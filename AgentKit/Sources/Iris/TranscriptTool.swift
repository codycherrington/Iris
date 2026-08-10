import AgentKit
import AppKit
import Foundation
import Observation
import SwiftUI

/// Fetches a YouTube transcript by driving the PodcastInsights scraper.
///
/// **No model call.** The second tool in the rail that spends no quota, and the first one that
/// does real work without one — a reminder that "sidebar tool" doesn't have to mean "small
/// Haiku call". The `youtube-transcript` skill already wraps this same script for the
/// conversation; this exists so the transcript can go to the clipboard without going through
/// a turn first, which is the whole point when the transcript is 40,000 words and the thing
/// you want to do with it is paste it somewhere else.
///
/// The script's location is configurable and persisted, because hardcoding a path into
/// another one of Cody's projects would make the tool dead on any other machine, and dead in a
/// way that reads as a bug rather than as a setting.
@MainActor
@Observable
final class TranscriptTool: SidebarTool {
    nonisolated let id = "youtube-transcript"
    nonisolated let title = "YouTube transcript"
    nonisolated let symbol = "text.quote"
    nonisolated var tint: Color { Tok.Palette.tool }
    nonisolated let blurb = "Paste a video link, get the transcript on the clipboard. No model call."
    nonisolated let usesModel = false

    struct Transcript: Sendable {
        let videoID: String
        let text: String
        let fileURL: URL
        let wasCached: Bool

        /// Whitespace-separated, which is close enough for "is this the length I expected"
        /// and doesn't pretend to be a token count.
        var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    enum Phase {
        case idle
        case running
        case failed(String)
        case done(Transcript)
    }

    var link = ""
    private(set) var phase: Phase = .idle
    private(set) var projectRoot: URL
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { return true }; return false }

    /// Where the scraper is expected to live. Wrong on any machine but Cody's, which is why
    /// it's a starting point rather than a constant — `locate(_:)` overrides and persists it.
    private static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/Development/Projects/PodcastInsights")

