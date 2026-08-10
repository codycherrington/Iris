import AgentKit
import AppKit
import SwiftUI

struct GlassContentView: View {
    @State private var personas = PersonaStore.shared
    @State private var sessionSettings = SessionSettingsStore.shared
    @State private var model = SessionModel(persona: PersonaStore.shared.persona,
                                            settings: SessionSettingsStore.shared.settings)
    @State private var registry = SidebarRegistry.shared
    @State private var draft = ""
    @State private var showingPersona = false
    @State private var showingSidebar = SidebarRegistry.shared.layout.isVisible
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `Tok.TypeScale.body` as an `NSFont`, so the composer's line height comes from the
    /// same typeface the transcript uses rather than from a number typed into a frame.
    static let composerFont = NSFont.systemFont(ofSize: 13.5)
    @State private var composerHeight = ComposerTextView.lineHeight(for: composerFont)

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(spacing: 0) {
                // The rail sits beside the *transcript only*, not beside the whole column.
                // Wrapping the composer and status bar too would shove them sideways every
                // time the panel opens, so the thing you're typing into would jump — and
                // the chrome at the bottom has no reason to yield space to a tool panel.
                HStack(spacing: 0) {
                    // The title strip belongs to this column, not to the window: the panel
                    // has to reach the very top so its header row lands in the same band as
                    // the Tools button, which is pinned to the window corner and never moves.
                    VStack(spacing: 0) {
                        // The representable itself, not `Color.clear` with it as a
                        // background: `Color` is hit-testable in SwiftUI and would claim the
                        // mouse-down before the NSView underneath ever saw it, which is the
                        // one thing this view exists to receive.
                        WindowDragStrip()
                            .frame(height: Self.titleStripHeight)
                        transcript
                    }

                    if showingSidebar {
                        SidebarPanel(registry: registry,
                                     workingDirectory: model.workingDirectory,
                                     headerHeight: Self.titleStripHeight,
                                     onToggle: toggleSidebar)
                            // Slides in from the edge it lives on; opacity alone made it
                            // appear to materialise on top of the transcript.
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                composer
                GlassStatusBar(stats: model.stats, isBusy: model.isBusy,
                               directory: model.workingDirectory,
                               assistantName: model.persona.assistantName,
                               settings: model.settings,
                               namespace: glass,
                               onPickDirectory: pickDirectory,
                               onEditPersona: {
                                   // Iris may have edited the file itself since launch.
                                   personas.reload()
                                   showingPersona = true
                               },
                               onRefreshQuota: {
                                   Task { await model.refreshQuota(force: true) }
                               },
                               onApplySettings: { next in
                                   sessionSettings.save(next)
                                   Task { await model.applySettings(next) }
                               })
            }
        }
        // Fixed to the window's corner, above everything, in the layout of nothing. That is
        // what keeps it still: it isn't a row in the transcript column *or* a row in the
        // panel header, so neither opening the rail nor anything else can push it. The panel
        // reserves its footprint and slides in underneath.
        .overlay(alignment: .topTrailing) {
            ToolsToggleButton(isOn: showingSidebar, action: toggleSidebar)
                // Centres it in the same band the panel header centres its own controls in,
                // so the two line up by construction rather than by a matching pair of
                // hand-tuned paddings.
                .frame(width: ToolsToggleButton.side, height: Self.titleStripHeight)
                .padding(.trailing, Tok.Space.base)
        }
        // Wider floor when the rail is out: 640 minus a 320pt panel leaves the transcript
        // too narrow for a code block to be readable.
        .frame(minWidth: showingSidebar ? 940 : 640, minHeight: 480)
        .task {
            // Don't launch a session behind the first-run wizard: the persona is a launch
            // argument, so a session started now would have to be torn down and relaunched
            // the moment the wizard is answered.
            if personas.needsSetup {
                showingPersona = true
            } else {
                await model.start()
            }
        }
        .sheet(isPresented: $showingPersona) {
            PersonaWizard(
                persona: personas.persona,
                onComplete: { persona in
                    let wasFirstRun = personas.needsSetup
                    personas.save(persona)
                    showingPersona = false
                    Task {
                        if wasFirstRun {
                            await model.applyPersona(persona)
                            await model.start()
                        } else {
                            await model.applyPersona(persona)
                        }
                    }
                },
                // No cancel on first run — there's no session behind it to go back to.
                onCancel: personas.needsSetup ? nil : { showingPersona = false }
            )
        }
        .overlay(alignment: .top) {
            if let error = model.fatalError {
                GlassErrorBanner(text: error) { Task { await model.start() } }
                    .padding(Tok.Space.snug)
                    .transition(.glassAppear(reduceMotion: reduceMotion))
            }
        }
        .animation(Tok.Motion.resolved(Tok.Motion.glass, reduceMotion: reduceMotion),
                   value: model.messages.count)
        .animation(Tok.Motion.resolved(Tok.Motion.touch, reduceMotion: reduceMotion),
                   value: model.isBusy)
        .animation(Tok.Motion.resolved(Tok.Motion.content, reduceMotion: reduceMotion),
                   value: showingSidebar)
        .background {
            // Hosts the keyboard shortcut without putting a visible control in the chrome.
            Button("Toggle Tools", action: toggleSidebar)
                .keyboardShortcut("s", modifiers: [.command, .option])
                .hidden()
        }
    }

