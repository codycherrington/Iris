import AgentKit
import Foundation

/// Phase 1 exit bar: a multi-turn conversation through AgentBridge, no UI.
///
///   make harness              interactive
///   make harness ARGS="-b"    scripted 3-turn benchmark (no input needed)

let args = CommandLine.arguments.dropFirst()
let benchmark = args.contains("-b") || args.contains("--benchmark")

let config = AgentConfiguration(
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    permissionMode: .default
)
let bridge = AgentBridge(configuration: config)

func styled(_ s: String, _ code: String) -> String { "\u{1B}[\(code)m\(s)\u{1B}[0m" }
let dim = { styled($0, "2") }, bold = { styled($0, "1") }, red = { styled($0, "31") }

print(bold("iris-cli") + dim(" — AgentKit harness. Ctrl-D to exit.\n"))

let stream: AsyncStream<AgentEvent>
do {
    stream = try await bridge.start()
} catch {
    print(red("launch failed: \(error)"))
    exit(1)
}

/// Signals a completed turn back to the driver loop.
let turnComplete = AsyncStream<RunResult>.makeStream()

let consumer = Task {
    var streaming = false
    // `system/init` arrives once per TURN, not once per process, so the banner needs its own
    // latch — reusing `streaming` printed it on every turn.
    var didPrintBanner = false
    for await event in stream {
        do {
            try await bridge.observe(event)
        } catch {
            // Subscription-auth violation is fatal by design.
            print("\n" + red("\(error)"))
            exit(2)
        }

        switch event {
        case .systemInit(let info):
            if !didPrintBanner {
                didPrintBanner = true
                let auth = info.isSubscriptionAuth
                    ? styled("subscription", "32") : red(info.apiKeySource)
                print(dim("  session \(info.sessionID.prefix(8))  ·  \(info.model)  ·  auth: ") + auth)
                let pending = info.mcpServers.filter(\.needsAuth).map(\.name)
                if !pending.isEmpty {
                    print(dim("  mcp needs auth: \(pending.joined(separator: ", "))"))
                }
                print("")
            }

        case .rateLimit(let info):
            let mins = max(0, Int(info.resetsAtDate.timeIntervalSinceNow / 60))
            print(dim("  quota: \(info.status) (\(info.rateLimitType), resets in \(mins)m)"))

        case .thinkingTokens(let estimated, _):
            print(dim("\r  thinking… \(estimated) tokens"), terminator: "")
            fflush(stdout)

        case .streamEvent(let s):
            if let text = s.textDelta {
                if !streaming { print(""); streaming = true }
                print(text, terminator: "")
                fflush(stdout)
            }

        case .assistant(let m):
            for (_, name, input) in m.toolUses {
                let target = input["file_path"]?.stringValue
                    ?? input["command"]?.stringValue ?? ""
                print("\n" + dim("  → \(name) \(target.prefix(80))"))
            }

        case .permissionDenied(let d):
            print("\n" + styled("  ⚠︎ \(d.toolName) needs approval", "33"))

        case .result(let r):
            streaming = false
            var line = "  " + dim("ttft \(r.ttftMS ?? 0)ms · dispatch \(r.timeToRequestMS ?? 0)ms")
            if let cost = r.totalCostUSD {
                line += dim(String(format: " · session total $%.4f", cost))
            }
            print("\n" + line)
            for d in r.permissionDenials {
                let path = d.toolInput["file_path"]?.stringValue ?? "?"
                let bytes = d.toolInput["content"]?.stringValue?.count ?? 0
                print(dim("  blocked \(d.toolName) → \(path) (\(bytes) bytes withheld)"))
            }
            print("")
            turnComplete.continuation.yield(r)

        case .unrecognized(let type, _):
            // Not an error — the protocol is undocumented and expected to grow.
            print(dim("  [unrecognized event: \(type)]"))

        default:
            break
        }
    }
    turnComplete.continuation.finish()
}

/// Await the next `result`, so turns don't interleave in the transcript.
func awaitTurn() async -> RunResult? {
    var it = turnComplete.stream.makeAsyncIterator()
    return await it.next()
}

if benchmark {
    let prompts = [
        "Reply with exactly the word PONG and nothing else.",
        "What word did I just ask you to reply with? Answer in one word.",
        "Count from 1 to 20, separated by spaces. No other text.",
    ]
    var dispatches: [Int] = []
    for (i, p) in prompts.enumerated() {
        print(bold("[\(i + 1)/\(prompts.count)] ") + p)
        try await bridge.send(p)
        if let r = await awaitTurn(), let d = r.timeToRequestMS { dispatches.append(d) }
    }
    if !dispatches.isEmpty {
        let avg = dispatches.reduce(0, +) / dispatches.count
        print(bold("per-turn dispatch overhead: ") + "\(dispatches.map(String.init).joined(separator: "ms, "))ms"
              + dim("  (avg \(avg)ms — Phase 0 baseline 7–20ms)"))
        if avg > 100 { print(red("REGRESSION: average dispatch overhead exceeds 100ms")) }
    }
} else {
    while true {
        print(bold("› "), terminator: "")
        fflush(stdout)
        guard let line = readLine(strippingNewline: true) else { break }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        if text == "/quit" || text == "/exit" { break }
        try await bridge.send(text)
        _ = await awaitTurn()
    }
}

print(dim("\nshutting down…"))
await bridge.stop()
consumer.cancel()
