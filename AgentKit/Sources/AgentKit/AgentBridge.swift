import Foundation

// MARK: - Errors

public enum AgentError: Error, Sendable, CustomStringConvertible {
    case executableNotFound(URL)
    case notRunning
    case alreadyRunning
    case writeFailed(String)
    /// The session authenticated with an API key instead of the subscription.
    /// Iris treats this as fatal rather than continuing into per-token billing.
    case unexpectedAuthSource(String)
    case launchFailed(String)
    /// A one-shot query ran past its deadline. Sidebar tools are meant to be quick; a
    /// hang must not leave a spinner up forever.
    case timedOut(seconds: Double)
    /// The run finished but produced no `structured_output`. Usually means the model
    /// answered in prose instead of calling the schema tool.
    case noStructuredOutput(stopReason: String?)
    /// The CLI reported `is_error` on the result line.
    case runFailed(String)
    /// The process stopped without ever emitting a `result`. `exitCode` is nil when the
    /// process was still running — `Process.terminationStatus` cannot be read before exit.
    case noResult(exitCode: Int32?)

    public var description: String {
        switch self {
        case .executableNotFound(let url):
            return "claude CLI not found at \(url.path)"
        case .notRunning: return "agent process is not running"
        case .alreadyRunning: return "agent process is already running"
        case .writeFailed(let why): return "failed to write to agent stdin: \(why)"
        case .unexpectedAuthSource(let source):
            return """
                refusing to continue: session reported apiKeySource=\"\(source)\", expected \
                "none". Iris runs on a Claude subscription and will not fall back to \
                per-token API billing. Unset ANTHROPIC_APIKEY / ANTHROPIC_AUTH_TOKEN and \
                make sure `claude` is logged in.
                """
        case .launchFailed(let why): return "failed to launch agent process: \(why)"
        case .timedOut(let seconds):
            return "one-shot query exceeded its \(seconds)s deadline"
        case .noStructuredOutput(let stop):
            return "run produced no structured_output (stop_reason: \(stop ?? "nil"))"
        case .runFailed(let why): return "run failed: \(why)"
        case .noResult(let code):
            let how = code.map { "exited (\($0))" } ?? "was still running"
            return "process \(how) without emitting a result event"
        }
    }
}

// MARK: - Configuration

public struct AgentConfiguration: Sendable {
    public enum PermissionMode: String, Sendable {
        /// Tools that need approval are denied, but the turn still completes and the full
        /// intended input comes back in `result.permission_denials` — see ADR-004.
        case `default`
        /// Auto-approves writes and common filesystem commands.
        case acceptEdits
        /// Denies anything not explicitly allowed.
        case dontAsk
    }

    /// Reasoning budget for the session. The CLI's own vocabulary — don't invent levels.
    public enum Effort: String, Sendable, CaseIterable {
        case low, medium, high, xhigh, max
    }

    public var executableURL: URL
    public var workingDirectory: URL
    public var sessionID: UUID
    public var permissionMode: PermissionMode
    public var allowedTools: [String]
    public var appendSystemPrompt: String?
    /// Model alias (`sonnet`, `opus`, `haiku`, `fable`) or a full id. `nil` leaves the CLI's
    /// own default in place; Iris always sets it so the status bar can name the model before
    /// the first turn, rather than waiting for `system/init` to say what it turned out to be.
    public var model: String?
    public var effort: Effort?
    /// Needed to receive subagent text/thinking for the Phase 5 tree. Requires claude ≥ 2.1.211.
    public var forwardSubagentText: Bool
    /// Resume an existing session instead of starting a new one.
    public var resumeSessionID: String?
    /// When resuming, branch to a new session id rather than continuing in place.
    public var forkSession: Bool
    /// Fail the session if it doesn't report subscription auth. Leave on.
    public var requireSubscriptionAuth: Bool

    public init(
        executableURL: URL = AgentConfiguration.defaultExecutableURL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        sessionID: UUID = UUID(),
        permissionMode: PermissionMode = .default,
        allowedTools: [String] = [],
        appendSystemPrompt: String? = nil,
        model: String? = nil,
        effort: Effort? = nil,
        forwardSubagentText: Bool = false,
        resumeSessionID: String? = nil,
        forkSession: Bool = false,
        requireSubscriptionAuth: Bool = true
    ) {
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.appendSystemPrompt = appendSystemPrompt
        self.model = model
        self.effort = effort
        self.forwardSubagentText = forwardSubagentText
        self.resumeSessionID = resumeSessionID
        self.forkSession = forkSession
        self.requireSubscriptionAuth = requireSubscriptionAuth
    }