    private func toggleSidebar() {
        showingSidebar.toggle()
        registry.setVisible(showingSidebar)
    }

    /// The band across the top of the window: the only place a drag moves the window, the
    /// row the Tools button sits in, and the height of the tool panel's header.
    ///
    /// One number for all three because they have to agree — the button holding still across
    /// the rail opening is exactly the claim that the panel's header row occupies the same
    /// band the button already occupies. Tall enough to clear the traffic lights, which the
    /// hidden titlebar still draws.
    static let titleStripHeight: CGFloat = 32

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // One container per region: shapes only fuse with siblings inside the same
                // container, which is what keeps message glass from bleeding into the
                // composer's.
                GlassEffectContainer(spacing: Tok.Fusion.transcript) {
                    LazyVStack(alignment: .leading, spacing: Tok.Space.tight) {
                        if model.messages.isEmpty {
                            GlassEmptyState(directory: model.workingDirectory)
                                .padding(.top, 72)
                        }
                        ForEach(model.messages) { message in
                            GlassMessageRow(
                                message: message,
                                namespace: glass,
                                isAnswerable: message.id == model.messages.last?.id
                                    && !model.isBusy,
                                onAnswer: { answer in Task { await model.send(answer) } }
                            )
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    // Both the stack AND the container size to their content by default, so
                    // without these the rows never span the window and every bubble hugs the
                    // leading edge no matter what the row's own Spacer does.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Tok.Space.base)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .scrollContentBackground(.hidden)
            .onChange(of: model.messages.last?.text) { _, _ in
                withAnimation(Tok.Motion.resolved(.easeOut(duration: 0.12),
                                                  reduceMotion: reduceMotion)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        GlassEffectContainer(spacing: Tok.Fusion.composer) {
            // .center, not .bottom: the text editor is taller than the button, and bottom
            // alignment drags the button below the text baseline.
            HStack(alignment: .center, spacing: Tok.Space.base) {
                ComposerTextView(
                    text: $draft,
                    height: $composerHeight,
                    font: Self.composerFont,
                    maxHeight: 132,
                    onSubmit: submit,
                    onEscape: {
                        guard model.isBusy else { return }
                        Task { await model.interrupt() }
                    }
                )
                .frame(height: composerHeight)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        // No offset. The text view's insets are zeroed, so its first glyph
                        // and this placeholder share an origin exactly.
                        Text(model.isBusy ? "Esc to interrupt…" : "Message Iris…")
                            .font(Tok.TypeScale.body)
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, Tok.Space.base + 2)
                .padding(.vertical, 11)
                .glassEffect(Tok.Surface.interactive, in: .capsule)
                .glassEffectID(GlassID.composer, in: glass)

                SendButton(isBusy: model.isBusy,
                           hasText: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           namespace: glass,
                           action: submit)
            }
            .padding(.horizontal, Tok.Space.loose)
            .padding(.vertical, Tok.Space.snug)
        }
        // Focus is taken by ComposerTextView itself when its NSView lands in a window.
    }

    private func submit() {
        if model.isBusy {
            Task { await model.interrupt() }
            return
        }
        let text = draft
        withAnimation(Tok.Motion.resolved(Tok.Motion.glass, reduceMotion: reduceMotion)) {
            draft = ""
        }
        Task { await model.send(text) }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.workingDirectory
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.changeDirectory(to: url) }
    }
}

// MARK: - Send button

struct SendButton: View {
    let isBusy: Bool
    let hasText: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        if isBusy { return Tok.Palette.danger }
        return hasText ? Tok.Palette.agent : .gray
    }

    /// The idle button is smaller, and that size change is expressed as a **frame** change
    /// rather than `.scaleEffect`.
    ///
    /// It used to be `.scaleEffect(0.9)`, which pulled the arrow visibly off centre while
    /// empty. Measured off Cody's screenshots: at scale 1.0 the glyph sits `(0.00, +0.50)pt`
    /// from the circle's centre; under the 0.9 scale it sits `(+1.75, +2.25)pt`. Rendering
    /// the glyph *alone* under the same scale shifts it only 0.06pt, so the glyph isn't what
    /// moves — the arrow and the glass circle simply don't scale about the same point.
    ///
    /// Animating the frame keeps content and glass in one geometry, and leaves the resting
    /// sizes on whole points so the stroke stays on the pixel grid. 42pt matches the
    /// composer's row height.
    private var side: CGFloat { hasText || isBusy ? 42 : 38 }

    var body: some View {
        Button(action: action) {
            // Centering is measured, not nudged: `CenteredSymbol` rasterizes the glyph
            // through SwiftUI's own renderer and offsets by the difference between its ink
            // centre and the frame's. Both symbols measure to exactly zero at both sizes —
            // which is why the old hand-tuned `-1, -1` had to go. It wasn't fixing an
            // off-centre arrow, it was creating one.
            CenteredSymbol(name: isBusy ? "stop.fill" : "arrow.up",
                           pointSize: 15, side: side)
                .foregroundStyle(.white)
        }
        .buttonStyle(.glassCircle)
        .glassEffect(Tok.Surface.accentInteractive(tint.opacity(0.8)), in: .circle)
        .glassEffectID(GlassID.sendButton, in: namespace)
        .animation(Tok.Motion.resolved(Tok.Motion.touch, reduceMotion: reduceMotion),
                   value: side)
        .help(isBusy ? "Interrupt (Esc)" : "Send (↵ — ⇧↵ for a new line)")
    }
}

// MARK: - Backdrop

/// A slow spectral wash behind the glass. Liquid Glass refracts what's behind it, so with a
/// flat background it reads as frosted plastic — this gives it something to bend.
///
/// The wash also leans toward the pointer. Not a chase: the blobs are tugged a bounded
/// distance from where they already are, on a long spring, so it reads as the light noticing
/// you rather than following you.
struct AuroraBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    /// Cursor offset from the window centre, normalised to -1…1 on each axis.
    @State private var pull: CGSize = .zero
    @State private var monitor: Any?

