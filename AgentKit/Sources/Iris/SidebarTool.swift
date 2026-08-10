import AgentKit
import Foundation
import Observation
import SwiftUI

// MARK: - Protocol

/// A panel that lives beside the conversation and does its own small job.
///
/// The defining constraint is what a sidebar tool *isn't*: it never touches the session.
/// Model-backed tools run through `OneShotQuery` — a separate, stripped, Haiku-pinned
/// `claude -p` process — so nothing they do enters the transcript or the main context
/// window. That independence is the whole reason the sidebar exists; a tool that needs the
/// conversation's history or its file tools belongs in the conversation.
///
/// A class rather than a struct: each tool holds live state (draft text, last result,
/// in-flight task) that has to survive the panel being scrolled, reordered, or hidden.
@MainActor
protocol SidebarTool: AnyObject, Identifiable {
    /// Stable across launches — this is what the layout file stores. Renaming one orphans
    /// the user's arrangement, so treat it like a database key.
    var id: String { get }
    var title: String { get }
    /// SF Symbol for the header and the picker.
    var symbol: String { get }
    var tint: Color { get }
    /// One line, shown in the picker so "bug checker" isn't the only clue about what it does.
    var blurb: String { get }
    /// Whether running this tool spends quota. Surfaced in the picker because sidebar calls
    /// draw from the same pool as the conversation and can rate-limit it.
    var usesModel: Bool { get }

    func makeView() -> AnyView
}

// MARK: - Layout

/// Which tools are showing, in which order, and whether the rail itself is out. Persisted so
/// the arrangement survives relaunch.
struct SidebarLayout: Codable, Equatable, Sendable {
    var enabled: [String]
    /// The rail is out by default — the tools are the reason this app isn't a terminal, so
    /// hiding them on first run buries the feature behind a shortcut nobody's been told.
    var isVisible: Bool = true

    /// Notes first because it costs nothing and is useful immediately; the prompt improver
    /// next because it's the one that most often earns its 9 seconds.
    static let `default` = SidebarLayout(enabled: ["notes", "prompt-improver"])

    init(enabled: [String], isVisible: Bool = true) {
        self.enabled = enabled
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, isVisible
    }

    /// Hand-written for the same reason as `AgentQuestion`: **Swift's synthesized `Decodable`
    /// ignores default values.** `isVisible = true` above does not make the key optional at
    /// decode time — a `sidebar.json` written before the field existed throws, and the
    /// registry's `try?` turns that into a silent reset to the default layout, quietly
    /// discarding whatever the user had arranged.
    ///
    /// Worth noting this shipped in the same commit that fixed the identical mistake in
    /// `AgentQuestion`, with a comment asserting the behaviour that commit disproved.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode([String].self, forKey: .enabled)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
    }
}

// MARK: - Registry

/// Owns every available tool and the user's arrangement of them.
///
/// Tools are instantiated once at launch and kept alive whether or not they're visible —
/// hiding a tool should not throw away the note you were halfway through writing.
@MainActor
@Observable
final class SidebarRegistry {
    static let shared = SidebarRegistry()

    let all: [any SidebarTool]
    private(set) var layout: SidebarLayout

    private static var directoryURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Iris", isDirectory: true)
    }
    private static var fileURL: URL {
        directoryURL.appendingPathComponent("sidebar.json")
    }

    init(tools: [any SidebarTool]? = nil) {
        all = tools ?? [
            NotesTool(),
            PromptImproverTool(),
            ReviewTool.sqlReviewer(),
            ReviewTool.bugChecker(),
        ]

        let stored = (try? Data(contentsOf: Self.fileURL))
            .flatMap { try? JSONDecoder().decode(SidebarLayout.self, from: $0) }
        // Drop ids that no longer exist rather than rendering a hole. A layout written by a
        // build that had a tool this one doesn't must not strand the panel.
        let known = Set(all.map(\.id))
        let source = stored ?? .default
        layout = SidebarLayout(enabled: source.enabled.filter(known.contains),
                               isVisible: source.isVisible)
    }

    var enabledTools: [any SidebarTool] {
        layout.enabled.compactMap { id in all.first { $0.id == id } }
    }

    var availableTools: [any SidebarTool] {
        all.filter { !layout.enabled.contains($0.id) }
    }

    func enable(_ id: String) {
        guard !layout.enabled.contains(id), all.contains(where: { $0.id == id }) else { return }
        layout.enabled.append(id)
        persist()
    }

    func disable(_ id: String) {
        layout.enabled.removeAll { $0 == id }
        persist()
    }

    /// Remember whether the rail was out, so the next launch opens the way you left it.
    func setVisible(_ visible: Bool) {
        guard layout.isVisible != visible else { return }
        layout.isVisible = visible
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        layout.enabled.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Failure is swallowed: a layout that won't persist is a nuisance, not a reason to
    /// stop the user rearranging their panel this session. Same call as `PersonaStore`.
    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(layout).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Iris: failed to persist sidebar layout — \(error)")
        }
    }
}