    public static var defaultExecutableURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/claude")
    }

    /// The flag set verified in the Phase 0 spike. `--include-partial-messages` requires
    /// `--verbose`; `--input-format stream-json` is what makes one process serve many turns.
    var arguments: [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if let resume = resumeSessionID {
            args += ["--resume", resume]
            if forkSession { args.append("--fork-session") }
        } else {
            args += ["--session-id", sessionID.uuidString.lowercased()]
        }
        if permissionMode != .default {
            args += ["--permission-mode", permissionMode.rawValue]
        }
        if !allowedTools.isEmpty {
            args += ["--allowedTools", allowedTools.joined(separator: ",")]
        }
        if let prompt = appendSystemPrompt {
            args += ["--append-system-prompt", prompt]
        }
        if let model {
            args += ["--model", model]
        }
        if let effort {
            args += ["--effort", effort.rawValue]
        }
        if forwardSubagentText {
            args.append("--forward-subagent-text")
        }
        return args
    }
}

// MARK: - Bridge

/// Owns a long-lived `claude` process and exposes its output as an `AsyncStream` of decoded
/// events.
///
/// The design rests on the Phase 0 measurement: `--input-format stream-json` keeps one
/// process alive across many turns, so the ~3.5 s startup is paid once per session and
/// per-turn dispatch overhead is 7–20 ms. Spawning per turn would put that 3.5 s on every
/// message and break the "never slower than the terminal" constraint.
public actor AgentBridge {

    public enum Lifecycle: Sendable, Equatable {
        case idle, running, terminated(code: Int32)
    }

    private let configuration: AgentConfiguration
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private let assembler = LineAssembler()
    public private(set) var lifecycle: Lifecycle = .idle
    /// Populated from the first `system/init`.
    public private(set) var sessionInfo: SystemInit?

    public init(configuration: AgentConfiguration = .init()) {
        self.configuration = configuration
    }

    // MARK: Lifecycle

    /// Launch the process and begin streaming events.
    ///
    /// The stream finishes when the process exits. It is a single-consumer stream — iterate
    /// it once; fan out downstream if several views need it.
    public func start() throws -> AsyncStream<AgentEvent> {
        guard process == nil else { throw AgentError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw AgentError.executableNotFound(configuration.executableURL)
        }

        let proc = Process()
        proc.executableURL = configuration.executableURL
        proc.arguments = configuration.arguments
        proc.currentDirectoryURL = configuration.workingDirectory

        // Belt and braces on the subscription constraint: even if the user's shell exports a
        // key, the child never sees it. Non-bare `claude -p` then falls through to OAuth.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        proc.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(
            // Events are small and the UI consumes them promptly; an unbounded buffer avoids
            // silently dropping protocol events, which would be far worse than memory growth.
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation

        let assembler = self.assembler
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

        // stderr is diagnostics only; the CLI reports real failures as a `result` on stdout.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                FileHandle.standardError.write(Data("[claude] \(text)".utf8))
            }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
        }

        do {
            try proc.run()
        } catch {
            continuation.finish()
            self.continuation = nil
            throw AgentError.launchFailed(String(describing: error))
        }

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.lifecycle = .running
        return stream
    }

    /// Record `system/init` and enforce the subscription-auth rule.
    ///
    /// Call this for each event you consume. Throws once, on the first init that reports a
    /// non-subscription auth source, so a caller can abort rather than silently run up an
    /// API bill.
    @discardableResult
    public func observe(_ event: AgentEvent) throws -> AgentEvent {
        if case .systemInit(let info) = event {
            sessionInfo = info
            if configuration.requireSubscriptionAuth, !info.isSubscriptionAuth {
                throw AgentError.unexpectedAuthSource(info.apiKeySource)
            }
        }
        return event
    }

    // MARK: Sending

    /// Queue a user turn. Safe to call while the agent is mid-turn — the CLI queues and
    /// processes in order.
    public func send(_ text: String) throws {
        guard let stdin = stdinHandle, process?.isRunning == true else {
            throw AgentError.notRunning
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            throw AgentError.writeFailed("could not encode message")
        }
        do {
            try stdin.write(contentsOf: data)
            try stdin.write(contentsOf: Data("\n".utf8))
        } catch {
            throw AgentError.writeFailed(String(describing: error))
        }
    }

    /// Abort the in-flight turn. The CLI aborts the turn, terminates any running Bash
    /// process tree, runs SessionEnd hooks, and exits 143.
    public func interrupt() {
        process?.terminate()
    }

    /// Close stdin and wait for a clean exit. Falls back to SIGTERM if it doesn't stop.
    public func stop(timeout: Duration = .seconds(10)) async {
        guard let proc = process else { return }
        try? stdinHandle?.close()
        stdinHandle = nil

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while proc.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if proc.isRunning { proc.terminate() }

        continuation?.finish()
        continuation = nil
        process = nil
        lifecycle = .terminated(code: proc.isRunning ? -1 : proc.terminationStatus)
    }
}
