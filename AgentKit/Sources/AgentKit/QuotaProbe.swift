import Foundation

// MARK: - Result

/// One rate-limit window, as the CLI's own status line reports it.
public struct QuotaWindow: Sendable {
    /// 0–100. The CLI emits fractions (`55.00000000000001`), so this is a `Double`.
    public let usedPercent: Double
    public let resetsAt: Date?

    public var timeRemaining: TimeInterval? {
        resetsAt.map { max(0, $0.timeIntervalSinceNow) }
    }
}

public struct QuotaSnapshot: Sendable {
    public let fiveHour: QuotaWindow?
    public let sevenDay: QuotaWindow?
    /// When the reading was taken. Shown to the user, because a probe this expensive doesn't
    /// run often enough for "now" to be honest.
    public let capturedAt: Date
}

public enum QuotaProbeError: Error, CustomStringConvertible, Sendable {
    /// Every probe runs an interactive session, and interactive sessions refuse to start in
    /// a directory the user hasn't trusted.
    case noTrustedDirectory
    case timedOut
    case noQuotaInPayload
    case launchFailed(String)

    public var description: String {
        switch self {
        case .noTrustedDirectory:
            return "no trusted directory to run the probe in — open a folder in Claude Code "
                + "once and accept the trust prompt"
        case .timedOut: return "quota probe timed out"
        case .noQuotaInPayload: return "the status line reported no rate_limits"
        case .launchFailed(let why): return "quota probe failed to launch: \(why)"
        }
    }
}

// MARK: - Probe

/// Reads the account's rate-limit percentages — the numbers behind `5h 72%` and `7d 55%` in
/// Claude Code's own status line.
///
/// ## Why this is so indirect
///
/// **Print mode does not report them.** `rate_limit_event` carries `status`, `resetsAt`,
/// `rateLimitType` and two overage flags, and nothing else — verified against a live 2.1.226
/// stream, not just the captured fixture. There is no `claude usage` subcommand. Every event
/// type a `-p` session emits (`system/init`, `system/status`, `system/thinking_tokens`,
/// `stream_event`, `assistant`, `rate_limit_event`, `result`) was enumerated and none of them
/// carries a percentage.
///
/// The percentages exist in exactly one place: the JSON payload the CLI pipes to a
/// **`statusLine` command**, under `rate_limits.five_hour.used_percentage`. That mechanism is
/// interactive-only — a `-p` run with a `statusLine` configured never invokes it (tested).
///
/// So the probe borrows the mechanism: launch a short interactive session whose `statusLine`
/// is a script that dumps its stdin, read the dump, and kill the session. Three consequences
/// that are load-bearing rather than incidental:
///
/// 1. **It needs a pty.** The interactive CLI won't run without one, hence `/usr/bin/script`.
/// 2. **It needs a real turn.** A session that has made no API call has no `rate_limits` key
///    at all — the numbers come from response headers. So the probe says one word and waits
///    for the *second* status-line render, the one that has them.
/// 3. **It needs a trusted directory.** Interactive sessions show a trust prompt in unfamiliar
///    folders, and a prompt in a pty nobody is watching is a hang. The probe looks up a folder
///    the user has already trusted rather than accepting the prompt on their behalf.
///
/// ## What it costs
///
/// Measured, with the same stripping the sidebar tools use: **1,132 in / 133 out, 0
/// cache-creation tokens, ~4 s**. `--setting-sources ""` is what keeps the cold start at zero,
/// and it does not disable `--settings`, so the status-line override still applies — that
/// combination was tested, not assumed. Without the strip flags the same probe pays 7,555
/// cache-creation tokens.
///
/// It is still a turn, drawn from the pool it is measuring. Call it on a slow timer.
public enum QuotaProbe {