    private static var settingsURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Iris", isDirectory: true)
            .appendingPathComponent("transcript-tool.json")
    }

    init() {
        let stored = (try? Data(contentsOf: Self.settingsURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        projectRoot = stored?["projectRoot"].map { URL(fileURLWithPath: $0) }
            ?? Self.defaultRoot
    }

    func makeView() -> AnyView { AnyView(TranscriptToolView(tool: self)) }

    // MARK: Locations

    /// `<root>/.venv/bin/python`, not whatever `python3` is on `PATH`. The scraper's
    /// dependencies live in that virtualenv, so the system interpreter would fail on import
    /// with a message about `youtube_transcript_api` that says nothing about the real cause.
    private var interpreter: URL {
        projectRoot.appendingPathComponent(".venv/bin/python")
    }

    private var script: URL {
        projectRoot.appendingPathComponent("tokenizer.py")
    }

    /// True when both halves of the install are where they're expected. Checked before
    /// running so a misconfigured path reports itself as a setting rather than as a launch
    /// failure buried in a Foundation error.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: interpreter.path)
            && FileManager.default.fileExists(atPath: script.path)
    }

    var missingPieces: String {
        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: interpreter.path) {
            missing.append(".venv/bin/python")
        }
        if !FileManager.default.fileExists(atPath: script.path) { missing.append("tokenizer.py") }
        return missing.joined(separator: " and ")
    }

    func locate(_ url: URL) {
        projectRoot = url
        let payload = ["projectRoot": url.path]
        do {
            try FileManager.default.createDirectory(
                at: Self.settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(payload).write(to: Self.settingsURL, options: .atomic)
        } catch {
            NSLog("Iris: failed to persist transcript tool location — \(error)")
        }
    }

    // MARK: Fetching

    func fetch() {
        let target = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        guard isInstalled else {
            phase = .failed("Can't find \(missingPieces) under \(projectRoot.path).")
            return
        }

        task?.cancel()
        phase = .running
        let interpreter = self.interpreter, root = self.projectRoot

        task = Task {
            do {
                let (stdout, status) = try await Self.runScript(
                    interpreter: interpreter, root: root, argument: target)
                guard !Task.isCancelled else { return }
                try Task.checkCancellation()
                phase = try resolve(TranscriptFetch.parse(stdout: stdout, exitStatus: status),
                                    root: root)
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
        link = ""
        phase = .idle
    }

    private func resolve(_ outcome: TranscriptFetch.Outcome, root: URL) throws -> Phase {
        switch outcome {
        case .saved(let path), .cached(let path):
            // The script prints an absolute path in practice and a relative one according to
            // its documentation. Resolving against the root handles both, because an absolute
            // path ignores the base — so this doesn't have to care which it got.
            let fileURL = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return .failed("The script reported \(path) but that file couldn't be read.")
            }
            return .done(Transcript(
                videoID: fileURL.deletingPathExtension().lastPathComponent,
                text: text,
                fileURL: fileURL,
                wasCached: outcome.wasCached))

        case .skipped(let id, let reason):
            return .failed("\(TranscriptFetch.explain(reason: reason))  (\(id))")

        case .unparseableLink:
            return .failed("That doesn't look like a YouTube link or an 11-character video ID.")

        case .unrecognized(let stdout):
            // Deliberately shows what it said. If the script's output format changes, the
            // person reading this needs the actual line, not a guess about it.
            return .failed("The script finished without reporting a result:\n"
                           + stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Runs off the main actor. `nonisolated` and `static` so nothing about the tool's
    /// observable state is captured into the process work.
    private nonisolated static func runScript(
        interpreter: URL, root: URL, argument: String
    ) async throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = interpreter
        // `video` is the only subcommand exposed here. The script also scrapes whole channels
        // and link lists, which is a long unattended job and the wrong shape for a sidebar.
        process.arguments = [root.appendingPathComponent("tokenizer.py").path,
                             "video", argument]
        process.currentDirectoryURL = root

        // stderr is merged in: the traceback on an unparseable link goes there, and it's the
        // only signal for that case.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Read to EOF before waiting. Waiting first deadlocks the moment the child writes
        // more than a pipe buffer, and a traceback is easily that.
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

// MARK: - View

struct TranscriptToolView: View {
    @Bindable var tool: TranscriptTool

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            TextField("Paste a YouTube link…", text: $tool.link)
                .textFieldStyle(.plain)
                .font(Tok.TypeScale.mono)
                .lineLimit(1)
                .onSubmit(tool.fetch)
                .padding(Tok.Space.tight)
                .glassEffect(Tok.Surface.interactive,
                             in: .rect(cornerRadius: Tok.Radius.chip))

            HStack(spacing: Tok.Space.tight) {
                if tool.isRunning {
                    Button("Cancel") { tool.cancel() }
                        .buttonStyle(.glass)
                        .font(Tok.TypeScale.label)
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("fetching · no model call")
                            .font(Tok.TypeScale.label)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Fetch", action: tool.fetch)
                        .buttonStyle(.glassProminent)
                        .tint(tool.tint)
                        .font(Tok.TypeScale.label)
                        .disabled(tool.link.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty)
                    if case .done = tool.phase {
                        Button("Clear") { tool.reset() }
                            .buttonStyle(.glass)
                            .font(Tok.TypeScale.label)
                    }
                }
                Spacer(minLength: 0)
            }

            switch tool.phase {
            case .idle, .running:
                EmptyView()

            case .failed(let message):
                VStack(alignment: .leading, spacing: 5) {
                    Text(message)
                        .font(Tok.TypeScale.label)
                        .foregroundStyle(Tok.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    // Only offered when the install is the problem. A relocate button beside
                    // "captions are turned off" would be a suggestion to fix the wrong thing.
                    if !tool.isInstalled {
                        Button("Locate PodcastInsights…", action: locate)
                            .buttonStyle(.glass)
                            .font(Tok.TypeScale.label)
                    }
                }

            case .done(let transcript):
                result(transcript)
            }
        }
    }

    /// Copy-first, deliberately. A podcast transcript is tens of thousands of words and this
    /// rail is 320pt wide — no amount of layout makes reading it here a good idea. The preview
    /// is evidence that the right video came back; the button is the thing you came for.
    @ViewBuilder
    private func result(_ transcript: TranscriptTool.Transcript) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            HStack(spacing: Tok.Space.tight) {
                Text(transcript.videoID)
                    .font(Tok.TypeScale.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                CopyButton(text: transcript.text)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([transcript.fileURL])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassCircle)
                .help("Reveal in Finder")
            }

            HStack(spacing: 4) {
                Text("\(transcript.wordCount.formatted()) words")
                // Saying which is worth a word: "cached" is why it came back instantly, and
                // the reason a re-fetch of a since-updated video won't change anything.
                Text("·")
                Text(transcript.wasCached ? "already on disk" : "fetched")
                    .foregroundStyle(transcript.wasCached ? Tok.Palette.warn : .secondary)
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)

            ScrollView {
                Text(transcript.text)
                    .font(Tok.TypeScale.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = tool.projectRoot.deletingLastPathComponent()
        panel.message = "Choose the PodcastInsights project folder"
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tool.locate(url)
        tool.fetch()
    }
}
