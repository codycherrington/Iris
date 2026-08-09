import Foundation

// MARK: - Structured output

/// A result shape a sidebar tool asks the model to fill in.
///
/// The schema is a hand-written literal rather than something derived from the type. Swift
/// has no built-in JSON Schema reflection, and the literal is what the model actually sees,
/// so keeping it beside the properties makes a drift between them visible in review.
///
/// Use `additionalProperties: false` and list every field in `required` — the CLI is
/// stricter about matching the schema than about matching your `Decodable`, and a missing
/// `required` entry shows up as a silently absent field rather than an error.
public protocol StructuredOutput: Decodable, Sendable {
    static var jsonSchema: String { get }
}

// MARK: - Configuration

/// How to launch a short-lived `claude -p` call for a sidebar tool.
///
/// The defaults here are the whole point of the type. A one-shot call inherits nothing from
/// the main session, so unless it is stripped it pays a full cold start every time: the
/// measured difference between a default launch and this one was **18,854 cache-creation
/// tokens and 32.5 s, versus 0 tokens and 6.6 s** for the same prompt. That is the gap
/// between a sidebar you press repeatedly and one you press twice and stop using.
///
/// Everything that costs tokens is off by default. Turn things back on deliberately.
public struct OneShotConfiguration: Sendable {

    public var executableURL: URL
    public var workingDirectory: URL

    /// Sidebar tools are classification and rewriting jobs, not agentic ones. Haiku is the
    /// default and should stay the default; a tool that genuinely needs more should say so
    /// loudly, because it shares the session's quota.
    public var model: String

    /// *Replaces* the default Claude Code system prompt rather than appending to it — that
    /// prompt is most of the cold start, and a sidebar tool needs none of it.
    public var systemPrompt: String

    /// Built-in tools to expose. Empty means `--tools ""`: no tool definitions at all, which
    /// is where the bulk of the token saving comes from. A tool that needs filesystem access
    /// is not a sidebar tool — it belongs in the main session.
    public var tools: [String]

    /// Hard deadline. The process is terminated when it expires.
    public var timeout: Duration

    /// Assert `apiKeySource == "none"`. Leave on: one-shot calls go through the same auth
    /// path as the session, so this is the same load-bearing check, not a weaker one.
    public var requireSubscriptionAuth: Bool

    public init(
        executableURL: URL = AgentConfiguration.defaultExecutableURL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        model: String = "haiku",
        systemPrompt: String,
        tools: [String] = [],
        timeout: Duration = .seconds(60),
        requireSubscriptionAuth: Bool = true
    ) {
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.timeout = timeout
        self.requireSubscriptionAuth = requireSubscriptionAuth
    }

    /// Flags verified against claude 2.1.226 by measuring the resulting token usage, not by
    /// reading docs — `--tools ""`, `--setting-sources ""` and
    /// `--exclude-dynamic-system-prompt-sections` are what drive cache creation to zero.
    func arguments(prompt: String, schema: String) -> [String] {
        [
            "-p", prompt,
            "--model", model,
            "--system-prompt", systemPrompt,
            "--exclude-dynamic-system-prompt-sections",
            // No CLAUDE.md, no skills, no plugins, no user settings. A sidebar tool must
            // behave identically regardless of which project happens to be open.
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            // These runs are ephemeral by definition; leaving session files behind would
            // pollute the Phase 5 session library with sidebar noise.
            "--no-session-persistence",
            "--tools", tools.joined(separator: ","),
            "--json-schema", schema,
            // stream-json rather than json purely so `system/init` is visible and the
            // subscription-auth assertion can run. The result line is identical.
            "--output-format", "stream-json",
            "--verbose",
        ]
    }
}

// MARK: - Result

public struct OneShotResult<Value: Sendable>: Sendable {
    public let value: Value
    public let usage: OneShotUsage
}

/// What the run cost. Surfaced rather than logged because sidebar tools draw on the same
/// quota as the conversation — the Phase 5 meter has to count these too or it lies.
public struct OneShotUsage: Sendable {
    public let durationMS: Int?
    public let numTurns: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheCreationTokens: Int?
    /// Client-side estimate at API rates. Nothing is billed on subscription auth.
    public let estimatedCostUSD: Double?
    public let model: String?

    /// True when the run rebuilt its prompt cache from scratch. Expected to be false for
    /// every sidebar tool; if it starts coming back true, a flag stopped working.
    public var didPayColdStart: Bool { (cacheCreationTokens ?? 0) > 0 }
}

// MARK: - Runner

