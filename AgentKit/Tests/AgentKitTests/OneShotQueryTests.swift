import XCTest
@testable import AgentKit

/// Replays a real captured one-shot run (`--json-schema` + the stripped launch flags) and
/// pins the properties that make sidebar tools viable. The interesting assertions here are
/// not about decoding — they're about *cost*: an unstripped one-shot call measured 18,854
/// cache-creation tokens and 32.5 s for the same prompt this fixture answers in 7.8 s.
final class OneShotQueryTests: XCTestCase {

    /// Mirrors the schema the fixture was captured with.
    private struct PromptCritique: StructuredOutput {
        let score: Int
        let issues: [String]
        let rewrite: String

        static let jsonSchema = """
            {"type":"object","properties":{"score":{"type":"integer"},\
            "issues":{"type":"array","items":{"type":"string"}},\
            "rewrite":{"type":"string"}},\
            "required":["score","issues","rewrite"],"additionalProperties":false}
            """
    }

    private func events(_ fixture: String) throws -> [AgentEvent] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: "ndjson"),
            "missing fixture \(fixture).ndjson")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { AgentEventDecoder.decode(line: String($0)) }
    }

    private func oneShotResult() throws -> RunResult {
        let results: [RunResult] = try events("oneshot_structured").compactMap {
            if case .result(let r) = $0 { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 1, "a one-shot run emits exactly one result")
        return try XCTUnwrap(results.first)
    }

    // MARK: Protocol shape

    /// A one-shot run reuses the session decoder wholesale — no new event types. If this
    /// fails, `--json-schema` grew a shape the main transcript path won't understand either.
    func testOneShotRunDecodesWithNoUnrecognizedEvents() throws {
        let evs = try events("oneshot_structured")
        XCTAssertFalse(evs.isEmpty)
        let unknown: [String] = evs.compactMap {
            if case .unrecognized(let t, _) = $0 { return t } else { return nil }
        }
        XCTAssertTrue(unknown.isEmpty, "unhandled event types: \(Set(unknown))")
    }

    /// The hard rule applies to sidebar tools exactly as it does to the session. One-shot
    /// calls go through the same auth path, so this is the same check, not a weaker one.
    func testOneShotUsesSubscriptionAuthNotAPIKey() throws {
        let inits: [SystemInit] = try events("oneshot_structured").compactMap {
            if case .systemInit(let i) = $0 { return i } else { return nil }
        }
        XCTAssertFalse(inits.isEmpty, "expected a system/init")
        for i in inits {
            XCTAssertEqual(i.apiKeySource, "none")
            XCTAssertTrue(i.isSubscriptionAuth)
        }
    }

    // MARK: Structured output

    func testStructuredOutputDecodesIntoAConcreteType() throws {
        let critique = try oneShotResult().decodeStructuredOutput(PromptCritique.self)
        XCTAssertGreaterThan(critique.score, 0)
        XCTAssertFalse(critique.issues.isEmpty)
        XCTAssertFalse(critique.rewrite.isEmpty)
    }

    /// The CLI mirrors the payload into `result` as a string, but that's the assistant's
    /// text channel. `structured_output` is the field that means it — pinned so a future
    /// refactor doesn't quietly start parsing prose.
    func testStructuredPayloadComesFromItsOwnFieldNotResultText() throws {
        let result = try oneShotResult()
        XCTAssertNotNil(result.structuredOutputJSON)
        let fromField = try result.decodeStructuredOutput(PromptCritique.self)
        let fromText = try XCTUnwrap(result.resultText).data(using: .utf8)
            .map { try? JSONDecoder().decode(PromptCritique.self, from: $0) } ?? nil
        XCTAssertEqual(fromField.score, fromText?.score,
                       "the two channels agree today; the typed path must use the real one")
    }

    func testMissingStructuredOutputThrowsRatherThanReturningEmpty() throws {
        let results: [RunResult] = try events("transcript").compactMap {
            if case .result(let r) = $0 { return r } else { return nil }
        }
        let plain = try XCTUnwrap(results.first, "transcript has results")
        XCTAssertNil(plain.structuredOutputJSON, "a run without --json-schema has no payload")
        XCTAssertThrowsError(try plain.decodeStructuredOutput(PromptCritique.self))
    }

    // MARK: Cost — the reason this type exists

    /// The regression guard. Sidebar tools are only usable because the stripped launch
    /// rebuilds nothing: a default one-shot call measured 18,854 cache-creation tokens for
    /// this exact prompt. If a flag stops working, this catches it before the sidebar does.
    func testStrippedLaunchPaysNoColdStart() throws {
        let usage = try XCTUnwrap(oneShotResult().usage)
        let created = try XCTUnwrap(usage.cacheCreationInputTokens)
        XCTAssertEqual(created, 0, "cold start returned: \(created) cache-creation tokens")
    }

    /// Sidebar tools run on Haiku. Inheriting the session's model silently turned a
    /// four-word query into 1,932 Opus output tokens during the spike.
    func testOneShotRunsOnHaikuOnly() throws {
        let models = try oneShotResult().modelUsage.keys.sorted()
        XCTAssertEqual(models.count, 1, "more than one model billed: \(models)")
        let model = try XCTUnwrap(models.first)
        XCTAssertTrue(model.contains("haiku"), "sidebar tool ran on \(model)")
    }

    /// Not a perf gate — a *quota* gate. Anything past a couple of seconds here means the
    /// call is doing work a sidebar shouldn't.
    func testOneShotStaysWellUnderTheSessionColdStart() throws {
        let duration = try XCTUnwrap(oneShotResult().durationMS)
        XCTAssertLessThan(duration, 20_000, "one-shot ballooned to \(duration)ms")
    }

    // MARK: Launch arguments

    /// Each of these flags was added because removing it cost measurable tokens. The test
    /// exists so nobody trims the list to make the command line tidier.
    func testArgumentsStripEverythingThatCostsTokens() {
        let config = OneShotConfiguration(systemPrompt: "Review prompts.")
        let args = config.arguments(prompt: "hi", schema: PromptCritique.jsonSchema)

        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }

        XCTAssertEqual(value(after: "--model"), "haiku")
        XCTAssertEqual(value(after: "--tools"), "", "empty --tools is what zeroes the cache")
        XCTAssertEqual(value(after: "--setting-sources"), "", "no CLAUDE.md, skills or plugins")
        XCTAssertEqual(value(after: "--system-prompt"), "Review prompts.")
        XCTAssertTrue(args.contains("--exclude-dynamic-system-prompt-sections"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--disable-slash-commands"))
        XCTAssertTrue(args.contains("--no-session-persistence"))

        // stream-json rather than json exists solely so system/init is visible for the
        // subscription-auth assertion; --verbose is required alongside it.
        XCTAssertEqual(value(after: "--output-format"), "stream-json")
        XCTAssertTrue(args.contains("--verbose"))

        // Appending would keep the full Claude Code system prompt — most of the cold start.
        XCTAssertFalse(args.contains("--append-system-prompt"))
    }

    // MARK: Pre-flight auth

    /// `claude auth status --json` is the only way to know a session's auth *before* it
    /// takes a turn, since `system/init` is per-turn. These pin the field that decides it.
    ///
    /// Note it reads a missing key and an explicit `null` identically — the CLI omits
    /// `apiKeySource` entirely on the subscription path but emits it as null elsewhere, and
    /// both mean "no key involved".
    func testAuthStatusTreatsAbsentKeySourceAsSubscription() throws {
        let json = """
            {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
             "email":"x@example.com","subscriptionType":"pro"}
            """
        let status = try decodeAuthStatus(json)
        XCTAssertTrue(status.isSubscriptionAuth)
        XCTAssertEqual(status.subscriptionType, "pro")
        XCTAssertNil(status.apiKeySource)
    }

    /// The shape observed with `ANTHROPIC_API_KEY` set: the key source appears and every
    /// subscription field goes null. This must never read as subscription auth.
    func testAuthStatusWithAKeyIsNotSubscription() throws {
        let json = """
            {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
             "apiKeySource":"ANTHROPIC_API_KEY","email":null,"subscriptionType":null}
            """
        let status = try decodeAuthStatus(json)
        XCTAssertFalse(status.isSubscriptionAuth,
                       "a key in play must never be reported as subscription auth")
        XCTAssertEqual(status.apiKeySource, "ANTHROPIC_API_KEY")
    }

    func testLoggedOutIsNotSubscription() throws {
        let status = try decodeAuthStatus(#"{"loggedIn":false}"#)
        XCTAssertFalse(status.isSubscriptionAuth)
    }

    /// Mirrors `AuthProbe.check`'s parsing without launching the CLI, so the suite stays
    /// hermetic. If the two ever drift this test is worthless — keep them together.
    private func decodeAuthStatus(_ json: String) throws -> AuthStatus {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        return AuthStatus(
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            authMethod: obj["authMethod"] as? String,
            apiProvider: obj["apiProvider"] as? String,
            apiKeySource: obj["apiKeySource"] as? String,
            subscriptionType: obj["subscriptionType"] as? String,
            email: obj["email"] as? String)
    }

    func testDefaultsAreTheCheapOnes() {
        let config = OneShotConfiguration(systemPrompt: "x")
        XCTAssertEqual(config.model, "haiku")
        XCTAssertTrue(config.tools.isEmpty)
        XCTAssertTrue(config.requireSubscriptionAuth)
    }

    func testColdStartFlagReflectsCacheCreation() throws {
        let usage = OneShotUsage(result: try oneShotResult())
        XCTAssertFalse(usage.didPayColdStart)
        XCTAssertEqual(usage.cacheCreationTokens, 0)
    }

    /// `result.usage` and `result.modelUsage` disagree: the fixture reports 956/542 against
    /// a modelUsage total of 1482/556. The 526-in/14-out shortfall is a hidden internal CLI
    /// call, and it was present on the Opus run too — a fixed cost, not noise. A quota meter
    /// reading `usage` would silently under-report every sidebar call.
    func testUsageBlockUndercountsModelUsage() throws {
        let result = try oneShotResult()
        let block = try XCTUnwrap(result.usage)
        let summed = OneShotUsage(result: result)

        XCTAssertEqual(block.inputTokens, 956)
        XCTAssertEqual(summed.inputTokens, 1482, "OneShotUsage must sum modelUsage")
        XCTAssertEqual(summed.inputTokens - (block.inputTokens ?? 0), 526)
        XCTAssertEqual(summed.outputTokens - (block.outputTokens ?? 0), 14)
    }

    /// The heaviest model by output tokens, not the alphabetically first — sorting by name
    /// would report "haiku" for a run that escalated to Opus, hiding the one thing this
    /// type exists to catch.
    func testPrimaryModelIsTheHeaviestNotTheAlphabeticallyFirst() {
        let escalated = RunResult(
            sessionID: "s", subtype: "success", isError: false, stopReason: "tool_use",
            resultText: nil, numTurns: 2, ttftMS: nil, ttftStreamMS: nil,
            timeToRequestMS: nil, durationMS: 1, durationAPIMS: nil, totalCostUSD: 0.237,
            modelUsage: [
                "claude-haiku-4-5": .init(inputTokens: 526, outputTokens: 14,
                                          cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
                                          costUSD: 0.0006, contextWindow: nil,
                                          maxOutputTokens: nil),
                "claude-opus-5": .init(inputTokens: 2, outputTokens: 1932,
                                       cacheReadInputTokens: 0,
                                       cacheCreationInputTokens: 18_854,
                                       costUSD: 0.2368, contextWindow: nil,
                                       maxOutputTokens: nil),
            ],
            permissionDenials: [], structuredOutputJSON: nil, usage: nil)

        let usage = OneShotUsage(result: escalated)
        XCTAssertEqual(usage.model, "claude-opus-5", "alphabetical order would say haiku")
        XCTAssertEqual(usage.models.count, 2)
        XCTAssertTrue(usage.didPayColdStart)
    }
}
