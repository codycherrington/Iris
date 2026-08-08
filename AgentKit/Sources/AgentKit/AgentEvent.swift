import Foundation

/// One line of `claude --output-format stream-json` output.
///
/// The schema here was derived from real captured output (Phase 0 spike,
/// `Tests/AgentKitTests/Fixtures/*.ndjson`), not from documentation — several of these
/// event types are undocumented. The protocol will evolve, so decoding is deliberately
/// permissive: anything unrecognized lands in `.unrecognized` and is preserved verbatim
/// rather than throwing.
public enum AgentEvent: Sendable {
    case rateLimit(RateLimitInfo)
    case systemInit(SystemInit)
    case systemStatus(status: String)
    case thinkingTokens(estimated: Int, delta: Int)
    case permissionDenied(PermissionDenied)
    case streamEvent(StreamEvent)
    case assistant(Message)
    case user(Message)
    case result(RunResult)
    /// Any line we don't have a case for. Never fatal — log and continue.
    case unrecognized(type: String, raw: String)

    /// The `session_id` carried by most events, when present.
    public var sessionID: String? {
        switch self {
        case .rateLimit(let v): return v.sessionID
        case .systemInit(let v): return v.sessionID
        case .permissionDenied(let v): return v.sessionID
        case .assistant(let v), .user(let v): return v.sessionID
        case .result(let v): return v.sessionID
        default: return nil
        }
    }
}

// MARK: - Payloads

public struct RateLimitInfo: Codable, Sendable {
    /// e.g. "allowed"
    public let status: String
    /// Unix epoch seconds when the window resets.
    public let resetsAt: Int
    /// e.g. "five_hour"
    public let rateLimitType: String
    public let overageStatus: String?
    public let isUsingOverage: Bool?
    public var sessionID: String?

    public var resetsAtDate: Date { Date(timeIntervalSince1970: TimeInterval(resetsAt)) }
}

public struct SystemInit: Sendable {
    public let sessionID: String
    public let model: String
    public let cwd: String
    public let permissionMode: String
    /// `"none"` means no API key was used — i.e. the subscription/OAuth path.
    /// Iris asserts on this so it can never silently start billing per-token.
    public let apiKeySource: String
    public let version: String
    public let mcpServers: [MCPServer]
    public let plugins: [Plugin]

    /// True when this session is running on subscription auth rather than an API key.
    public var isSubscriptionAuth: Bool { apiKeySource == "none" }

    public struct MCPServer: Codable, Sendable {
        public let name: String
        /// e.g. "connected", "needs-auth"
        public let status: String
        public var needsAuth: Bool { status == "needs-auth" }
    }

    public struct Plugin: Codable, Sendable {
        public let name: String
        public let path: String?
        public let source: String?
        public let version: String?
    }
}

public struct PermissionDenied: Sendable {
    public let toolName: String
    public let toolUseID: String
    public let message: String
    public var sessionID: String?
}

public struct StreamEvent: Sendable {
    /// The inner Anthropic streaming event type: `message_start`, `content_block_delta`, …
    public let eventType: String
    /// Populated only for `content_block_delta` with a `text_delta`.
    public let textDelta: String?
}

public struct Message: Sendable {
    public let sessionID: String?
    public let role: String
    public let model: String?
    public let content: [ContentBlock]
    /// `nil` on the main thread; set to the spawning tool-use id inside a subagent.
    /// Following these reconstructs the full subagent tree at any nesting depth.
    public let parentToolUseID: String?

    public var text: String {
        content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined()
    }
    public var toolUses: [(id: String, name: String, input: [String: JSONValue])] {
        content.compactMap {
            if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) }
            return nil
        }
    }
}

public enum ContentBlock: Sendable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case toolResult(toolUseID: String, content: String, isError: Bool)
    case other(type: String)
}

public struct RunResult: Sendable {
    public let sessionID: String
    public let subtype: String
    public let isError: Bool
    public let stopReason: String?
    public let resultText: String?
    public let numTurns: Int?

