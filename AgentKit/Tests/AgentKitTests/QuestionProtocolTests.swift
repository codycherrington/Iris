import XCTest
@testable import AgentKit

/// `AskUserQuestion` is not available to a `claude -p` session — `system/init` lists 67 tools
/// and it isn't one of them (checked against 2.1.226). So a question Iris asks back has to
/// travel inside the assistant's own text as a fenced block. These pin the parser that pulls
/// it out, including the half-arrived states it sees on every streamed delta.
final class QuestionProtocolTests: XCTestCase {

    /// Captured verbatim from a live session on 2026-08-09, prompted with
    /// "I want to add caching to my API. Should I use Redis or in-memory? Ask me to choose."
    /// Note the sentence of prose before the block — the prompt permits that, so the parser
    /// has to keep it.
    private let liveResponse = """
        Depends on your deployment: in-memory is simpler and fine for a single instance, \
        but Redis is needed if you run multiple instances/processes that need a shared, \
        consistent cache.

        ```iris:question
        {"question": "Which caching approach fits your setup?", "options": \
        [{"label": "In-memory", "description": "Simple, no extra infra, but not shared \
        across instances."}, {"label": "Redis", "description": "Shared cache across \
        instances, persists independently, adds infra dependency."}], "multiSelect": false}
        ```
        """

    func testParsesARealCapturedResponse() {
        let result = QuestionProtocol.split(liveResponse)
        let question = try? XCTUnwrap(result.question)

        XCTAssertEqual(question?.question, "Which caching approach fits your setup?")
        XCTAssertEqual(question?.options.map(\.label), ["In-memory", "Redis"])
        XCTAssertEqual(question?.multiSelect, false)
        XCTAssertFalse(result.isPending)

        // The prose survives; the block does not.
        XCTAssertTrue(result.text.hasPrefix("Depends on your deployment"))
        XCTAssertFalse(result.text.contains("iris:question"))
        XCTAssertFalse(result.text.contains("multiSelect"))
    }

    /// The overwhelmingly common case, and the one that must cost almost nothing — this runs
    /// on every streamed delta of every message.
    func testOrdinaryTextIsUntouched() {
        let text = "Here's the answer. No question here, just prose with a ``` code fence."
        let result = QuestionProtocol.split(text)
        XCTAssertEqual(result.text, text)
        XCTAssertNil(result.question)
        XCTAssertFalse(result.isPending)
    }

    /// Mid-stream: the opening fence has arrived but the payload hasn't. Rendering the raw
    /// text here would scroll half-formed JSON through the transcript one delta at a time.
    func testPartialBlockIsPendingAndHidesItsPayload() {
        let partial = """
            Sure, quick one:

            ```iris:question
            {"question": "Which approa
            """
        let result = QuestionProtocol.split(partial)
        XCTAssertTrue(result.isPending)
        XCTAssertNil(result.question)
        XCTAssertEqual(result.text, "Sure, quick one:")
        XCTAssertFalse(result.text.contains("{"))
    }

    /// A malformed payload keeps its raw block. A question that silently disappears is much
    /// worse to diagnose than one that renders as ugly JSON.
    func testMalformedPayloadStaysVisible() {
        let broken = """
            ```iris:question
            {"question": "Missing options"}
            ```
            """
        let result = QuestionProtocol.split(broken)
        XCTAssertNil(result.question)
        XCTAssertFalse(result.isPending)
        XCTAssertTrue(result.text.contains("Missing options"),
                      "malformed blocks must not be swallowed")
    }

    /// Options are what make it a question; an empty list is malformed, not an empty picker.
    func testEmptyOptionsIsTreatedAsMalformed() {
        let empty = """
            ```iris:question
            {"question": "Nothing to pick", "options": []}
            ```
            """
        XCTAssertNil(QuestionProtocol.split(empty).question)
    }

    func testMultiSelectIsCarried() {
        let json = """
            ```iris:question
            {"question": "Which?", "options": [{"label": "A", "description": null}, \
            {"label": "B", "description": null}], "multiSelect": true}
            ```
            """
        XCTAssertEqual(QuestionProtocol.split(json).question?.multiSelect, true)
    }

    /// `description` is optional in the schema and the model does omit it.
    func testDescriptionIsOptional() {
        let json = """
            ```iris:question
            {"question": "Which?", "options": [{"label": "A"}, {"label": "B"}]}
            ```
            """
        let question = QuestionProtocol.split(json).question
        XCTAssertEqual(question?.options.count, 2)
        XCTAssertNil(question?.options.first?.description)
        XCTAssertEqual(question?.multiSelect, false, "multiSelect defaults to single-choice")
    }

    /// The system prompt is what makes the whole thing work, so pin the parts the parser
    /// depends on. If the fence in the prompt and the fence in the parser ever diverge,
    /// questions silently stop rendering.
    func testSystemPromptTeachesTheFenceTheParserLooksFor() {
        XCTAssertTrue(QuestionProtocol.systemPrompt.contains(QuestionProtocol.fence))
        XCTAssertTrue(QuestionProtocol.systemPrompt.contains("multiSelect"))
        XCTAssertTrue(QuestionProtocol.systemPrompt.contains("\"options\""))
    }
}
