import AgentKit
import Foundation
import Observation

// MARK: - View models

struct ToolCall: Identifiable, Sendable {
    let id: String
    let name: String
    var detail: String
    var result: String?
    var isError = false
    var deniedInput: [String: String]?
}

struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var toolCalls: [ToolCall] = []
    var isStreaming = false
    /// Set once the buffered `assistant` event confirms the streamed text.
    var isConfirmed = false
}

/// Live per-turn and per-session telemetry, straight from the CLI's own reporting.
struct SessionStats: Sendable {
    /// Nothing is known about the session until the first turn — `system/init` arrives per
    /// turn, not at process start. Distinguishing "not yet known" from "known to be bad"
    /// matters: the auth indicator must not imply API-key billing before it has any data.
    enum Connection: Sendable { case starting, ready, degraded }

    var connection: Connection = .starting
    var model = "—"
    var authSource = "—"
    var isSubscription = false
    var ttftMS: Int?
    var dispatchMS: Int?
    var sessionCostUSD: Double?
    var contextWindow: Int?
    var quotaStatus: String?
    var quotaResetsAt: Date?
    var thinkingTokens: Int?
    var mcpNeedingAuth: [String] = []
}

// MARK: - Model

@MainActor
@Observable
final class SessionModel {
    private(set) var messages: [ChatMessage] = []
    private(set) var stats = SessionStats()
    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var fatalError: String?
    private(set) var workingDirectory: URL

    private var bridge: AgentBridge?
    private var consumer: Task<Void, Never>?

    private static let directoryKey = "iris.workingDirectory"