    /// Maximum lean, in points. Deliberately small — past roughly 40 it stops looking like
    /// light bending and starts looking like a cursor-tracking gimmick.
    private static let maxPull: CGFloat = 34
    /// Per-blob parallax factor. The front blob leans furthest and the back ones lag, which
    /// is what gives depth instead of one flat sheet sliding around.
    private static let depth: [CGFloat] = [1.0, 0.6, 0.35]

    var body: some View {
        ZStack {
            Rectangle().fill(Tok.Palette.background)

            ForEach(Array(Tok.Palette.spectrum.enumerated()), id: \.offset) { index, color in
                let lean = Self.depth[index % Self.depth.count] * Self.maxPull
                Ellipse()
                    .fill(color.opacity(0.30))
                    .frame(width: 460, height: 340)
                    .blur(radius: 110)
                    .offset(
                        x: (drift ? CGFloat(120 - index * 130) : CGFloat(-90 + index * 110))
                            + pull.width * lean,
                        y: (drift ? CGFloat(-130 + index * 120) : CGFloat(150 - index * 90))
                            + pull.height * lean
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                drift = true
            }
            startTracking()
        }
        .onDisappear(perform: stopTracking)
        .accessibilityHidden(true)
    }

    /// A local event monitor rather than `onContinuousHover`: the backdrop sits underneath
    /// the entire UI, so hover would be swallowed by whatever chrome is on top of it.
    private func startTracking() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            MainActor.assumeIsolated {
                guard let window = event.window else { return }
                let size = window.frame.size
                guard size.width > 1, size.height > 1 else { return }

                let point = event.locationInWindow
                let nx = min(max((point.x / size.width) * 2 - 1, -1), 1)
                let ny = min(max((point.y / size.height) * 2 - 1, -1), 1)
                // AppKit's origin is bottom-left; SwiftUI's offset runs top-down.
                let next = CGSize(width: nx, height: -ny)

                // Mouse-moved fires ~100×/s and each blob carries a 110pt blur, so redrawing
                // on every event is real work for sub-pixel movement. Ignore anything under
                // ~0.3pt of actual lean; the spring interpolates across the gaps anyway.
                guard abs(next.width - pull.width) > 0.01
                        || abs(next.height - pull.height) > 0.01 else { return }

                withAnimation(.spring(response: 1.7, dampingFraction: 0.95)) {
                    pull = next
                }
            }
            return event
        }
    }

    private func stopTracking() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Status bar

