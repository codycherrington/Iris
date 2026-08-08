import SwiftUI

// MARK: - Message

struct GlassMessageRow: View {
    let message: ChatMessage
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isUser: Bool { message.role == .user }
    private var accent: Color { isUser ? Tok.Palette.user : Tok.Palette.agent }

    var body: some View {
        // The row must span the full transcript width or the Spacer has nothing to push
        // against and every bubble collapses toward the leading edge.
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: Tok.Space.wide) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: Tok.Space.snug) {
                if !message.text.isEmpty || message.isStreaming {
                    contentBody
                }
                if !message.toolCalls.isEmpty {
                    ToolChipCluster(calls: message.toolCalls, namespace: namespace)
                }
            }
            .frame(maxWidth: 620, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: Tok.Space.wide) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Tok.Space.loose)
        .padding(.vertical, Tok.Space.tight)
        .transition(.glassAppear(reduceMotion: reduceMotion))
    }

    private var contentBody: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: Tok.Space.tight) {
            HStack(spacing: Tok.Space.tight) {
                if isUser {
                    if message.isStreaming { StreamingPulse() }
                    Text("You").font(Tok.TypeScale.label).foregroundStyle(accent)
                    Circle().fill(accent).frame(width: 5, height: 5)
                } else {
                    Circle().fill(accent).frame(width: 5, height: 5)
                    Text("Iris").font(Tok.TypeScale.label).foregroundStyle(accent)
                    if message.isStreaming { StreamingPulse() }
                }
            }

            if message.text.isEmpty && message.isStreaming {
                // Nothing streamed yet — hold the shape so the glass doesn't pop in.
                Text("…").font(Tok.TypeScale.body).foregroundStyle(.tertiary)
            } else {
                MarkdownText(raw: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Size the bubble to its content rather than the 620pt track, so a short message
        // stays a short bubble.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Tok.Space.base)
        .padding(.vertical, Tok.Space.snug + 1)
        .glassEffect(
            isUser ? Tok.Surface.accent(Tok.Palette.user.opacity(0.55)) : Tok.Surface.panel,
            in: .rect(cornerRadius: Tok.Radius.card)
        )
        .glassEffectID(GlassID.message(message.id), in: namespace)
    }
}

/// Spectral sweep while tokens are arriving. Reads as light refracting through the glass
/// rather than a spinner bolted on top.
struct StreamingPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: Tok.Palette.spectrum + [Tok.Palette.spectrum[0]],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: 26, height: 3)
            .mask {
                Capsule().fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, phase - 0.35)),
                            .init(color: .white, location: phase),
                            .init(color: .clear, location: min(1, phase + 0.35)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            }
            .opacity(reduceMotion ? 0.9 : 1)
            .onAppear {
                guard !reduceMotion else { phase = 0.5; return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
            .accessibilityLabel("Responding")
    }
}

// MARK: - Tool chips

/// Tool calls share a union id, so adjacent chips fuse into one liquid blob and split apart
/// as they resolve. This is the `glassEffectUnion` payoff — it only works inside a
/// `GlassEffectContainer`.
struct ToolChipCluster: View {
    let calls: [ToolCall]
    let namespace: Namespace.ID

    var body: some View {
        FlowLayout(spacing: Tok.Space.tight) {
            ForEach(calls) { call in
                ToolChip(call: call, namespace: namespace)
            }
        }
    }
}

struct ToolChip: View {
    let call: ToolCall
    let namespace: Namespace.ID
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: (icon: String, tint: Color) {
        if call.deniedInput != nil { return ("hand.raised.fill", Tok.Palette.warn) }
        if call.isError { return ("exclamationmark.triangle.fill", Tok.Palette.danger) }
        if call.result == nil { return ("circle.dotted", Tok.Palette.tool) }
        return ("checkmark", Tok.Palette.approve)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            Button {
                withAnimation(Tok.Motion.resolved(Tok.Motion.glass, reduceMotion: reduceMotion)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Tok.Space.tight) {
                    Image(systemName: state.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(state.tint)
                    Text(call.name).font(Tok.TypeScale.mono)
                    if !call.detail.isEmpty {
                        Text(shortened(call.detail))
                            .font(Tok.TypeScale.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Tok.Space.snug)
                .padding(.vertical, Tok.Space.tight)
            }
            .buttonStyle(.plain)
            .glassEffect(
                Tok.Surface.accentInteractive(state.tint.opacity(0.4)),
                in: .rect(cornerRadius: Tok.Radius.chip)
            )
            .glassEffectID(GlassID.tool(call.id), in: namespace)
            // Unresolved chips fuse together; resolved ones separate out.
            .glassEffectUnion(
                id: call.result == nil ? "tools-pending" : nil,
                namespace: namespace
            )

            if expanded, let detail = expandedDetail {
                Text(detail)
                    .font(Tok.TypeScale.mono)
                    .textSelection(.enabled)
                    .padding(Tok.Space.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(Tok.Surface.panel, in: .rect(cornerRadius: Tok.Radius.chip))
                    .transition(.glassAppear(reduceMotion: reduceMotion))
            }
        }
    }

    private var expandedDetail: String? {
        if let denied = call.deniedInput {
            return denied.sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value.prefix(600))" }
                .joined(separator: "\n")
        }
        return call.result.map { String($0.prefix(2000)) }
    }

    private func shortened(_ s: String) -> String {
        guard s.count > 42 else { return s }
        return "…" + s.suffix(40)
    }
}

// MARK: - Layout

/// Wrapping row layout for the tool chips. SwiftUI has no built-in flow layout, and chips
/// need to wrap rather than compress for the fusion effect to read correctly.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// Content entering a glass surface. Reduce Motion gets a plain fade rather than a
    /// faster version of the same movement.
    static func glassAppear(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.98)),
                removal: .opacity
            )
    }
}
