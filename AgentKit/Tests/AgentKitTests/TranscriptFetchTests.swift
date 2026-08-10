import XCTest
@testable import AgentKit

/// The scraper's contract is a set of one-line stdout messages and an exit status that means
/// almost nothing — every handled outcome, including the failures, exits 0. These pin the
/// parse so a change to the script shows up here rather than as a sidebar that reports
/// "fetched" for a video with no captions.
final class TranscriptFetchTests: XCTestCase {

    /// The absolute form, which is what the script actually prints. Captured from a live run
    /// after the skill's documentation turned out to describe a relative path it doesn't emit.
    func testFreshFetchWithTheAbsolutePathItActuallyPrints() {
        let line = "saved /Users/cody/Projects/PodcastInsights/transcripts/"
            + "single videos/dQw4w9WgXcQ.txt\n"
        let out = TranscriptFetch.parse(stdout: line, exitStatus: 0)
        XCTAssertEqual(out.path, "/Users/cody/Projects/PodcastInsights/transcripts/"
                       + "single videos/dQw4w9WgXcQ.txt")
        XCTAssertFalse(out.wasCached)
    }

    /// The documented relative form is still accepted. If the script is ever fixed to match
    /// its own docs, the tool keeps working rather than breaking on the correction.
    func testRelativePathStillParses() {
        let out = TranscriptFetch.parse(
            stdout: "saved transcripts/single videos/dQw4w9WgXcQ.txt\n", exitStatus: 0)
        XCTAssertEqual(out, .saved(path: "transcripts/single videos/dQw4w9WgXcQ.txt"))
    }

    /// The reason this parse doesn't split on spaces. "single videos" has one in it, and a
    /// naive `split(separator: " ")[1]` yields `transcripts/single` — a path that doesn't
    /// exist, which would surface as a file-read failure well away from the actual cause.
    func testPathContainingASpaceSurvives() {
        let out = TranscriptFetch.parse(
            stdout: "exists transcripts/single videos/abc12345678.txt", exitStatus: 0)
        XCTAssertEqual(out.path, "transcripts/single videos/abc12345678.txt")
        XCTAssertTrue(out.wasCached)
    }

    func testEachSkipReason() {
        for reason in ["TranscriptsDisabled", "NoTranscriptFound", "VideoUnavailable"] {
            let out = TranscriptFetch.parse(
                stdout: "skipped abc12345678 (\(reason))", exitStatus: 0)
            XCTAssertEqual(out, .skipped(videoID: "abc12345678", reason: reason))
        }
    }

    /// The script's catch-all prints the exception's message inline. Keeping it — rather than
    /// collapsing everything unknown to "failed" — is the difference between a report you can
    /// act on and one you can't.
    func testCatchAllSkipKeepsItsMessage() {
        let out = TranscriptFetch.parse(
            stdout: "skipped abc12345678 (error: connection reset)", exitStatus: 0)
        XCTAssertEqual(out, .skipped(videoID: "abc12345678", reason: "error: connection reset"))
        XCTAssertEqual(TranscriptFetch.explain(reason: "error: connection reset"),
                       "connection reset")
    }

    /// An unrecognised reason is passed through verbatim. A future exception name we don't
    /// have a sentence for is still more useful than "unknown error".
    func testUnknownReasonPassesThrough() {
        XCTAssertEqual(TranscriptFetch.explain(reason: "RequestBlocked"), "RequestBlocked")
    }

    /// The only non-zero exit: a link the script couldn't turn into a video id at all. It
    /// arrives as a Python traceback with nothing parseable in it.
    func testUnparseableLinkIsTheNonZeroExit() {
        let traceback = """
            Traceback (most recent call last):
              File "tokenizer.py", line 120, in <module>
            ValueError: could not extract video id from: 'https://example.com'
            """
        XCTAssertEqual(TranscriptFetch.parse(stdout: traceback, exitStatus: 1),
                       .unparseableLink)
    }

    /// Exit 0 and nothing recognised means the script's output format changed. Reported as
    /// its own case, carrying what it actually said, rather than guessed at.
    func testSilentSuccessIsItsOwnCase() {
        XCTAssertEqual(TranscriptFetch.parse(stdout: "all done!\n", exitStatus: 0),
                       .unrecognized(stdout: "all done!\n"))
    }

    /// Real runs print progress before the line that matters.
    func testFindsTheContractLineAmongOtherOutput() {
        let noisy = """
            fetching…
            saved transcripts/single videos/xyz98765432.txt
            """
        XCTAssertEqual(TranscriptFetch.parse(stdout: noisy, exitStatus: 0).path,
                       "transcripts/single videos/xyz98765432.txt")
    }
}