struct GlassStatusBar: View {
    let stats: SessionStats
    let isBusy: Bool
    let directory: URL
    let assistantName: String
    let settings: SessionSettings
    let namespace: Namespace.ID
    let onPickDirectory: () -> Void
    let onEditPersona: () -> Void
    let onRefreshQuota: () -> Void
    let onApplySettings: (SessionSettings) -> Void

    @State private var showingModelPicker = false

    var body: some View {
        GlassEffectContainer(spacing: Tok.Fusion.status) {
            HStack(spacing: Tok.Space.snug) {
                Button(action: onPickDirectory) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill").font(.system(size: 8))
                        Text(directory.lastPathComponent).lineLimit(1)
                    }
                    .padding(.horizontal, Tok.Space.snug)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.glassChip)
                .glassEffect(Tok.Surface.interactive, in: .capsule)
                .help(directory.path)

                Button(action: onEditPersona) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill").font(.system(size: 8))
                        Text(assistantName.isEmpty ? "persona" : assistantName).lineLimit(1)
                    }
                    .padding(.horizontal, Tok.Space.snug)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.glassChip)
                .glassEffect(Tok.Surface.interactive, in: .capsule)
                .help("Edit persona — restarts the session")

                // Green means running on the subscription. The one indicator that must never
                // be subtle — and must never imply API billing before it has any data.
                //
                // Model and effort come from the *configuration*, so they're known at launch
                // and shown immediately. Auth isn't: `system/init` arrives per turn, so the
                // dot stays grey until the first message proves it. Showing a real model name
                // beside a hedged auth state is the honest version of what used to be an
                // uninformative "starting… —".
                Button { showingModelPicker = true } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(connectionTint)
                            .frame(width: 5, height: 5)
                            .opacity(stats.connection == .starting ? 0.45 : 1)
                        Text(connectionLabel)
                        Text(stats.configuredModel).foregroundStyle(.secondary)
                        Text(stats.configuredEffort).foregroundStyle(.tertiary)
                        if let drift = modelDrift {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Tok.Palette.warn)
                                .help(drift)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    // Without this the model id wraps to two lines inside the chip.
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Tok.Space.snug)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.glassChip)
                .glassEffect(Tok.Surface.interactive, in: .capsule)
                .help(connectionHelp)
                .popover(isPresented: $showingModelPicker, arrowEdge: .top) {
                    ModelEffortPicker(settings: settings, onApply: onApplySettings)
                }

                // The one number Cody actually asked for, and the only chip here that is a
                // button: the reading is a scrape that costs a turn, so it refreshes on a
                // slow timer and on demand rather than continuously.
                Button(action: onRefreshQuota) {
                    HStack(spacing: 4) {
                        Text("quota:").foregroundStyle(.tertiary)
                        if let five = stats.quota?.fiveHour {
                            Text("\(Int(five.usedPercent.rounded()))%")
                                .foregroundStyle(quotaTint(five.usedPercent))
                            if let left = five.timeRemaining {
                                // The dash is a separator, not a minus: percent used and time
                                // until reset are two independent facts about one window.
                                Text("-").foregroundStyle(.tertiary)
                                Text(remaining(left)).foregroundStyle(.tertiary)
                            }
                        } else if stats.quotaProbeRunning {
                            Text("reading…").foregroundStyle(.tertiary)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                        if stats.quotaProbeRunning, stats.quota != nil {
                            ProgressView().controlSize(.mini).scaleEffect(0.6)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Tok.Space.snug)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.glassChip)
                .glassEffect(Tok.Surface.interactive, in: .capsule)
                .help(quotaHelp)

                // Context and session sit beside quota rather than above the status bar
                // because they answer the same kind of question — what has this session
                // spent, and how close is it to a limit. A bar was the wrong shape for one
                // number in a row of chips that are all one number.
                if let context = contextPercent {
                    readout(help: contextHelp) {
                        Text("context").foregroundStyle(.tertiary)
                        Text("\(context)%").foregroundStyle(contextTint(context))
                    }
                }

                if stats.turns > 0 {
                    readout(help: sessionHelp) {
                        Text("session").foregroundStyle(.tertiary)
                        Text(compactTokens(stats.sessionTokens))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Thinking is reported beside Iris's name in the message itself, where the
                // reasoning it describes actually happened — not down here in the chrome.
                if let ttft = stats.ttftMS {
                    metric("ttft \(ttft)ms", tint: nil)
                }
                if let dispatch = stats.dispatchMS {
                    metric("dispatch \(dispatch)ms",
                           tint: dispatch > 100 ? Tok.Palette.danger : nil)
                }
                if let cost = stats.sessionCostUSD {
                    metric(String(format: "$%.4f", cost), tint: nil)
                }
            }
            .font(Tok.TypeScale.mono)
            .padding(.horizontal, Tok.Space.base)
            .padding(.vertical, Tok.Space.snug)
        }
    }

    private var connectionTint: Color {
        switch stats.connection {
        case .starting: return .gray
        case .ready: return Tok.Palette.approve
        case .degraded: return Tok.Palette.warn
        }
    }

    private var connectionLabel: String {
        switch stats.connection {
        // Honest: auth isn't known until the first turn, so don't claim anything. The model
        // beside it is a launch argument, so it can be stated with confidence.
        case .starting: return "checking…"
        case .ready: return "subscription"
        case .degraded: return stats.authSource
        }
    }

    /// Set when the model that actually ran isn't the one that was asked for — a fallback
    /// kicked in, or an alias resolved somewhere unexpected. Silent disagreement between
    /// "what I selected" and "what I'm being charged for" is exactly the kind of thing this
    /// app exists to make visible.
    private var modelDrift: String? {
        guard stats.connection == .ready, stats.model != "—" else { return nil }
        let reported = ModelChoice.label(forReportedModel: stats.model)
        guard reported != stats.configuredModel else { return nil }
        return "Configured \(stats.configuredModel), but the session reported \(stats.model)."
    }

    private var connectionHelp: String {
        let tail = "  ·  Click to change model or effort."
        switch stats.connection {
        case .starting:
            return "Checking local credentials…" + tail
        case .ready:
            let plan = stats.subscriptionPlan.map { " (\($0))" } ?? ""
            return "apiKeySource = none — running on your Claude subscription\(plan)." + tail
        case .degraded:
            return "apiKeySource = \(stats.authSource) — NOT the subscription path." + tail
        }
    }

    private func metric(_ text: String, tint: Color?) -> some View {
        Text(text)
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, Tok.Space.tight)
            .padding(.vertical, 3)
    }

    /// A chip that reports rather than acts. Same shape as the buttons beside it, minus the
    /// interactive glass and the press feedback — those would promise a click that does
    /// nothing.
    private func readout(help: String,
                         @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 4, content: content)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Tok.Space.snug)
            .padding(.vertical, 5)
            .glassEffect(Tok.Surface.panel, in: .capsule)
            .help(help)
    }

    private func remaining(_ interval: TimeInterval) -> String {
        let mins = max(0, Int(interval / 60))
        return mins >= 60 ? "\(mins / 60)h\(mins % 60)m" : "\(mins)m"
    }

    /// Same thresholds as context, for the same reason — they mark where behaviour should
    /// change, not where a designer wanted a colour.
    private func quotaTint(_ percent: Double) -> Color {
        switch percent {
        case ..<70: return Tok.Palette.approve
        case ..<90: return Tok.Palette.warn
        default: return Tok.Palette.danger
        }
    }

    private var quotaHelp: String {
        var lines: [String] = []
        if let five = stats.quota?.fiveHour {
            lines.append(String(format: "5-hour window: %.0f%% used", five.usedPercent)
                + (five.timeRemaining.map { ", \(remaining($0)) left" } ?? ""))
        }
        if let seven = stats.quota?.sevenDay {
            lines.append(String(format: "7-day window: %.0f%% used", seven.usedPercent)
                + (seven.timeRemaining.map { ", \(remaining($0)) left" } ?? ""))
        }
        if let captured = stats.quota?.capturedAt {
            let age = Int(Date().timeIntervalSince(captured) / 60)
            lines.append("Read \(age < 1 ? "just now" : "\(age)m ago") — click to refresh.")
        }
        if let error = stats.quotaProbeError {
            lines.append("Last probe failed: \(error)")
        }
        if lines.isEmpty {
            lines.append("Reading the account's rate-limit usage…")
        }
        // Said plainly, because it's surprising: the only source for these numbers is the
        // interactive CLI's status line, so getting them costs a small turn.
        lines.append("These come from a short probe session — print mode never reports them.")
        return lines.joined(separator: "\n")
    }

    // MARK: Context

    /// Nil until a turn has completed. A 0% chip would assert a measurement that hasn't
    /// happened yet.
    private var contextPercent: Int? {
        guard let tokens = stats.contextTokens,
              let window = stats.contextWindow, window > 0 else { return nil }
        return Int((min(Double(tokens) / Double(window), 1) * 100).rounded())
    }

    /// Amber from 70, red from 90 — the points where what you'd do next changes: be
    /// deliberate about pasting large files, then expect a compact.
    private func contextTint(_ percent: Int) -> Color {
        switch percent {
        case ..<70: return Tok.Palette.agent
        case ..<90: return Tok.Palette.warn
        default: return Tok.Palette.danger
        }
    }

    private var contextHelp: String {
        guard let tokens = stats.contextTokens, let window = stats.contextWindow else {
            return "How full the context window is."
        }
        return "\(tokens.formatted()) of \(window.formatted()) tokens carried by the last "
            + "turn's prompt, cached included — cached tokens occupy the window like any "
            + "other, they're only cheaper to send."
    }

    // MARK: Session

    private var sessionHelp: String {
        let cost = stats.sessionCostUSD.map { String(format: "  ·  $%.4f at API rates "
            + "(nothing is billed on the subscription)", $0) } ?? ""
        return """
            \(stats.turns) turn\(stats.turns == 1 ? "" : "s")  ·  \
            \(stats.sessionInputTokens.formatted()) in  ·  \
            \(stats.sessionOutputTokens.formatted()) out  ·  \
            \(stats.sessionCacheCreationTokens.formatted()) cache write  ·  \
            \(stats.sessionCacheReadTokens.formatted()) cache read\(cost)
            """
    }

    /// The headline figure is dominated by cache reads, which is honest — every turn re-sends
    /// the whole conversation and the CLI charges quota for it either way. The breakdown is
    /// one hover away rather than four chips wide.
    private func compactTokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n) tok"
        case ..<1_000_000: return String(format: "%.0fk tok", Double(n) / 1_000)
        default: return String(format: "%.2fM tok", Double(n) / 1_000_000)
        }
    }
}

