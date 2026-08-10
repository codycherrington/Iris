import XCTest
@testable import AgentKit

/// A model occasionally escapes its own escapes when filling in a `--json-schema` string
/// field, so the decoded value carries a literal backslash-n instead of a newline. The repair
/// has to fire on exactly that and on nothing else — a blanket replace would corrupt every
/// answer that legitimately mentions an escape sequence.
final class EscapedTextTests: XCTestCase {

    /// Transcribed from the prompt improver's Rewrite panel on 2026-08-10, where it rendered
    /// as visible `\n` and `\"` runs.
    private let doubleEscaped =
        #"Update the chat interface:\n\n**1. Keybindings:**\n- Return sends.\n- Label it \"Tokens used: X / Y\"."#

    func testRepairsADoubleEscapedString() {
        let repaired = doubleEscaped.repairingDoubleEscapedJSON
        XCTAssertTrue(repaired.contains("\n"))
        XCTAssertFalse(repaired.contains(#"\n"#))
        XCTAssertTrue(repaired.contains("\"Tokens used: X / Y\""))
        XCTAssertFalse(repaired.contains(#"\""#))
    }

    /// The overwhelmingly common case: the decoder already did the work. Touching it would
    /// mean re-parsing every model string for no reason and risking a wrong answer.
    func testLeavesACorrectlyDecodedStringAlone() {
        let correct = "Line one\nLine two\n\n**Bold**"
        XCTAssertEqual(correct.repairingDoubleEscapedJSON, correct)
    }

    /// Mixed content — real newlines *and* the two characters `\` `n` — is a string that was
    /// decoded correctly and happens to discuss escapes. Not a repair candidate.
    func testLeavesMixedContentAlone() {
        let mixed = "Use this:\nprintf(\"%s\\n\")"
        XCTAssertEqual(mixed.repairingDoubleEscapedJSON, mixed)
    }

    func testLeavesPlainProseAlone() {
        let plain = "One line, nothing special."
        XCTAssertEqual(plain.repairingDoubleEscapedJSON, plain)
    }

    /// The repair re-parses the string as a JSON string body, so anything that isn't valid
    /// there has to come back untouched rather than throwing or truncating.
    func testUnparseableInputIsReturnedUnchanged() {
        // A bare quote in the middle: `"a\nb"c"` is not a valid JSON string body.
        let ragged = #"a\nb"c"#
        XCTAssertEqual(ragged.repairingDoubleEscapedJSON, ragged)

        // Trailing lone backslash.
        let dangling = #"a\nb\"#
        XCTAssertEqual(dangling.repairingDoubleEscapedJSON, dangling)
    }

    func testRepairsAcrossAnArray() {
        let issues = [#"first\nsecond"#, "already fine"]
        let repaired = issues.repairingDoubleEscapedJSON
        XCTAssertEqual(repaired[0], "first\nsecond")
        XCTAssertEqual(repaired[1], "already fine")
    }

    /// The known false positive, pinned deliberately: a single-line string that only
    /// *mentions* an escape gets rewritten. Recorded so the trade-off is visible rather than
    /// discovered later as a surprise.
    func testKnownFalsePositiveIsRewritten() {
        let mention = #"Separate the fields with \n between them."#
        XCTAssertEqual(mention.repairingDoubleEscapedJSON,
                       "Separate the fields with \n between them.")
    }
}