    // The CLI reports its own timings — no client-side instrumentation needed.
    public let ttftMS: Int?
    public let ttftStreamMS: Int?
    /// Per-turn dispatch overhead inside the persistent process. Measured at 7–20 ms.
    public let timeToRequestMS: Int?
    public let durationMS: Int?
    public let durationAPIMS: Int?

    /// NOTE: cumulative for the whole session, not per turn. Diff consecutive results
    /// to get a per-turn cost.
    public let totalCostUSD: Double?
    public let modelUsage: [String: ModelUsage]
    /// Tools that were blocked. Carries the *full* intended input, which is what makes
    /// a native diff-approval UI possible without an MCP permission server.
    public let permissionDenials: [Denial]

    public struct ModelUsage: Codable, Sendable {
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cacheReadInputTokens: Int?
        public let cacheCreationInputTokens: Int?
        public let costUSD: Double?
        public let contextWindow: Int?
        public let maxOutputTokens: Int?
    }

    public struct Denial: Sendable {
        public let toolName: String
        public let toolUseID: String
        public let toolInput: [String: JSONValue]
    }
}

// MARK: - Minimal JSON value

/// Tool inputs are arbitrary JSON. We keep them structurally rather than forcing a schema,
/// because the diff-approval UI needs whatever the tool actually asked for.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let n as NSNumber:
            // NSNumber bridges Bool as well; check the ObjC type encoding.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else { self = .number(n.doubleValue) }
        case let a as [Any]: self = .array(a.map(JSONValue.init))
        case let d as [String: Any]: self = .object(d.mapValues(JSONValue.init))
        default: self = .null
        }
    }
}

// MARK: - Decoding

