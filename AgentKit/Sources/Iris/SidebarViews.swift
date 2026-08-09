import AgentKit
import SwiftUI

// MARK: - Panel

/// The right-hand rail. One glass card per enabled tool, stacked.
struct SidebarPanel: View {
    @Bindable var registry: SidebarRegistry
    let workingDirectory: URL
    let onClose: () -> Void

    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if registry.enabledTools.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // Each card is its own glass shape; fusion stays at 0 so stacked tools
                    // read as separate panels rather than welding into one slab — the same
                    // problem the transcript hit with message bubbles.
                    GlassEffectContainer(spacing: Tok.Fusion.sidebar) {
                        VStack(spacing: Tok.Space.snug) {
                            ForEach(registry.enabledTools, id: \.id) { tool in
                                SidebarToolCard(
                                    tool: tool,
                                    workingDirectory: workingDirectory,
                                    onRemove: { registry.disable(tool.id) })
                            }
                        }
                        .padding(.horizontal, Tok.Space.snug)
                        .padding(.bottom, Tok.Space.snug)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 320)
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            SidebarToolPicker(registry: registry)
        }
    }

    private var header: some View {
        HStack(spacing: Tok.Space.tight) {
            Text("Tools")
                .font(Tok.TypeScale.title)
            Spacer()
            Button { showingPicker = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .glassEffect(Tok.Surface.interactive, in: .circle)
            .help("Add a tool")
            .disabled(registry.availableTools.isEmpty)

            Button(action: onClose) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .glassEffect(Tok.Surface.interactive, in: .circle)
            .help("Hide tools (⌘⌥S)")
        }
        .padding(.horizontal, Tok.Space.base)
        .padding(.vertical, Tok.Space.snug)
    }

    private var emptyState: some View {
        VStack(spacing: Tok.Space.tight) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No tools showing")
                .font(Tok.TypeScale.label)
                .foregroundStyle(.secondary)
            Button("Add one") { showingPicker = true }
                .buttonStyle(.glass)
                .font(Tok.TypeScale.label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tok.Space.wide)
    }
}

// MARK: - Picker

struct SidebarToolPicker: View {
    @Bindable var registry: SidebarRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            ForEach(registry.availableTools, id: \.id) { tool in
                Button {
                    registry.enable(tool.id)
                } label: {
                    HStack(alignment: .top, spacing: Tok.Space.snug) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(tool.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Tok.Space.tight) {
                                Text(tool.title).font(Tok.TypeScale.body)
                                if tool.usesModel { quotaBadge }
                            }
                            Text(tool.blurb)
                                .font(Tok.TypeScale.label)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if registry.availableTools.isEmpty {
                Text("Everything's already showing.")
                    .font(Tok.TypeScale.label)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Tok.Space.base)
        .frame(width: 290)
    }

    /// Sidebar calls draw on the same quota as the conversation, so "this one spends" is
    /// worth saying at the moment someone adds it, not buried in a doc.
    private var quotaBadge: some View {
        Text("uses quota")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Tok.Palette.warn)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Tok.Palette.warn.opacity(0.14), in: .capsule)
    }
}

// MARK: - Card

struct SidebarToolCard: View {
    let tool: any SidebarTool
    let workingDirectory: URL
    let onRemove: () -> Void

    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tok.Space.tight) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(tool.tint)
                Text(tool.title)
                    .font(Tok.TypeScale.label)
                Spacer()
                Button {
                    withAnimation(Tok.Motion.touch) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Remove \(tool.title)")
            }
            .padding(.horizontal, Tok.Space.snug)
            .padding(.vertical, Tok.Space.tight)

            if !collapsed {
                tool.makeView()
                    .environment(\.sidebarWorkingDirectory, workingDirectory)
                    .padding(.horizontal, Tok.Space.snug)
                    .padding(.bottom, Tok.Space.snug)
            }
        }
        .glassEffect(Tok.Surface.panel, in: .rect(cornerRadius: Tok.Radius.card))
    }
}

// MARK: - Environment

