import Foundation

/// Runs the PodcastInsights `tokenizer.py` scraper and makes sense of what it printed.
///
/// Lives in `AgentKit` rather than beside the sidebar tool for one reason: **the interesting
/// part is parsing, and the `Iris` target can't be imported by the test target.** Same argument
/// as `QuestionProtocol` in ADR-010. The script's contract is a set of one-line stdout
/// messages, which is exactly the kind of thing that rots silently if nothing pins it.
///
/// The contract, **taken from a live run**, not from the script's documentation:
///
/// ```
/// saved /abs/…/transcripts/single videos/<id>.txt    freshly fetched          exit 0
/// exists /abs/…/transcripts/single videos/<id>.txt   already on disk          exit 0
/// skipped <id> (TranscriptsDisabled)                 captions off             exit 0
/// skipped <id> (NoTranscriptFound)                   no English transcript    exit 0
/// skipped <id> (VideoUnavailable)                    private or deleted       exit 0
/// skipped <id> (error: …)                            anything else it caught  exit 0
/// (Python traceback, on stderr)                      unparseable link         exit 1
/// ```
///
/// Two details only a live run gives you:
///
/// - **The path is absolute.** The `youtube-transcript` skill documents it as
///   `saved transcripts/single videos/<id>.txt`, and the script actually prints a `Path` built
///   from `Path(__file__).resolve().parent` — fully qualified. Both forms work, because
///   resolving an absolute path against a base ignores the base, but the shipping case is the
///   absolute one and the tests pin that.
/// - **Every handled outcome exits 0**, the failures included. Only an unparseable link exits
///   non-zero. Exit status alone therefore tells you almost nothing: the *line* is the
///   contract. A run printing none of these is a case of its own, reported as what it is
///   rather than forced into one of the others.
public enum TranscriptFetch {

    public enum Outcome: Sendable, Equatable {
        /// Fetched this run. `path` is exactly as printed — absolute, in practice.
        case saved(path: String)
        /// Already on disk from a previous run. Same file, no network.
        case cached(path: String)
        /// The script declined, for a reason it named. Not an error in the script.
        case skipped(videoID: String, reason: String)
        /// Non-zero exit — the link couldn't be parsed into a video id at all.
        case unparseableLink
        /// Exit 0 with nothing recognisable on stdout. Means the script changed.
        case unrecognized(stdout: String)

        public var path: String? {
            switch self {
            case .saved(let p), .cached(let p): return p
            default: return nil
            }
        }

        public var wasCached: Bool {
            if case .cached = self { return true }
            return false
        }
    }

    /// Human-readable version of the reasons the script prints, which are Python exception
    /// class names. Unknown reasons pass through verbatim rather than becoming "unknown error"
    /// — a name we don't recognise is still more useful than one we've thrown away.
    public static func explain(reason: String) -> String {
        switch reason {
        case "TranscriptsDisabled": return "Captions are turned off for this video."
        case "NoTranscriptFound": return "No English transcript is available for this video."
        case "VideoUnavailable": return "The video is private, deleted, or unavailable."
        default:
            return reason.hasPrefix("error: ")
                ? String(reason.dropFirst("error: ".count))
                : reason
        }
    }

    public static func parse(stdout: String, exitStatus: Int32) -> Outcome {
        // Checked before the exit status: the script exits 0 for every outcome it handles,
        // so a recognised line is authoritative and a non-zero exit only means "none of the
        // above happened".
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            // `dropFirst(n)` on the prefix rather than a split on spaces: the path contains a
            // space ("single videos") and splitting would truncate it to "transcripts/single".
            if text.hasPrefix("saved ") {
                return .saved(path: String(text.dropFirst("saved ".count)))
            }
            if text.hasPrefix("exists ") {
                return .cached(path: String(text.dropFirst("exists ".count)))
            }
            if text.hasPrefix("skipped "), let open = text.firstIndex(of: "("),
               text.hasSuffix(")") {
                let id = text[text.index(text.startIndex, offsetBy: "skipped ".count)..<open]
                let reason = text[text.index(after: open)..<text.index(before: text.endIndex)]
                return .skipped(videoID: id.trimmingCharacters(in: .whitespaces),
                                reason: String(reason))
            }
        }
        return exitStatus == 0 ? .unrecognized(stdout: stdout) : .unparseableLink
    }
}
