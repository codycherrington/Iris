import Foundation

/// What `claude auth status --json` reports.
///
/// Shapes observed on claude 2.1.226:
///
/// ```json
/// { "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
///   "email": "…", "orgId": "…", "subscriptionType": "pro" }
/// ```
///
/// and with a key in the environment — note `apiKeySource` appears and the subscription
/// fields go null:
///
/// ```json
/// { "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
///   "apiKeySource": "ANTHROPIC_API_KEY", "subscriptionType": null }
/// ```
public struct AuthStatus: Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let apiProvider: String?
    /// Present only when a key is in play. Absent is the subscription path — the same
    /// invariant `system/init.apiKeySource == "none"` expresses, reported by the same name.
    public let apiKeySource: String?
    /// e.g. "pro", "max". Null whenever a key is being used.
    public let subscriptionType: String?
    public let email: String?

    /// True when this install will authenticate against a subscription rather than a key.
    public var isSubscriptionAuth: Bool { loggedIn && apiKeySource == nil }
}

/// Answers "is this install on a subscription?" *before* a session has taken a turn.
///
/// This exists because `system/init` — the authoritative signal — is emitted **per turn**,
/// not at process start. A freshly launched session therefore knows nothing about its own
/// auth until the user sends a first message, which left the status indicator reading
/// "checking…" indefinitely on a window that had just been opened.
///
/// `claude auth status --json` answers the same question by reading local credentials:
/// **no model call, no tokens, no quota.** That makes it safe to run on every launch, which
/// a one-shot `claude -p` would not be.
///
/// Measured: ~0.25 s invoked directly in a shell, **~1.2 s through `Process`** — the same
/// ~1 s of spawn overhead the sidebar's one-shot calls pay. Fast enough to run detached at
/// launch and let the indicator fill in a moment later; not fast enough to block on.
///
/// It does **not** replace the per-turn assertion in `AgentBridge.observe`. That one is
/// authoritative and stays: this reports what the install is configured to do, and
/// `system/init` reports what the session actually did.
public enum AuthProbe {

    public static func check(
        executableURL: URL = AgentConfiguration.defaultExecutableURL,
        timeout: Duration = .seconds(10)
    ) async throws -> AuthStatus {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AgentError.executableNotFound(executableURL)
        }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = ["auth", "status", "--json"]

        // Scrub exactly what AgentBridge scrubs. Without this the probe would report a key
        // the session is never going to see, and warn about a problem that doesn't exist.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        proc.environment = env

        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw AgentError.launchFailed(String(describing: error))
        }

        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let handle = stdout.fileHandleForReading
                return handle.readDataToEndOfFile()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AgentError.timedOut(seconds: Double(timeout.components.seconds))
            }
            guard let first = try await group.next() else {
                throw AgentError.noResult(exitCode: nil)
            }
            group.cancelAll()
            return first
        }

        if proc.isRunning { proc.terminate() }

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AgentError.runFailed("could not parse `claude auth status --json` output")
        }

        return AuthStatus(
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            authMethod: obj["authMethod"] as? String,
            apiProvider: obj["apiProvider"] as? String,
            // Deliberately reads a *missing* key and an explicit null the same way: both
            // mean "no key involved".
            apiKeySource: obj["apiKeySource"] as? String,
            subscriptionType: obj["subscriptionType"] as? String,
            email: obj["email"] as? String)
    }
}