private struct SidebarWorkingDirectoryKey: EnvironmentKey {
    static let defaultValue = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

extension EnvironmentValues {
    /// Passed down rather than captured by each tool: the project switcher changes it at
    /// runtime, and a tool holding a stale copy would run against the wrong directory.
    var sidebarWorkingDirectory: URL {
        get { self[SidebarWorkingDirectoryKey.self] }
        set { self[SidebarWorkingDirectoryKey.self] = newValue }
    }
}

// MARK: - Notes

struct NotesToolView: View {
    @Bindable var tool: NotesTool

    var body: some View {
        TextEditor(text: $tool.text)
            .font(Tok.TypeScale.body)
            .scrollContentBackground(.hidden)
            .textEditorStyle(.plain)
            .frame(minHeight: 90, maxHeight: 220)
            .overlay(alignment: .topLeading) {
                if tool.text.isEmpty {
                    Text("Anything you don't want in the transcript…")
                        .font(Tok.TypeScale.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Model-backed tool chrome

/// Input box + run button + phase handling, shared by every model-backed tool. Only the
/// result rendering differs between them.
struct OneShotToolBody<Output: StructuredOutput, Result: View>: View {
    @Binding var draft: String
    /// A plain `let`, not `@Bindable`: nothing here writes to the runner's properties, and
    /// `@Observable` tracks reads through a stored reference just fine.
    let runner: OneShotRunner<Output>
    let placeholder: String
    let tint: Color
    let runLabel: String
    @ViewBuilder let result: (Output, OneShotUsage) -> Result

    @Environment(\.sidebarWorkingDirectory) private var workingDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            TextEditor(text: $draft)
                .font(Tok.TypeScale.mono)
                .scrollContentBackground(.hidden)
                .textEditorStyle(.plain)
                .frame(minHeight: 62, maxHeight: 150)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(placeholder)
                            .font(Tok.TypeScale.mono)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(Tok.Space.tight)
                .glassEffect(Tok.Surface.interactive,
                             in: .rect(cornerRadius: Tok.Radius.chip))

            HStack(spacing: Tok.Space.tight) {
                if runner.isRunning {
                    Button("Cancel") { runner.cancel() }
                        .buttonStyle(.glass)
                        .font(Tok.TypeScale.label)
                    // ~9 s is long enough that a spinner alone reads as a hang. Saying what
                    // it's waiting on, and that it isn't the conversation, is the difference
                    // between "slow" and "broken".
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("haiku · separate process")
                            .font(Tok.TypeScale.label)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(runLabel) {
                        runner.run(draft, workingDirectory: workingDirectory)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .font(Tok.TypeScale.label)
                    .disabled(draft.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)

                    if case .done = runner.phase {
                        Button("Clear") { runner.reset() }
                            .buttonStyle(.glass)
                            .font(Tok.TypeScale.label)
                    }
                }
                Spacer(minLength: 0)
            }

            switch runner.phase {
            case .idle, .running:
                EmptyView()
            case .failed(let message):
                Text(message)
                    .font(Tok.TypeScale.label)
                    .foregroundStyle(Tok.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            case .done(let output, let usage):
                result(output, usage)
                UsageFootnote(usage: usage)
            }
        }
    }
}

/// What the call actually drew. Shown because the honest unit here is quota, not dollars —
/// and because a sidebar silently escalating off Haiku is exactly the failure worth seeing.
struct UsageFootnote: View {
    let usage: OneShotUsage

    /// Two independent ways a sidebar call can go wrong, and they don't imply each other: a
    /// call can escalate off Haiku without paying a cold start, and vice versa. Tinting only
    /// on cold start would have left escalation merely *visible* rather than flagged, which
    /// is the failure this footnote exists to catch.
    private var escalated: Bool {
        guard let model = usage.model else { return false }
        return !model.contains("haiku")
    }

    var body: some View {
        HStack(spacing: Tok.Space.tight) {
            Text(usage.model.map(shortModel) ?? "?")
                .foregroundStyle(escalated ? Tok.Palette.danger : .secondary)
                .help(escalated
                      ? "Sidebar tools are meant to run on Haiku — this one didn't."
                      : "")
            Text("\(usage.inputTokens + usage.outputTokens) tok")
            if let ms = usage.durationMS {
                // Rounded, not truncated: integer division rendered 9,900 ms as "9s".
                Text(String(format: "%.1fs", Double(ms) / 1000))
            }
            if usage.didPayColdStart {
                Text("cold start")
                    .foregroundStyle(Tok.Palette.warn)
                    .help("This call rebuilt its prompt cache — a strip flag stopped working.")
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(.tertiary)
    }

    private func shortModel(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
            .split(separator: "-").prefix(1).joined()
    }
}

// MARK: - Prompt improver

struct PromptImproverToolView: View {
    @Bindable var tool: PromptImproverTool

    var body: some View {
        OneShotToolBody(
            draft: $tool.draft,
            runner: tool.runner,
            placeholder: "Paste a prompt…",
            tint: tool.tint,
            runLabel: "Review"
        ) { critique, _ in
            VStack(alignment: .leading, spacing: Tok.Space.tight) {
                HStack(spacing: Tok.Space.tight) {
                    Text("\(critique.clampedScore)/10")
                        .font(Tok.TypeScale.title)
                        .foregroundStyle(scoreTint(critique.clampedScore))
                    Text("\(critique.issues.count) issue\(critique.issues.count == 1 ? "" : "s")")
                        .font(Tok.TypeScale.label)
                        .foregroundStyle(.secondary)
                    if critique.scoreOutOfRange {
                        Text("model said \(critique.score)")
                            .font(Tok.TypeScale.label)
                            .foregroundStyle(Tok.Palette.warn)
                            .help("Outside the schema's 1–10 bounds — the constraint isn't holding.")
                    }
                }

                ForEach(critique.issues, id: \.self) { issue in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(issue).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Tok.TypeScale.label)
                }

                if !critique.rewrite.isEmpty {
                    Divider().opacity(0.3)
                    HStack {
                        Text("Rewrite").font(Tok.TypeScale.label).foregroundStyle(.secondary)
                        Spacer()
                        CopyButton(text: critique.rewrite)
                    }
                    ScrollView {
                        Text(critique.rewrite)
                            .font(Tok.TypeScale.mono)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
    }

    private func scoreTint(_ score: Int) -> Color {
        switch score {
        case ..<4: return Tok.Palette.danger
        case 4..<7: return Tok.Palette.warn
        default: return Tok.Palette.approve
        }
    }
}

// MARK: - Review tools

struct ReviewToolView: View {
    @Bindable var tool: ReviewTool

    var body: some View {
        OneShotToolBody(
            draft: $tool.draft,
            runner: tool.runner,
            placeholder: tool.placeholder,
            tint: tool.tint,
            runLabel: "Check"
        ) { review, _ in
            VStack(alignment: .leading, spacing: Tok.Space.tight) {
                Text(review.summary)
                    .font(Tok.TypeScale.label)
                    .fixedSize(horizontal: false, vertical: true)

                if review.findings.isEmpty {
                    // "Nothing found" has to be a real, confident answer — otherwise the
                    // tool is pressured into inventing nits to look useful.
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Tok.Palette.approve)
                        Text("Nothing worth flagging")
                            .foregroundStyle(.secondary)
                    }
                    .font(Tok.TypeScale.label)
                }

                ForEach(review.findings) { finding in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(finding.tint).frame(width: 5, height: 5)
                            Text(finding.severity.lowercased())
                                .foregroundStyle(finding.tint)
                            if let location = finding.location, !location.isEmpty {
                                Text(location)
                                    .font(Tok.TypeScale.mono)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(Tok.TypeScale.label)

                        Text(finding.issue)
                            .font(Tok.TypeScale.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(finding.fix)
                            .font(Tok.TypeScale.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Tok.Space.tight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(finding.tint.opacity(0.07),
                                in: .rect(cornerRadius: Tok.Radius.chip))
                }
            }
        }
    }
}

// MARK: - Copy

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(copied ? Tok.Palette.approve : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}
