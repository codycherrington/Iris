import XCTest
@testable import AgentKit

/// These replay real captured CLI output from the Phase 0 spike. They are the guard against
/// the stream-json protocol drifting underneath us: if a shape changes, these fail loudly
/// instead of the UI silently going blank.
final class AgentEventDecodingTests: XCTestCase {

    private func events(_ fixture: String) throws -> [AgentEvent] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: "ndjson"),
            "missing fixture \(fixture).ndjson")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { AgentEventDecoder.decode(line: String($0)) }
    }

    // MARK: Core transcript

    func testTranscriptDecodesWithNoUnrecognizedEvents() throws {
        let evs = try events("transcript")
        XCTAssertFalse(evs.isEmpty)
        let unknown: [String] = evs.compactMap {
            if case .unrecognized(let t, _) = $0 { return t } else { return nil }
        }
        XCTAssertTrue(unknown.isEmpty, "unhandled event types: \(Set(unknown))")
    }

    /// The load-bearing constraint of the whole project: Iris must never fall back to
    /// per-token API billing. `apiKeySource == "none"` is the runtime proof.
    func testSessionUsesSubscriptionAuthNotAPIKey() throws {
        let inits: [SystemInit] = try events("transcript").compactMap {
            if case .systemInit(let i) = $0 { return i } else { return nil }
        }
        XCTAssertFalse(inits.isEmpty, "expected at least one system/init")
        for i in inits {
            XCTAssertEqual(i.apiKeySource, "none")
            XCTAssertTrue(i.isSubscriptionAuth)
        }
    }

    /// system/init repeats per turn, not once per process — worth pinning so the UI
    /// doesn't treat a re-init as a new session.
    func testSystemInitRepeatsPerTurn() throws {
        let evs = try events("transcript")
        let inits = evs.filter { if case .systemInit = $0 { return true }; return false }
        let results = evs.filter { if case .result = $0 { return true }; return false }
        XCTAssertEqual(inits.count, results.count)
        XCTAssertEqual(results.count, 3, "spike sent three turns")
    }

    /// One persistent process serving many turns is what makes Iris as fast as the
    /// terminal. `time_to_request_ms` is that per-turn overhead.
    func testPerTurnDispatchOverheadIsNegligible() throws {
        let results: [RunResult] = try events("transcript").compactMap {
            if case .result(let r) = $0 { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 3)
        for r in results {
            let overhead = try XCTUnwrap(r.timeToRequestMS)
            XCTAssertLessThan(overhead, 100, "per-turn overhead regressed to \(overhead)ms")
            XCTAssertNotNil(r.ttftMS)
            XCTAssertFalse(r.isError)
            XCTAssertEqual(r.stopReason, "end_turn")
        }
    }

    /// total_cost_usd accumulates across the session. Anything showing per-turn cost
    /// must diff consecutive results.
    func testTotalCostIsCumulativeAcrossSession() throws {
        let costs: [Double] = try events("transcript").compactMap {
            if case .result(let r) = $0 { return r.totalCostUSD } else { return nil }
        }
        XCTAssertEqual(costs.count, 3)
        XCTAssertEqual(costs, costs.sorted(), "expected monotonically increasing cumulative cost")
        XCTAssertGreaterThan(costs[2], costs[0])
    }

    func testAssistantTextIsRecoverable() throws {
        let msgs: [Message] = try events("transcript").compactMap {
            if case .assistant(let m) = $0 { return m } else { return nil }
        }
        XCTAssertEqual(msgs.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), "PONG")
        // Main-thread messages carry no parent; subagents do.
        XCTAssertNil(msgs.first?.parentToolUseID)
    }

    func testStreamingTextDeltasReconstructTheMessage() throws {
        let deltas: String = try events("transcript").compactMap {
            if case .streamEvent(let s) = $0 { return s.textDelta } else { return nil }
        }.joined()
        XCTAssertTrue(deltas.contains("PONG"))
        XCTAssertTrue(deltas.contains("20"), "third turn counted to 20")
    }

    func testRateLimitEventIsDecodedForQuotaGauge() throws {
        let limits: [RateLimitInfo] = try events("transcript").compactMap {
            if case .rateLimit(let r) = $0 { return r } else { return nil }
        }
        let first = try XCTUnwrap(limits.first)
        XCTAssertEqual(first.status, "allowed")
        XCTAssertEqual(first.rateLimitType, "five_hour")
        XCTAssertGreaterThan(first.resetsAt, 0)
    }

    // MARK: Permission flow

    /// The Phase 5 unblocker. A denied write does NOT hang the stream: it completes the
    /// turn and hands back the full intended tool input, which is enough to render a diff
    /// and offer approval — no MCP permission server required.
    func testDeniedWriteCompletesAndExposesFullToolInput() throws {
        let evs = try events("perm_default")

        let denied: [PermissionDenied] = evs.compactMap {
            if case .permissionDenied(let d) = $0 { return d } else { return nil }
        }
        XCTAssertEqual(denied.first?.toolName, "Write")

        let result = try XCTUnwrap(evs.compactMap { ev -> RunResult? in
            if case .result(let r) = ev { return r } else { return nil }
        }.first)

        // Crucially: the turn still completes successfully rather than blocking.
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.stopReason, "end_turn")

        let denial = try XCTUnwrap(result.permissionDenials.first)
        XCTAssertEqual(denial.toolName, "Write")
        // The content it wanted to write is present — this is what the diff sheet renders.
        XCTAssertNotNil(denial.toolInput["file_path"]?.stringValue)
        XCTAssertEqual(denial.toolInput["content"]?.stringValue, "hello\n")
    }

    func testAcceptEditsModeProducesNoDenials() throws {
        let result = try XCTUnwrap(try events("perm_acceptedits").compactMap { ev -> RunResult? in
            if case .result(let r) = ev { return r } else { return nil }
        }.first)
        XCTAssertTrue(result.permissionDenials.isEmpty)
        XCTAssertFalse(result.isError)
    }

    func testToolUseAndResultBlocksDecode() throws {
        let evs = try events("perms")
        let uses = evs.compactMap { ev -> (id: String, name: String, input: [String: JSONValue])? in
            if case .assistant(let m) = ev { return m.toolUses.first } else { return nil }
        }
        XCTAssertEqual(uses.first?.name, "Read")
        XCTAssertNotNil(uses.first?.input["file_path"]?.stringValue)
    }

    // MARK: Resilience

    func testUnknownAndMalformedLinesDegradeGracefully() {
        let unknown = AgentEventDecoder.decode(line: #"{"type":"brand_new_event_2027","x":1}"#)
        guard case .unrecognized(let t, _)? = unknown else {
            return XCTFail("expected .unrecognized, got \(String(describing: unknown))")
        }
        XCTAssertEqual(t, "brand_new_event_2027")

        guard case .unrecognized? = AgentEventDecoder.decode(line: "{not json at all") else {
            return XCTFail("malformed JSON should decode to .unrecognized, not crash")
        }

        XCTAssertNil(AgentEventDecoder.decode(line: "   "))
    }

    func testEveryFixtureDecodesWithoutCrashing() throws {
        for f in ["transcript", "skills", "perms", "perm_default", "perm_acceptedits"] {
            XCTAssertFalse(try events(f).isEmpty, "\(f) produced no events")
        }
    }
}