    public static func check(
        executableURL: URL = AgentConfiguration.defaultExecutableURL,
        preferring preferredDirectory: URL? = nil,
        timeout: Duration = .seconds(40)
    ) async throws -> QuotaSnapshot {
        guard let workingDirectory = trustedDirectory(preferring: preferredDirectory) else {
            throw QuotaProbeError.noTrustedDirectory
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-quota-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let payload = scratch.appendingPathComponent("payload.json")
        let sentinel = scratch.appendingPathComponent("ready")
        let dumper = scratch.appendingPathComponent("statusline.sh")
        let settings = scratch.appendingPathComponent("settings.json")

        // The status line renders more than once, and the first render — before any API call
        // has returned — has no `rate_limits`. The sentinel is only touched once the payload
        // actually contains them, which is what lets the session exit the moment it's useful
        // instead of on a fixed timer.
        try """
            #!/bin/sh
            cat > '\(payload.path)'
            grep -q '"rate_limits"' '\(payload.path)' && : > '\(sentinel.path)'
            echo ""
            """.write(to: dumper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dumper.path)
        try #"{"statusLine":{"type":"command","command":"\#(dumper.path)"}}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // `-q /dev/null` allocates the pty and throws the typescript away. The inner shell
        // owns the lifetime: it waits for the sentinel and then kills the session, so nothing
        // is left running if this side goes away.
        process.arguments = [
            "-q", "/dev/null", "/bin/sh", "-c",
            innerScript(executable: executableURL, settings: settings, sentinel: sentinel),
        ]
        process.currentDirectoryURL = workingDirectory

        // Same guard as everywhere else: the probe must not be the one call that quietly
        // authenticates with a key.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        process.environment = env

        // The TUI's output is noise — a pty means it's full of escape sequences — but the
        // pipes still have to be drained or the child blocks once a buffer fills.
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        process.standardInput = FileHandle.nullDevice
        sink.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        do {
            try process.run()
        } catch {
            throw QuotaProbeError.launchFailed(String(describing: error))
        }

        defer {
            sink.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        try await waitForExit(process, timeout: timeout)

        guard let data = try? Data(contentsOf: payload) else {
            throw QuotaProbeError.noQuotaInPayload
        }
        return try parse(data)
    }

    // MARK: Pieces

    private static func innerScript(executable: URL, settings: URL, sentinel: URL) -> String {
        // The flags are the sidebar's stripping discipline, for the same reason: an
        // interactive launch reads CLAUDE.md, skills, plugins and MCP config, and every one of
        // those is prompt-cache creation the probe has no use for.
        //
        // `--setting-sources ''` does *not* disable `--settings`, so the status-line override
        // still lands. That is the one flag interaction here worth having tested.
        let claude = "'\(executable.path)'"
        return """
            \(claude) --model haiku --settings '\(settings.path)' \
            --setting-sources '' --tools '' --strict-mcp-config --disable-slash-commands \
            --exclude-dynamic-system-prompt-sections \
            --system-prompt 'Reply with the single word ok.' ok &
            CP=$!
            i=0
            while [ $i -lt 70 ]; do
              [ -f '\(sentinel.path)' ] && break
              sleep 0.5
              i=$((i+1))
            done
            kill $CP 2>/dev/null
            """
    }

    private static func waitForExit(_ process: Process, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                    // Racing the handler against an already-exited process: without this a
                    // fast probe hangs forever waiting for a callback that fired first.
                    if !process.isRunning { process.terminationHandler = nil
                        continuation.resume() }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw QuotaProbeError.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func parse(_ data: Data) throws -> QuotaSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else {
            throw QuotaProbeError.noQuotaInPayload
        }
        func window(_ key: String) -> QuotaWindow? {
            guard let raw = limits[key] as? [String: Any],
                  let percent = raw["used_percentage"] as? Double else { return nil }
            let resets = (raw["resets_at"] as? Double).map {
                Date(timeIntervalSince1970: $0)
            }
            return QuotaWindow(usedPercent: percent, resetsAt: resets)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { throw QuotaProbeError.noQuotaInPayload }
        return QuotaSnapshot(fiveHour: five, sevenDay: seven, capturedAt: Date())
    }

    /// A folder the user has already accepted the trust prompt for.
    ///
    /// Read from `~/.claude.json`, never written. Accepting trust on the user's behalf — by
    /// flipping the flag, or by answering the prompt through the pty — would be Iris granting
    /// the CLI file access to a directory on a decision the user never made.
    public static func trustedDirectory(preferring preferred: URL?) -> URL? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return nil }

        func isTrusted(_ path: String) -> Bool {
            guard let entry = projects[path] as? [String: Any] else { return false }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path,
                                                        isDirectory: &isDirectory)
            return entry["hasTrustDialogAccepted"] as? Bool == true
                && exists && isDirectory.boolValue
        }

        // The session's own folder first, so the probe runs somewhere the user would expect.
        if let preferred, isTrusted(preferred.path) { return preferred }
        // Otherwise any trusted folder — the numbers are account-wide, so which one is
        // irrelevant beyond satisfying the trust check. Sorted for a stable choice across
        // launches rather than whatever order the dictionary hands back.
        return projects.keys.sorted().first(where: isTrusted).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }
}
