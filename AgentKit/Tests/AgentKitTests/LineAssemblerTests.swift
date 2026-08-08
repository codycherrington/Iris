import XCTest
@testable import AgentKit

/// A pipe hands over whatever bytes happen to be available, so JSON events routinely arrive
/// split across reads. If reassembly is wrong the symptom is truncated JSON that looks
/// exactly like protocol drift — so these cases are pinned explicitly.
final class LineAssemblerTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    func testCompleteLinesInOneChunk() {
        let a = LineAssembler()
        XCTAssertEqual(a.append(d("one\ntwo\nthree\n")), ["one", "two", "three"])
    }

    func testPartialLineIsHeldUntilTerminated() {
        let a = LineAssembler()
        XCTAssertEqual(a.append(d("hel")), [])
        XCTAssertEqual(a.append(d("lo")), [])
        XCTAssertEqual(a.append(d("\n")), ["hello"])
    }

    /// The realistic failure: one JSON object split mid-token across two reads.
    func testJSONSplitAcrossChunkBoundary() {
        let a = LineAssembler()
        let json = #"{"type":"assistant","message":{"role":"assistant"}}"#
        let cut = json.index(json.startIndex, offsetBy: 20)

        XCTAssertEqual(a.append(d(String(json[..<cut]))), [])
        let lines = a.append(d(String(json[cut...]) + "\n"))
        XCTAssertEqual(lines, [json])
        XCTAssertNotNil(AgentEventDecoder.decode(line: lines[0]))
    }

    func testTrailingPartialSurvivesAcrossManyChunks() {
        let a = LineAssembler()
        XCTAssertEqual(a.append(d("first\nsec")), ["first"])
        XCTAssertEqual(a.append(d("ond\nthi")), ["second"])
        XCTAssertEqual(a.append(d("rd\n")), ["third"])
    }

    func testEmptyLinesAreSkipped() {
        let a = LineAssembler()
        XCTAssertEqual(a.append(d("a\n\n\nb\n")), ["a", "b"])
    }

    func testFlushReturnsUnterminatedTail() {
        let a = LineAssembler()
        XCTAssertEqual(a.append(d("done\nleftover")), ["done"])
        XCTAssertEqual(a.flush(), "leftover")
        XCTAssertNil(a.flush(), "flush should drain the buffer")
    }

    func testFlushIsNilWhenNothingBuffered() {
        let a = LineAssembler()
        XCTAssertEqual(a.append(d("clean\n")), ["clean"])
        XCTAssertNil(a.flush())
    }

    /// Multi-byte UTF-8 split mid-character must not corrupt the line.
    func testMultiByteCharacterSplitAcrossChunks() {
        let a = LineAssembler()
        let text = "café ☕️ 日本語"
        var bytes = Array(text.utf8)
        bytes.append(0x0A)
        let mid = bytes.count / 2

        _ = a.append(Data(bytes[..<mid]))
        let lines = a.append(Data(bytes[mid...]))
        XCTAssertEqual(lines, [text])
    }

    /// Byte-at-a-time is the worst case and should still reassemble exactly.
    func testByteAtATimeDelivery() {
        let a = LineAssembler()
        let json = #"{"type":"result","subtype":"success"}"#
        var out: [String] = []
        for byte in Array((json + "\n").utf8) {
            out += a.append(Data([byte]))
        }
        XCTAssertEqual(out, [json])
    }

    /// A realistic burst: many events in one read, ending mid-line.
    func testLargeBurstWithTrailingPartial() {
        let a = LineAssembler()
        let events = (0..<500).map { #"{"type":"stream_event","i":\#($0)}"# }
        let blob = events.joined(separator: "\n") + "\n" + #"{"type":"partial"#

        let lines = a.append(d(blob))
        XCTAssertEqual(lines.count, 500)
        XCTAssertEqual(lines.first, events.first)
        XCTAssertEqual(lines.last, events.last)
        XCTAssertEqual(a.flush(), #"{"type":"partial"#)
    }

    func testCarriageReturnsArePreservedNotTreatedAsTerminators() {
        let a = LineAssembler()
        XCTAssertEqual(a.append(d("has\rcr\n")), ["has\rcr"])
    }
}