    init(workingDirectory: URL? = nil) {
        // Remember the last folder so the app doesn't reopen in $HOME every launch — which
        // also means re-triggering macOS's Documents-access prompt each time.
        if let explicit = workingDirectory {
            self.workingDirectory = explicit
        } else if let saved = UserDefaults.standard.url(forKey: Self.directoryKey),
                  FileManager.default.fileExists(atPath: saved.path) {
            self.workingDirectory = saved
        } else {
            self.workingDirectory = URL(fileURLWithPath: NSHomeDirectory())
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !isRunning else { return }
        fatalError = nil
        messages.removeAll()

        let bridge = AgentBridge(configuration: AgentConfiguration(
            workingDirectory: workingDirectory,
            permissionMode: .default
        ))
        self.bridge = bridge

        let stream: AsyncStream<AgentEvent>
        do {
            stream = try await bridge.start()
        } catch {
            fatalError = String(describing: error)
            return
        }
        isRunning = true
        consumer = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, from: bridge)
            }
            await MainActor.run { self?.isRunning = false }
        }
    }

    func changeDirectory(to url: URL) async {
        await stop()
        workingDirectory = url
        UserDefaults.standard.set(url, forKey: Self.directoryKey)
        stats = SessionStats()
        await start()
    }

    func stop() async {
        consumer?.cancel()
        consumer = nil
        await bridge?.stop()
        bridge = nil
        isRunning = false
        isBusy = false
    }

    // MARK: Sending

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let bridge else { return }
        messages.append(ChatMessage(role: .user, text: trimmed, isConfirmed: true))
        isBusy = true
        stats.ttftMS = nil
        stats.thinkingTokens = nil
        do {
            try await bridge.send(trimmed)
        } catch {
            fatalError = String(describing: error)
            isBusy = false
        }
    }

    /// Abort the in-flight turn. The CLI tears down the turn and exits 143, so the session
    /// is restarted to keep the window usable.
    func interrupt() async {
        guard isBusy, let bridge else { return }
        await bridge.interrupt()
        isBusy = false
        if var last = messages.last, last.role == .assistant, last.isStreaming {
            last.isStreaming = false
            last.text += last.text.isEmpty ? "[interrupted]" : "\n\n[interrupted]"
            messages[messages.count - 1] = last
        }
        await stop()
        await start()
    }

    // MARK: Event handling

    private func handle(_ event: AgentEvent, from bridge: AgentBridge) async {
        do {
            try await bridge.observe(event)
        } catch {
            fatalError = String(describing: error)
            await stop()
            return
        }

        switch event {
        case .systemInit(let info):
            stats.model = info.model
            stats.authSource = info.apiKeySource
            stats.isSubscription = info.isSubscriptionAuth
            stats.connection = info.isSubscriptionAuth ? .ready : .degraded
            stats.mcpNeedingAuth = info.mcpServers.filter(\.needsAuth).map(\.name)

        case .rateLimit(let info):
            stats.quotaStatus = info.status
            stats.quotaResetsAt = info.resetsAtDate

        case .thinkingTokens(let estimated, _):
            stats.thinkingTokens = estimated

        case .streamEvent(let s):
            guard let delta = s.textDelta else { break }
            appendStreamingText(delta)

        case .assistant(let m):
            // Buffered message — arrives BEFORE content_block_stop. Treat as authoritative
            // for text, and pick up any tool calls.
            let text = m.text
            if !text.isEmpty {
                if var last = messages.last, last.role == .assistant, !last.isConfirmed {
                    last.text = text
                    last.isConfirmed = true
                    last.isStreaming = false
                    messages[messages.count - 1] = last
                } else {
                    messages.append(ChatMessage(role: .assistant, text: text, isConfirmed: true))
                }
            }
            for (id, name, input) in m.toolUses {
                let detail = input["file_path"]?.stringValue
                    ?? input["command"]?.stringValue
                    ?? input["pattern"]?.stringValue ?? ""
                let call = ToolCall(id: id, name: name, detail: detail)
                if var last = messages.last, last.role == .assistant {
                    last.toolCalls.append(call)
                    messages[messages.count - 1] = last
                } else {
                    var m = ChatMessage(role: .assistant, text: "", isConfirmed: true)
                    m.toolCalls = [call]
                    messages.append(m)
                }
            }

        case .user(let m):
            // Tool results come back as a synthetic user turn.
            for block in m.content {
                guard case .toolResult(let toolUseID, let content, let isError) = block else { continue }
                attachResult(content, isError: isError, to: toolUseID)
            }

        case .permissionDenied(let denied):
            markDenied(toolUseID: denied.toolUseID)

        case .result(let r):
            isBusy = false
            stats.ttftMS = r.ttftMS
            stats.dispatchMS = r.timeToRequestMS
            stats.sessionCostUSD = r.totalCostUSD
            stats.thinkingTokens = nil
            if let window = r.modelUsage.values.compactMap(\.contextWindow).max() {
                stats.contextWindow = window
            }
            for denial in r.permissionDenials {
                attachDeniedInput(denial)
            }
            if var last = messages.last, last.isStreaming {
                last.isStreaming = false
                messages[messages.count - 1] = last
            }

        default:
            break
        }
    }

    private func appendStreamingText(_ delta: String) {
        if var last = messages.last, last.role == .assistant, !last.isConfirmed {
            last.text += delta
            last.isStreaming = true
            messages[messages.count - 1] = last
        } else {
            messages.append(ChatMessage(role: .assistant, text: delta, isStreaming: true))
        }
    }

    private func attachResult(_ content: String, isError: Bool, to toolUseID: String) {
        for i in messages.indices.reversed() {
            guard let j = messages[i].toolCalls.firstIndex(where: { $0.id == toolUseID })
            else { continue }
            messages[i].toolCalls[j].result = content
            messages[i].toolCalls[j].isError = isError
            return
        }
    }

    private func markDenied(toolUseID: String) {
        for i in messages.indices.reversed() {
            guard let j = messages[i].toolCalls.firstIndex(where: { $0.id == toolUseID })
            else { continue }
            messages[i].toolCalls[j].isError = true
            return
        }
    }

    /// The denial carries the full intended input — the basis of the Phase 5 diff UI.
    /// Phase 2 just surfaces that we have it.
    private func attachDeniedInput(_ denial: RunResult.Denial) {
        for i in messages.indices.reversed() {
            guard let j = messages[i].toolCalls.firstIndex(where: { $0.id == denial.toolUseID })
            else { continue }
            var flattened: [String: String] = [:]
            for (k, v) in denial.toolInput {
                flattened[k] = v.stringValue ?? String(describing: v)
            }
            messages[i].toolCalls[j].deniedInput = flattened
            return
        }
    }
}
