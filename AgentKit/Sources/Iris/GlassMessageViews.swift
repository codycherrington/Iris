import AgentKit
import SwiftUI

// MARK: - Message

struct GlassMessageRow: View {
    let message: ChatMessage
    let namespace: Namespace.ID
    /// True only for the newest message while the session is idle. A question card is
    /// interactive exactly then — scrolling back to an old question and clicking it would
    /// answer a turn that has long since moved on.
    var isAnswerable = false
    var onAnswer: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isUser: Bool { message.role == .user }
    private var accent: Color { isUser ? Tok.Palette.user : Tok.Palette.agent }

    var body: some View {
        // The row must span the full transcript width or the Spacer has nothing to push
        // against and every bubble collapses toward the leading edge.
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: Tok.Space.wide) }

            // Actions above the answer: they're the lead-up to it, not a trailing footnote.
            // Thinking isn't a bubble of its own — the CLI never emits reasoning text, only a
            // token estimate, so there'd be nothing to open. It rides in the bubble header.
            VStack(alignment: isUser ? .trailing : .leading, spacing: Tok.Space.snug) {
                if !message.toolCalls.isEmpty {
                    ToolChipCluster(calls: message.toolCalls, namespace: namespace)
                }
                if !message.text.isEmpty || message.isStreaming {
                    contentBody
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

    @ViewBuilder
    private var contentBody: some View {
        let parsed = message.parsed
        // Pulse only while there's genuinely nothing to show yet. Once text is actually
        // streaming, the growing text itself is the "alive" signal — a header badge pinned
        // above it just looks stuck once the bubble has grown well past it.
        // A message whose only content so far is a half-arrived question block counts as
        // still waiting, since there's nothing to read yet.
        let isWaiting = message.isStreaming && parsed.text.isEmpty && parsed.question == nil
        VStack(alignment: isUser ? .trailing : .leading, spacing: Tok.Space.tight) {
            HStack(spacing: Tok.Space.tight) {
                if isUser {
                    Text("You").font(Tok.TypeScale.label).foregroundStyle(accent)
                    Circle().fill(accent).frame(width: 5, height: 5)
                } else {
                    // The name and its dot breathe as one while the turn works. Grouped so
                    // they share a single animation — driven separately they drift apart.
                    HStack(spacing: Tok.Space.tight) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text("Iris").font(Tok.TypeScale.label).foregroundStyle(accent)
                    }
                    .breathing(isWaiting)

                    if message.didThink {
                        // Past tense once the answer starts: the reasoning is over, but how
                        // much of it there was stays on the record.
                        Text(isWaiting ? "thinking" : "thought")
                            .font(Tok.TypeScale.label)
                            .foregroundStyle(.secondary)
                    }
                    if let tokens = message.thinkingTokens, tokens > 0 {
                        Text("\(tokens) tokens")
                            .font(Tok.TypeScale.mono)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if parsed.text.isEmpty && message.isStreaming && parsed.question == nil {
                // Nothing streamed yet — hold the shape so the glass doesn't pop in.
                Text("…").font(Tok.TypeScale.body).foregroundStyle(.tertiary)
            } else if !parsed.text.isEmpty {
                // No maxWidth here: forcing .infinity stretched the bubble across the whole
                // 620pt track, which made a right-aligned bubble still *look* left-aligned
                // because its text sat at the far edge. Let it hug its content instead.
                MarkdownText(raw: parsed.text)
                    .multilineTextAlignment(.leading)
            }

            if parsed.isPending {
                // The block is mid-stream. Say a question is coming rather than letting raw
                // JSON scroll past one delta at a time.
                Label("preparing a question…", systemImage: "questionmark.bubble")
                    .font(Tok.TypeScale.label)
                    .foregroundStyle(.tertiary)
            }

            if let question = parsed.question {
                QuestionCard(question: question,
                             isAnswerable: isAnswerable,
                             onAnswer: onAnswer)
            }
        }
        .padding(.horizontal, Tok.Space.base)
        .padding(.vertical, Tok.Space.snug + 1)
        .glassEffect(
            isUser ? Tok.Surface.accent(Tok.Palette.user.opacity(0.55)) : Tok.Surface.panel,
            in: .rect(cornerRadius: Tok.Radius.card)
        )
        .glassEffectID(GlassID.message(message.id), in: namespace)
    }
}

/// A slow opacity breath while a turn is still working.
///
/// Replaces an earlier sweeping-capsule shimmer: a separate animated element beside the name
/// read as a loading spinner bolted onto the glass. Dimming the label itself says the same
/// thing without adding a second object to look at.
struct Breathing: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.35 : 1)
            .animation(
                isActive && !reduceMotion
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: dimmed
            )
            .onAppear { dimmed = isActive && !reduceMotion }
            .onChange(of: isActive) { _, active in dimmed = active && !reduceMotion }
            .accessibilityLabel(isActive ? "Responding" : "")
    }
}

