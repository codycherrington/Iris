import AppKit
import SwiftUI

struct GlassContentView: View {
    @State private var model = SessionModel(
        workingDirectory: URL(fileURLWithPath: NSHomeDirectory())
    )
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(spacing: 0) {
                transcript
                composer
                GlassStatusBar(stats: model.stats, isBusy: model.isBusy,
                               directory: model.workingDirectory,
                               namespace: glass,
                               onPickDirectory: pickDirectory)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await model.start() }
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
                    .padding(.vertical, Tok.Space.base)
                }
            }
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
            HStack(alignment: .bottom, spacing: Tok.Space.snug) {
                TextEditor(text: $draft)
                    .font(Tok.TypeScale.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 26, maxHeight: 132)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($composerFocused)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(model.isBusy ? "Esc to interrupt…" : "Message Iris…")
                                .font(Tok.TypeScale.body)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .padding(.top, 4)
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
                    .padding(.horizontal, Tok.Space.base)
                    .padding(.vertical, Tok.Space.snug)
                    .glassEffect(Tok.Surface.interactive,
                                 in: .rect(cornerRadius: Tok.Radius.capsule))
                    .glassEffectID(GlassID.composer, in: glass)
                    // Shared union id: the field and the send button read as one piece of
                    // liquid and pull apart as the button grows on send.
                    .glassEffectUnion(id: GlassID.composerCluster, namespace: glass)

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
            Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .padding(Tok.Space.snug)
        }
        .buttonStyle(.plain)
        .glassEffect(Tok.Surface.accentInteractive(tint.opacity(0.75)), in: .circle)
        .glassEffectID(GlassID.sendButton, in: namespace)
        // Union only while idle: the button sits fused to the composer, then breaks away as
        // its own shape the moment there's something to send. That separation IS the
        // affordance — it's what makes the control feel liquid rather than decorated.
        .glassEffectUnion(
            id: (hasText || isBusy) ? nil : GlassID.composerCluster,
            namespace: namespace
        )
        .scaleEffect(hasText || isBusy ? 1.0 : 0.88)
        .animation(Tok.Motion.resolved(Tok.Motion.touch, reduceMotion: reduceMotion),
                   value: hasText)
        .help(isBusy ? "Interrupt (Esc)" : "Send (⌘↵)")
    }
}

// MARK: - Backdrop

/// A slow spectral wash behind the glass. Liquid Glass refracts what's behind it, so with a
/// flat background it reads as frosted plastic — this gives it something to bend.
struct AuroraBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var drift = false

    var body: some View {
        ZStack {
            Rectangle().fill(.background)

            ForEach(Array(Tok.Palette.spectrum.enumerated()), id: \.offset) { index, color in
                Ellipse()
                    .fill(color.opacity(scheme == .dark ? 0.30 : 0.16))
                    .frame(width: 460, height: 340)
                    .blur(radius: 110)
                    .offset(
                        x: drift ? CGFloat(120 - index * 130) : CGFloat(-90 + index * 110),
                        y: drift ? CGFloat(-130 + index * 120) : CGFloat(150 - index * 90)
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Status bar

struct GlassStatusBar: View {
    let stats: SessionStats
    let isBusy: Bool
    let directory: URL
    let namespace: Namespace.ID
    let onPickDirectory: () -> Void

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
                .buttonStyle(.plain)
                .glassEffect(Tok.Surface.interactive, in: .capsule)
                .help(directory.path)

                // Green means running on the subscription. The one indicator that must never
                // be subtle — and must never imply API billing before it has any data.
                HStack(spacing: 4) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 5, height: 5)
                        .opacity(stats.connection == .starting ? 0.45 : 1)
                    Text(connectionLabel)
                    if stats.connection == .ready {
                        Text(stats.model).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Tok.Space.snug)
                .padding(.vertical, 5)
                .glassEffect(Tok.Surface.panel, in: .capsule)
                .help(connectionHelp)

                if let quota = stats.quotaStatus {
                    Text(quotaLabel(quota))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Tok.Space.snug)
                        .padding(.vertical, 5)
                        .glassEffect(Tok.Surface.panel, in: .capsule)
                }

                Spacer()

                if let thinking = stats.thinkingTokens, isBusy {
                    metric("thinking \(thinking)", tint: Tok.Palette.agent)
                }
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
        // Honest: nothing is known until the first turn, so don't claim anything.
        case .starting: return "starting…"
        case .ready: return "subscription"
        case .degraded: return stats.authSource
        }
    }

    private var connectionHelp: String {
        switch stats.connection {
        case .starting:
            return "Session details arrive with your first message — system/init is emitted per turn."
        case .ready:
            return "apiKeySource = none — running on your Claude subscription."
        case .degraded:
            return "apiKeySource = \(stats.authSource) — NOT the subscription path."
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