/// `Process.terminationStatus` raises an **Objective-C exception** if the process hasn't
/// exited yet, and Swift cannot catch those — it aborts the process. A fired deadline is
/// exactly that state, so every timeout crashed the app until this guard existed. Never
/// read `terminationStatus` without checking `isRunning` first.
private func exitedStatus(_ process: Process) -> Int32? {
    process.isRunning ? nil : process.terminationStatus
}

/// Runs a single short-lived `claude -p` call and decodes its structured result.
///
/// Deliberately not part of `AgentBridge`. The bridge exists to keep *one* process alive
/// across many turns because per-turn startup would break the perf gate; this does the
/// opposite on purpose, because a sidebar tool must not touch the conversation's context.
/// Two execution modes, two types.
public enum OneShotQuery {

    /// Ask for one structured answer.
    ///
    /// - Throws: `AgentError.unexpectedAuthSource` if the run isn't on subscription auth,
    ///   `.timedOut` past the deadline, `.noStructuredOutput` if the model answered in prose.
    public static func run<Value: StructuredOutput>(
        _ type: Value.Type = Value.self,
        prompt: String,
        configuration: OneShotConfiguration
    ) async throws -> OneShotResult<Value> {
        let result = try await runRaw(
            prompt: prompt, schema: Value.jsonSchema, configuration: configuration)

        return OneShotResult(
            value: try result.decodeStructuredOutput(Value.self),
            usage: OneShotUsage(
                durationMS: result.durationMS,
                numTurns: result.numTurns,
                inputTokens: result.usage?.inputTokens,
                outputTokens: result.usage?.outputTokens,
                cacheCreationTokens: result.usage?.cacheCreationInputTokens,
                estimatedCostUSD: result.totalCostUSD,
                model: result.modelUsage.keys.sorted().first))
    }

    /// The run without the decoding step, for callers that want the raw result — the
    /// benchmark harness, mostly.
    public static func runRaw(
        prompt: String,
        schema: String,
        configuration: OneShotConfiguration
    ) async throws -> RunResult {
        guard FileManager.default.isExecutableFile(
                atPath: configuration.executableURL.path) else {
            throw AgentError.executableNotFound(configuration.executableURL)
        }

        let proc = Process()
        proc.executableURL = configuration.executableURL
        proc.arguments = configuration.arguments(prompt: prompt, schema: schema)
        proc.currentDirectoryURL = configuration.workingDirectory

        // Same belt-and-braces as AgentBridge: even if the user's shell exports a key, the
        // child never sees it, so it cannot silently fall into per-token billing.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        proc.environment = env

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(
            bufferingPolicy: .unbounded)

        let assembler = LineAssembler()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                if let tail = assembler.flush(), let ev = AgentEventDecoder.decode(line: tail) {
                    continuation.yield(ev)
                }
                handle.readabilityHandler = nil
                return
            }
            for line in assembler.append(chunk) {
                if let event = AgentEventDecoder.decode(line: line) {
                    continuation.yield(event)
                }
            }
        }
        // Drained but discarded: the CLI reports real failures on stdout as a result event.
        // Leaving it unread would deadlock the child once the pipe buffer fills.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        proc.terminationHandler = { _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
        }

        do {
            try proc.run()
        } catch {
            continuation.finish()
            throw AgentError.launchFailed(String(describing: error))
        }

        let timeout = configuration.timeout
        let requireSubscription = configuration.requireSubscriptionAuth

        do {
            return try await withThrowingTaskGroup(of: RunResult.self) { group in
                group.addTask {
                    var found: RunResult?
                    for await event in stream {
                        if case .systemInit(let info) = event,
                           requireSubscription, !info.isSubscriptionAuth {
                            throw AgentError.unexpectedAuthSource(info.apiKeySource)
                        }
                        // Keep draining after the result so the process closes cleanly
                        // rather than being killed mid-write on the next line.
                        if case .result(let r) = event { found = r }
                    }
                    // When the deadline fires, the group cancels this task and the stream
                    // ends early. Report that as cancellation rather than as a bogus
                    // "no result", which would mask the real timeout.
                    try Task.checkCancellation()
                    guard let found else {
                        throw AgentError.noResult(exitCode: exitedStatus(proc))
                    }
                    if found.isError {
                        throw AgentError.runFailed(found.resultText ?? found.subtype)
                    }
                    return found
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AgentError.timedOut(
                        seconds: Double(timeout.components.seconds))
                }

                // Whichever finishes first wins; cancelling the group stops the other.
                guard let winner = try await group.next() else {
                    throw AgentError.noResult(exitCode: exitedStatus(proc))
                }
                group.cancelAll()
                return winner
            }
        } catch {
            if proc.isRunning { proc.terminate() }
            continuation.finish()
            throw error
        }
    }
}