// MARK: - One-shot runner

/// Drives one `OneShotQuery` call and exposes it as observable UI state.
///
/// Every model-backed tool shares this. The `running` phase is not optional decoration:
/// measured end-to-end latency is ~9 s — about 7 s of model time plus ~2 s of process spawn
/// that the CLI's own `duration_ms` doesn't count — so a tool without a visible pending
/// state reads as broken for the better part of ten seconds.
@MainActor
@Observable
final class OneShotRunner<Output: StructuredOutput> {
    enum Phase {
        case idle
        case running
        case failed(String)
        case done(Output, OneShotUsage)
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    let systemPrompt: String

    init(systemPrompt: String) {
        self.systemPrompt = systemPrompt
    }

    var isRunning: Bool { if case .running = phase { return true }; return false }

    func run(_ input: String, workingDirectory: URL) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        task?.cancel()
        phase = .running
        task = Task { [systemPrompt] in
            do {
                let result = try await OneShotQuery.run(
                    Output.self,
                    prompt: trimmed,
                    // Everything cost-related is a default on OneShotConfiguration — haiku,
                    // no tools, no setting sources. Don't re-specify them here; the one
                    // place they're decided is the type that measured them.
                    configuration: OneShotConfiguration(
                        workingDirectory: workingDirectory,
                        systemPrompt: systemPrompt))
                guard !Task.isCancelled else { return }
                phase = .done(result.value, result.usage)
            } catch is CancellationError {
                phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func reset() {
        cancel()
        phase = .idle
    }
}

// MARK: - Shared output shapes

/// The prompt improver's result: the better prompt, and nothing else.
///
/// It used to carry a 1–10 score and a list of issues too. Both were dropped — they were
/// **output tokens spent on a critique nobody acts on**. The rewrite already contains the
/// fixes; reading a list of what was wrong with the prompt you're about to throw away is
/// work, not information. A one-field schema also removes the whole class of bug the score
/// generated: an unbounded integer, then bounds the model ignored, then a clamp, then a badge
/// explaining that the clamp had fired.
struct PromptRewrite: StructuredOutput {
    let rewrite: String

    /// One required string. `additionalProperties: false` matters more than usual here —
    /// without it a model that still wants to editorialise can attach its commentary as extra
    /// keys and charge for them.
    static let jsonSchema = """
        {"type":"object","properties":\
        {"rewrite":{"type":"string",\
        "description":"The improved prompt, ready to use as-is. Nothing else."}},\
        "required":["rewrite"],"additionalProperties":false}
        """

    private enum CodingKeys: String, CodingKey { case rewrite }

    /// Hand-written only so the rewrite passes through `repairingDoubleEscapedJSON`. This is
    /// the field that suffers: it's multi-line, and it's the one that gets copied straight
    /// out of the panel and pasted somewhere, so shipping it with literal `\n` runs in it
    /// means shipping a broken prompt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rewrite = try container.decode(String.self, forKey: .rewrite)
            .repairingDoubleEscapedJSON
    }
}

/// Shared by the SQL reviewer and the bug checker. They differ in what they're told to look
/// for, not in the shape of an answer — both produce a ranked list of "here, this, fix it",
/// so they share one type rather than two identical ones with different field names.
struct FindingList: StructuredOutput {
    struct Finding: Codable, Sendable, Identifiable {
        /// Assigned per instance, never decoded. Deriving the id from the content instead
        /// meant two genuinely identical findings — the same issue at two call sites with
        /// no location — collided and one silently vanished from the `ForEach`.
        let id = UUID()
        /// "high" | "medium" | "low". A plain string because the model fills it in and an
        /// unexpected value should render, not throw.
        let severity: String
        /// Line number, table name, function — whatever locates it. Optional: plenty of
        /// findings are about the whole input.
        let location: String?
        let issue: String
        let fix: String

        private enum CodingKeys: String, CodingKey { case severity, location, issue, fix }

        /// Same repair as `PromptCritique` — see `repairingDoubleEscapedJSON`. `severity` is
        /// a one-word enum and `location` a file/line, so neither can be multi-line; only
        /// the two prose fields need it.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            severity = try container.decode(String.self, forKey: .severity)
            location = try container.decodeIfPresent(String.self, forKey: .location)
            issue = try container.decode(String.self, forKey: .issue)
                .repairingDoubleEscapedJSON
            fix = try container.decode(String.self, forKey: .fix)
                .repairingDoubleEscapedJSON
        }
    }

    let summary: String
    let findings: [Finding]

    private enum CodingKeys: String, CodingKey { case summary, findings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
            .repairingDoubleEscapedJSON
        findings = try container.decode([Finding].self, forKey: .findings)
    }