extension View {
    /// Breathe while `isActive`; settle to full opacity when it clears.
    func breathing(_ isActive: Bool) -> some View {
        modifier(Breathing(isActive: isActive))
    }
}

// MARK: - Question card

/// Iris's question, rendered as controls.
///
/// Answering sends the chosen label back as an ordinary user turn — the same thing you'd
/// have typed. That keeps the transcript honest: there's no hidden side channel, and the
/// conversation reads correctly if you reopen it later or resume the session elsewhere.
struct QuestionCard: View {
    let question: AgentQuestion
    let isAnswerable: Bool
    let onAnswer: (String) -> Void

    @State private var selected: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            Text(question.question)
                .font(Tok.TypeScale.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                optionRow(option)
            }

            if question.multiSelect {
                HStack(spacing: Tok.Space.tight) {
                    Button("Send \(selected.count) selected") {
                        // Stable order: the options as written, not the order they were
                        // clicked in.
                        let ordered = question.options
                            .map(\.label).filter(selected.contains)
                        onAnswer(ordered.joined(separator: ", "))
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Tok.Palette.agent)
                    .font(Tok.TypeScale.label)
                    .disabled(selected.isEmpty || !isAnswerable)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }

            if !isAnswerable {
                Text("Answered — or type anything to reply instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Tok.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.Palette.agent.opacity(0.06),
                    in: .rect(cornerRadius: Tok.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Tok.Radius.chip)
                .strokeBorder(Tok.Palette.agent.opacity(isAnswerable ? 0.28 : 0.10),
                              lineWidth: 1)
        )
        .padding(.top, Tok.Space.hair)
    }

    private func optionRow(_ option: AgentQuestion.Option) -> some View {
        let isOn = selected.contains(option.label)
        return Button {
            if question.multiSelect {
                if isOn { selected.remove(option.label) } else { selected.insert(option.label) }
            } else {
                onAnswer(option.label)
            }
        } label: {
            HStack(alignment: .top, spacing: Tok.Space.tight) {
                Image(systemName: marker(isOn: isOn))
                    .font(.system(size: 11))
                    .foregroundStyle(isOn ? AnyShapeStyle(Tok.Palette.agent)
                                          : AnyShapeStyle(.tertiary))
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(Tok.TypeScale.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(Tok.TypeScale.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, Tok.Space.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.glassRow)
        .disabled(!isAnswerable)
        .background(
            RoundedRectangle(cornerRadius: Tok.Radius.chip)
                .fill(isOn ? Tok.Palette.agent.opacity(0.10) : .clear)
        )
    }

    private func marker(isOn: Bool) -> String {
        if question.multiSelect {
            return isOn ? "checkmark.square.fill" : "square"
        }
        return isOn ? "largecircle.fill.circle" : "circle"
    }
}

// MARK: - Tool chips

/// One chip per action, each its own glass shape. These deliberately do *not* share a
/// `glassEffectUnion` — adjacent chips fusing into a single blob made a run of tool calls
/// unreadable as distinct steps.
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
            .buttonStyle(.glassChip)
            .glassEffect(
                Tok.Surface.accentInteractive(state.tint.opacity(0.4)),
                in: .rect(cornerRadius: Tok.Radius.chip)
            )
            .glassEffectID(GlassID.tool(call.id), in: namespace)

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
