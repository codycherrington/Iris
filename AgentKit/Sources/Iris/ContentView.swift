import AppKit
import SwiftUI

struct ContentView: View {
    @State private var model = SessionModel(
        workingDirectory: URL(fileURLWithPath: NSHomeDirectory())
    )
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
            Divider()
            StatusBar(stats: model.stats, isBusy: model.isBusy,
                      directory: model.workingDirectory) {
                pickDirectory()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await model.start() }
        .overlay(alignment: .top) {
            if let error = model.fatalError {
                ErrorBanner(text: error) { Task { await model.start() } }
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.messages.isEmpty {
                        EmptyState(directory: model.workingDirectory)
                            .padding(.top, 60)
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.vertical, 8)
            }
            .onChange(of: model.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: model.messages.count) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var bottomAnchor: String { "bottom" }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 32, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .focused($composerFocused)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(model.isBusy ? "Esc to interrupt…" : "Message Iris…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                // ⌘↵ sends; ↵ alone inserts a newline.
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

            Button(action: submit) {
                Image(systemName: model.isBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isBusy ? .red : (draft.isEmpty ? .secondary : .accentColor))
            .keyboardShortcut(.return, modifiers: .command)
            .help(model.isBusy ? "Interrupt (Esc)" : "Send (⌘↵)")
        }
        .padding(10)
        .onAppear { composerFocused = true }
    }

    private func submit() {
        if model.isBusy {
            Task { await model.interrupt() }
            return
        }
        let text = draft
        draft = ""
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

// MARK: - Chrome

struct StatusBar: View {
    let stats: SessionStats
    let isBusy: Bool
    let directory: URL
    let onPickDirectory: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPickDirectory) {
                HStack(spacing: 3) {
                    Image(systemName: "folder").font(.system(size: 9))
                    Text(directory.lastPathComponent).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help(directory.path)

            Divider().frame(height: 10)

            // The load-bearing indicator: green means running on the subscription.
            HStack(spacing: 3) {
                Circle()
                    .fill(stats.isSubscription ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(stats.isSubscription ? "subscription" : stats.authSource)
            }
            .help("apiKeySource = \(stats.authSource)")

            Text(stats.model).foregroundStyle(.secondary)

            if let quota = stats.quotaStatus {
                Divider().frame(height: 10)
                Text(quotaLabel(quota)).foregroundStyle(.secondary)
            }

            Spacer()

            if let thinking = stats.thinkingTokens, isBusy {
                Text("thinking \(thinking)").foregroundStyle(.secondary)
            }
            if let ttft = stats.ttftMS {
                Text("ttft \(ttft)ms").foregroundStyle(.secondary)
            }
            if let dispatch = stats.dispatchMS {
                // The number the whole architecture rests on — kept visible on purpose.
                Text("dispatch \(dispatch)ms")
                    .foregroundStyle(dispatch > 100 ? .red : .secondary)
                    .help("Per-turn overhead of the persistent process. Baseline 7–20ms.")
            }
            if let cost = stats.sessionCostUSD {
                Text(String(format: "$%.4f", cost))
                    .foregroundStyle(.secondary)
                    .help("Cumulative session estimate, client-side")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }

    private func quotaLabel(_ status: String) -> String {
        guard let resets = stats.quotaResetsAt else { return status }
        let mins = max(0, Int(resets.timeIntervalSinceNow / 60))
        return mins >= 60 ? "\(status) · \(mins / 60)h\(mins % 60)m" : "\(status) · \(mins)m"
    }
}

struct EmptyState: View {
    let directory: URL

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Iris").font(.system(size: 15, weight: .medium))
            Text(directory.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
            Text("⌘↵ to send · Esc to interrupt")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let text: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            Text(text).font(.system(size: 11)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry", action: onRetry)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(10)
        .background(Color.red.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}