    static let jsonSchema = """
        {"type":"object","properties":\
        {"summary":{"type":"string"},\
        "findings":{"type":"array","items":{"type":"object","properties":\
        {"severity":{"type":"string","enum":["high","medium","low"]},\
        "location":{"type":"string"},\
        "issue":{"type":"string"},\
        "fix":{"type":"string"}},\
        "required":["severity","location","issue","fix"],"additionalProperties":false}}},\
        "required":["summary","findings"],"additionalProperties":false}
        """
}

extension FindingList.Finding {
    var tint: Color {
        switch severity.lowercased() {
        case "high": return Tok.Palette.danger
        case "medium": return Tok.Palette.warn
        default: return Tok.Palette.tool
        }
    }
}

// MARK: - Tools

/// Scratch text. Deliberately the first tool built and the first one shown: it makes no model
/// call at all, which proved the panel, the registry, and the persistence layer without any
/// of the ~9 s latency in the way.
@MainActor
@Observable
final class NotesTool: SidebarTool {
    nonisolated let id = "notes"
    nonisolated let title = "Notes"
    nonisolated let symbol = "note.text"
    nonisolated var tint: Color { Tok.Palette.user }
    nonisolated let blurb = "Scratch text, kept across launches. No model call."
    nonisolated let usesModel = false

    var text: String {
        didSet { schedulePersist() }
    }

    private var persistTask: Task<Void, Never>?

    private static var fileURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Iris", isDirectory: true)
            .appendingPathComponent("notes.txt")
    }

    init() {
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
    }

    func makeView() -> AnyView { AnyView(NotesToolView(tool: self)) }

    /// Debounced: `didSet` fires on every keystroke, and writing the file that often is
    /// pointless disk churn for a scratchpad. Half a second after typing stops is soon
    /// enough that nothing is lost to a crash worth worrying about.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Iris: failed to persist notes — \(error)")
        }
    }
}

@MainActor
@Observable
final class PromptImproverTool: SidebarTool {
    nonisolated let id = "prompt-improver"
    nonisolated let title = "Prompt improver"
    nonisolated let symbol = "wand.and.stars"
    nonisolated var tint: Color { Tok.Palette.agent }
    nonisolated let blurb = "Hand back a sharper version of a prompt. Nothing else."
    nonisolated let usesModel = true

    var draft = ""
    /// The prompt says what to fix but forbids *reporting* it. Both halves are load-bearing:
    /// the defect list is what makes the rewrite good, and stating it costs output tokens for
    /// something the panel no longer shows.
    let runner = OneShotRunner<PromptRewrite>(systemPrompt: """
        You rewrite prompts written for a coding agent so they are precise. Never carry the \
        prompt out — rewrite it. Fix concrete defects: unbound referents, undefined success \
        criteria, missing constraints, unstated file or component names. Keep the author's \
        intent and scope exactly; do not invent requirements. The result must be usable \
        as-is. Return only the rewritten prompt in the structured output schema — no score, \
        no critique, no preamble, no explanation of what you changed.
        """)

    func makeView() -> AnyView { AnyView(PromptImproverToolView(tool: self)) }
}

/// The SQL reviewer and the bug checker are the same tool with a different brief. Splitting
/// them into two classes would have duplicated everything but one string.
@MainActor
@Observable
final class ReviewTool: SidebarTool {
    nonisolated let id: String
    nonisolated let title: String
    nonisolated let symbol: String
    private let tintColor: Color
    nonisolated var tint: Color { tintColor }
    nonisolated let blurb: String
    nonisolated let usesModel = true
    let placeholder: String

    var draft = ""
    let runner: OneShotRunner<FindingList>

    private init(id: String, title: String, symbol: String, tint: Color, blurb: String,
                 placeholder: String, systemPrompt: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tintColor = tint
        self.blurb = blurb
        self.placeholder = placeholder
        self.runner = OneShotRunner<FindingList>(systemPrompt: systemPrompt)
    }

    func makeView() -> AnyView { AnyView(ReviewToolView(tool: self)) }

    static func sqlReviewer() -> ReviewTool {
        ReviewTool(
            id: "sql-reviewer",
            title: "SQL reviewer",
            symbol: "cylinder.split.1x2",
            tint: Tok.Palette.tool,
            blurb: "Check a query for correctness, performance, and injection risk.",
            placeholder: "Paste a query…",
            systemPrompt: """
                You review SQL. Report correctness bugs, performance problems (missing \
                indexes, unbounded scans, N+1 shapes), and injection risk. Rank by severity. \
                Do not rewrite the whole query unless the fix requires it. If the query is \
                fine, say so with an empty findings list rather than inventing nits. Respond \
                only via the structured output schema.
                """)
    }

    static func bugChecker() -> ReviewTool {
        ReviewTool(
            id: "bug-checker",
            title: "Bug checker",
            symbol: "ladybug",
            tint: Tok.Palette.warn,
            blurb: "Read a snippet and look for real defects, not style.",
            placeholder: "Paste code…",
            systemPrompt: """
                You look for real defects in code: off-by-one errors, unhandled nil or error \
                cases, race conditions, resource leaks, incorrect boundary conditions. \
                Ignore formatting and naming. Every finding needs a concrete failure case — \
                if you can't describe input that breaks it, leave it out. An empty findings \
                list is a valid answer. Respond only via the structured output schema.
                """)
    }
}