// MARK: - Model & effort

/// Picks the model and reasoning effort for the session.
///
/// Both are launch arguments, so choosing either restarts the session and clears the
/// transcript. That's stated in the footer rather than hidden behind a confirmation — the
/// persona wizard makes the same trade, and being told once is better than a dialog every
/// time.
struct ModelEffortPicker: View {
    let settings: SessionSettings
    let onApply: (SessionSettings) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.snug) {
            section("Model") {
                ForEach(ModelChoice.all) { choice in
                    row(title: choice.label,
                        note: choice.note,
                        selected: settings.model == choice.id) {
                        var next = settings
                        next.model = choice.id
                        onApply(next)
                    }
                }
            }

            Divider().opacity(0.3)

            section("Effort") {
                ForEach(AgentConfiguration.Effort.allCases, id: \.self) { level in
                    row(title: level.rawValue,
                        note: level.note,
                        selected: settings.effort == level) {
                        var next = settings
                        next.effort = level
                        onApply(next)
                    }
                }
            }

            Text("Changing either restarts the session and clears the transcript.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tok.Space.base)
        .frame(width: 300)
    }

    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            content()
        }
    }

    private func row(title: String, note: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Tok.Space.tight) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 10))
                    // Explicit erasure: a ternary mixing a Color with a hierarchical style
                    // has no common type for the compiler to land on.
                    .foregroundStyle(selected
                        ? AnyShapeStyle(Tok.Palette.agent) : AnyShapeStyle(.tertiary))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Tok.TypeScale.body)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.glassRow)
    }
}

