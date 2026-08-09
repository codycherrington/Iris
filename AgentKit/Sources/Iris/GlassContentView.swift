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
    @State private var showingSidebar = false
    @FocusState private var composerFocused: Bool
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(spacing: 0) {
                // The rail sits beside the *transcript only*, not beside the whole column.
                // Wrapping the composer and status bar too would shove them sideways every
                // time the panel opens, so the thing you're typing into would jump — and
                // the chrome at the bottom has no reason to yield space to a tool panel.
                HStack(spacing: 0) {
                    transcript

                    if showingSidebar {
                        SidebarPanel(registry: registry,
                                     workingDirectory: model.workingDirectory,
                                     onClose: toggleSidebar)
                            // Slides in from the edge it lives on; opacity alone made it
                            // appear to materialise on top of the transcript.
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                composer
                GlassStatusBar(stats: model.stats, isBusy: model.isBusy,
                               directory: model.workingDirectory,
                               assistantName: model.persona.assistantName,
                               sidebarShowing: showingSidebar,
                               settings: model.settings,
                               namespace: glass,
                               onPickDirectory: pickDirectory,
                               onEditPersona: {
                                   // Iris may have edited the file itself since launch.
                                   personas.reload()
                                   showingPersona = true
                               },
                               onToggleSidebar: toggleSidebar,
                               onApplySettings: { next in
                                   sessionSettings.save(next)
                                   Task { await model.applySettings(next) }
                               })
            }
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
    }

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
                            GlassMessageRow(message: message, namespace: glass)
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
                TextEditor(text: $draft)
                    .font(Tok.TypeScale.body)
                    .scrollContentBackground(.hidden)
                    // Kill TextEditor's built-in insets so the placeholder overlay and the
                    // real caret share one origin — otherwise they sit a few points apart.
                    .textEditorStyle(.plain)
                    .contentMargins(.all, 0, for: .scrollContent)
                    .frame(minHeight: 20, maxHeight: 132)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($composerFocused)
                    .overlay(alignment: .leading) {
                        if draft.isEmpty {
                            Text(model.isBusy ? "Esc to interrupt…" : "Message Iris…")
                                .font(Tok.TypeScale.body)
                                .foregroundStyle(.tertiary)
                                // Clear the caret. Both sit at the text origin, so without
                                // this the blinking cursor lands on top of the first glyph.
                                .padding(.leading, 7)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        submit()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard model.isBusy else { return .ignored }
                        Task { await model.interrupt() }
                        return .handled
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
        .onAppear { composerFocused = true }
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

    var body: some View {
        Button(action: action) {
            // A fixed square frame with the glyph centred in it.
            // 42pt matches the text field's height (20 content + 11 padding top and bottom),
            // so the pair reads as one row rather than a small dot beside a tall pill.
            // arrow.up's ink is still offset down-and-right of its design box even at this
            // size — that's inherent to the glyph, not something frame sizing fixes — so it
            // keeps a small counter-nudge. stop.fill is symmetric and needs none.
            Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: isBusy ? 0 : -1, y: isBusy ? 0 : -1)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.glassCircle)
        .glassEffect(Tok.Surface.accentInteractive(tint.opacity(0.8)), in: .circle)
        .glassEffectID(GlassID.sendButton, in: namespace)
        .scaleEffect(hasText || isBusy ? 1.0 : 0.9)
        .animation(Tok.Motion.resolved(Tok.Motion.touch, reduceMotion: reduceMotion),
                   value: hasText)
        .help(isBusy ? "Interrupt (Esc)" : "Send (⌘↵)")
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
    let sidebarShowing: Bool
    let settings: SessionSettings
    let namespace: Namespace.ID
    let onPickDirectory: () -> Void
    let onEditPersona: () -> Void
    let onToggleSidebar: () -> Void
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

                if let quota = stats.quotaStatus {
                    Text(quotaLabel(quota))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Tok.Space.snug)
                        .padding(.vertical, 5)
                        .glassEffect(Tok.Surface.panel, in: .capsule)
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

                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 9))
                        .foregroundStyle(sidebarShowing ? Tok.Palette.agent : .secondary)
                        .padding(.horizontal, Tok.Space.snug)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.glassChip)
                .glassEffect(Tok.Surface.interactive, in: .capsule)
                .help("Tools (⌘⌥S)")
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

    private func quotaLabel(_ status: String) -> String {
        guard let resets = stats.quotaResetsAt else { return status }
        let mins = max(0, Int(resets.timeIntervalSinceNow / 60))
        return mins >= 60 ? "quota \(mins / 60)h\(mins % 60)m" : "quota \(mins)m"
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
            Text("⌘↵ send · Esc interrupt")
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
