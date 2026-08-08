import SwiftUI

/// First-launch flow: who the assistant is, who you are, what it should assume.
///
/// The last step shows the generated system prompt verbatim. That's deliberate — it's the
/// difference between a settings screen that stores strings and one that visibly configures
/// the agent. What you read there is exactly what gets appended to every session.
struct PersonaWizard: View {
    @State private var draft: Persona
    @State private var step = 0
    let onComplete: (Persona) -> Void
    let onCancel: (() -> Void)?

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Field?

    private enum Field { case assistantName, personality, userName, userRole, workContext }

    private static let steps = ["Assistant", "You", "Context"]

    init(persona: Persona,
         onComplete: @escaping (Persona) -> Void,
         onCancel: (() -> Void)? = nil) {
        _draft = State(initialValue: persona)
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(alignment: .leading, spacing: Tok.Space.loose) {
                header
                GlassEffectContainer(spacing: 0) {
                    stepBody
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(Tok.Space.wide)
        }
        .frame(width: 560, height: 460)
        .preferredColorScheme(.dark)
        .onAppear { focused = .assistantName }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
            Text(subtitle)
                .font(Tok.TypeScale.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Tok.Space.tight) {
                ForEach(Self.steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Tok.Palette.agent : Color.secondary.opacity(0.25))
                        .frame(width: i == step ? 22 : 10, height: 3)
                        .animation(Tok.Motion.resolved(Tok.Motion.touch,
                                                       reduceMotion: reduceMotion),
                                   value: step)
                }
            }
            .padding(.top, Tok.Space.tight)
        }
    }

    private var title: String {
        switch step {
        case 0: return "Who is your assistant?"
        case 1: return "Who are you?"
        default: return "What should it already know?"
        }
    }

    private var subtitle: String {
        switch step {
        case 0:
            return "A name and a manner. This becomes part of the system prompt, so it "
                 + "genuinely answers to it."
        case 1:
            return "So it doesn't have to ask, and can pitch its answers at the right level."
        default:
            return "Anything it should assume every session — your team, your stack, what "
                 + "you're building."
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: Tok.Space.base) {
                field("Name", text: $draft.assistantName, focus: .assistantName,
                      placeholder: "Iris")
                field("Personality", text: $draft.personality, focus: .personality,
                      placeholder: "Direct and dry. Skips preamble. Flags risk early.",
                      multiline: true)
            }
        case 1:
            VStack(alignment: .leading, spacing: Tok.Space.base) {
                field("Your name", text: $draft.userName, focus: .userName,
                      placeholder: "Cody")
                field("Your role", text: $draft.userRole, focus: .userRole,
                      placeholder: "Software engineer working mostly in Swift and TypeScript")
            }
        default:
            VStack(alignment: .leading, spacing: Tok.Space.base) {
                field("Standing context", text: $draft.workContext, focus: .workContext,
                      placeholder: "Who you report to, what your team owns, the projects "
                                 + "you come back to most.",
                      multiline: true)
                promptPreview
            }
        }
    }

    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            Text("Appended to every session")
                .font(Tok.TypeScale.label)
                .foregroundStyle(.tertiary)
            ScrollView {
                Text(draft.systemPrompt ?? "Nothing yet — Iris will run with its defaults.")
                    .font(Tok.TypeScale.mono)
                    .foregroundStyle(draft.systemPrompt == nil ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96)
            .padding(Tok.Space.snug)
            .glassEffect(Tok.Surface.panel, in: .rect(cornerRadius: Tok.Radius.chip))
        }
    }

    private func field(_ label: String,
                       text: Binding<String>,
                       focus: Field,
                       placeholder: String = "",
                       multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.tight) {
            Text(label)
                .font(Tok.TypeScale.label)
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: text, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(Tok.TypeScale.body)
                .lineLimit(multiline ? 3...3 : 1...1)
                .focused($focused, equals: focus)
                .padding(.horizontal, Tok.Space.base)
                .padding(.vertical, Tok.Space.snug)
                .glassEffect(Tok.Surface.interactive, in: .rect(cornerRadius: Tok.Radius.chip))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Tok.Space.snug) {
            if step > 0 {
                Button("Back") {
                    withAnimation(Tok.Motion.resolved(Tok.Motion.glass,
                                                      reduceMotion: reduceMotion)) {
                        step -= 1
                    }
                }
                .buttonStyle(.glass)
            }

            Spacer()

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
            } else {
                // First run has no cancel — but it must be skippable, or the app is
                // unusable until you've filled in a form you didn't ask for.
                Button("Skip") { onComplete(Persona()) }
                    .buttonStyle(.glass)
            }

            Button(step == Self.steps.count - 1 ? "Start" : "Next") {
                if step == Self.steps.count - 1 {
                    onComplete(draft)
                } else {
                    withAnimation(Tok.Motion.resolved(Tok.Motion.glass,
                                                      reduceMotion: reduceMotion)) {
                        step += 1
                    }
                    focused = step == 1 ? .userName : .workContext
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}