// MARK: - Empty state & errors

struct GlassEmptyState: View {
    let directory: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        VStack(spacing: Tok.Space.snug) {
            ZStack {
                ForEach(Array(Tok.Palette.spectrum.enumerated()), id: \.offset) { i, color in
                    Circle()
                        .strokeBorder(color.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 34 + CGFloat(i) * 13, height: 34 + CGFloat(i) * 13)
                        .scaleEffect(breathe ? 1.06 : 0.97)
                        .animation(
                            reduceMotion ? nil
                                : .easeInOut(duration: 2.6).repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.22),
                            value: breathe
                        )
                }
            }
            .frame(height: 68)

            Text("Iris").font(Tok.TypeScale.title)
            Text(directory.path)
                .font(Tok.TypeScale.mono)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("↵ send · ⇧↵ newline · Esc interrupt")
                .font(Tok.TypeScale.label)
                .foregroundStyle(.tertiary)
        }
        .padding(Tok.Space.wide)
        .frame(maxWidth: .infinity)
        .onAppear { breathe = true }
    }
}

struct GlassErrorBanner: View {
    let text: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Tok.Space.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tok.Palette.danger)
            Text(text)
                .font(Tok.TypeScale.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tok.Space.snug)
            Button("Retry", action: onRetry)
                .buttonStyle(.glass)
                .font(Tok.TypeScale.label)
        }
        .padding(Tok.Space.base)
        .glassEffect(Tok.Surface.accent(Tok.Palette.danger.opacity(0.5)),
                     in: .rect(cornerRadius: Tok.Radius.card))
    }
}