public enum AgentEventDecoder {
    /// Decode one NDJSON line. Returns `nil` for blank lines.
    ///
    /// Never throws on unknown shapes — unknown or malformed lines come back as
    /// `.unrecognized` so a protocol change degrades the UI instead of crashing it.
    public static func decode(line: String) -> AgentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unrecognized(type: "__unparseable__", raw: trimmed)
        }

        let type = obj["type"] as? String ?? "?"
        let subtype = obj["subtype"] as? String
        let session = obj["session_id"] as? String

        switch (type, subtype) {
        case ("rate_limit_event", _):
            guard let info = obj["rate_limit_info"] as? [String: Any] else { break }
            return .rateLimit(RateLimitInfo(
                status: info["status"] as? String ?? "unknown",
                resetsAt: info["resetsAt"] as? Int ?? 0,
                rateLimitType: info["rateLimitType"] as? String ?? "unknown",
                overageStatus: info["overageStatus"] as? String,
                isUsingOverage: info["isUsingOverage"] as? Bool,
                sessionID: session))

        case ("system", "init"):
            let servers = (obj["mcp_servers"] as? [[String: Any]] ?? []).map {
                SystemInit.MCPServer(name: $0["name"] as? String ?? "",
                                     status: $0["status"] as? String ?? "unknown")
            }
            let plugins = (obj["plugins"] as? [[String: Any]] ?? []).map {
                SystemInit.Plugin(name: $0["name"] as? String ?? "",
                                  path: $0["path"] as? String,
                                  source: $0["source"] as? String,
                                  version: $0["version"] as? String)
            }
            return .systemInit(SystemInit(
                sessionID: session ?? "",
                model: obj["model"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                permissionMode: obj["permissionMode"] as? String ?? "default",
                apiKeySource: obj["apiKeySource"] as? String ?? "unknown",
                version: obj["claude_code_version"] as? String ?? "",
                mcpServers: servers,
                plugins: plugins))

        case ("system", "status"):
            return .systemStatus(status: obj["status"] as? String ?? "")

        case ("system", "thinking_tokens"):
            return .thinkingTokens(estimated: obj["estimated_tokens"] as? Int ?? 0,
                                   delta: obj["estimated_tokens_delta"] as? Int ?? 0)

        case ("system", "permission_denied"):
            return .permissionDenied(PermissionDenied(
                toolName: obj["tool_name"] as? String ?? "",
                toolUseID: obj["tool_use_id"] as? String ?? "",
                message: obj["message"] as? String ?? "",
                sessionID: session))

        case ("stream_event", _):
            let inner = obj["event"] as? [String: Any] ?? [:]
            let delta = inner["delta"] as? [String: Any]
            let text = (delta?["type"] as? String) == "text_delta"
                ? delta?["text"] as? String : nil
            return .streamEvent(StreamEvent(
                eventType: inner["type"] as? String ?? "?", textDelta: text))

        case ("assistant", _), ("user", _):
            let msg = obj["message"] as? [String: Any] ?? [:]
            let blocks = (msg["content"] as? [[String: Any]] ?? []).map(decodeBlock)
            let m = Message(sessionID: session,
                            role: msg["role"] as? String ?? type,
                            model: msg["model"] as? String,
                            content: blocks,
                            parentToolUseID: obj["parent_tool_use_id"] as? String)
            return type == "assistant" ? .assistant(m) : .user(m)

        case ("result", _):
            var usage: [String: RunResult.ModelUsage] = [:]
            for (k, v) in (obj["modelUsage"] as? [String: [String: Any]] ?? [:]) {
                usage[k] = RunResult.ModelUsage(
                    inputTokens: v["inputTokens"] as? Int,
                    outputTokens: v["outputTokens"] as? Int,
                    cacheReadInputTokens: v["cacheReadInputTokens"] as? Int,
                    cacheCreationInputTokens: v["cacheCreationInputTokens"] as? Int,
                    costUSD: v["costUSD"] as? Double,
                    contextWindow: v["contextWindow"] as? Int,
                    maxOutputTokens: v["maxOutputTokens"] as? Int)
            }
            let denials = (obj["permission_denials"] as? [[String: Any]] ?? []).map {
                RunResult.Denial(
                    toolName: $0["tool_name"] as? String ?? "",
                    toolUseID: $0["tool_use_id"] as? String ?? "",
                    toolInput: ($0["tool_input"] as? [String: Any] ?? [:]).mapValues(JSONValue.init))
            }
            return .result(RunResult(
                sessionID: session ?? "",
                subtype: subtype ?? "",
                isError: obj["is_error"] as? Bool ?? false,
                stopReason: obj["stop_reason"] as? String,
                resultText: obj["result"] as? String,
                numTurns: obj["num_turns"] as? Int,
                ttftMS: obj["ttft_ms"] as? Int,
                ttftStreamMS: obj["ttft_stream_ms"] as? Int,
                timeToRequestMS: obj["time_to_request_ms"] as? Int,
                durationMS: obj["duration_ms"] as? Int,
                durationAPIMS: obj["duration_api_ms"] as? Int,
                totalCostUSD: obj["total_cost_usd"] as? Double,
                modelUsage: usage,
                permissionDenials: denials))

        default:
            break
        }
        return .unrecognized(type: subtype.map { "\(type)/\($0)" } ?? type, raw: trimmed)
    }

    private static func decodeBlock(_ b: [String: Any]) -> ContentBlock {
        switch b["type"] as? String {
        case "text": return .text(b["text"] as? String ?? "")
        case "thinking": return .thinking(b["thinking"] as? String ?? "")
        case "tool_use":
            return .toolUse(id: b["id"] as? String ?? "",
                            name: b["name"] as? String ?? "",
                            input: (b["input"] as? [String: Any] ?? [:]).mapValues(JSONValue.init))
        case "tool_result":
            let content: String
            if let s = b["content"] as? String { content = s }
            else if let arr = b["content"] as? [[String: Any]] {
                content = arr.compactMap { $0["text"] as? String }.joined()
            } else { content = "" }
            return .toolResult(toolUseID: b["tool_use_id"] as? String ?? "",
                               content: content,
                               isError: b["is_error"] as? Bool ?? false)
        case let other: return .other(type: other ?? "?")
        }
    }
}
