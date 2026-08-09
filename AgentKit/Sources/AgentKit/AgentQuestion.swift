import Foundation

/// A question Iris asks back, rendered as real controls instead of a paragraph of "A) … B) …".
public struct AgentQuestion: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable, Identifiable {
        public let label: String
        public let description: String?
        public var id: String { label }

        public init(label: String, description: String?) {
            self.label = label
            self.description = description
        }

        private enum CodingKeys: String, CodingKey {
            case label, description
        }

        /// `description` is genuinely optional in the prompt's schema and models do omit it.
        /// Synthesized decoding handles a missing Optional correctly, but this is written
        /// alongside the parent's hand-rolled initializer so both live in one place.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            description = try container.decodeIfPresent(String.self, forKey: .description)
        }
    }

    public let question: String
    public let options: [Option]
    public var multiSelect: Bool = false

    public init(question: String, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    private enum CodingKeys: String, CodingKey {
        case question, options, multiSelect
    }

    /// Hand-written because Swift's synthesized `Decodable` **ignores default values**: a
    /// payload omitting `multiSelect` throws rather than defaulting to false, and the whole
    /// question then fails to render with no visible reason. The prompt asks for the field,
    /// but a model dropping an optional-looking flag is exactly the kind of drift this
    /// project decodes around rather than trusting — same rule as the stream-json decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        options = try container.decode([Option].self, forKey: .options)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }
}

/// The convention Iris uses to ask a question, and the parser that reads it back.
///
/// **Why a convention and not a tool.** Claude Code has an `AskUserQuestion` tool, and hooking
/// it would have been the obvious design. It isn't available here: a `claude -p` session
/// reports 67 tools in `system/init` and `AskUserQuestion` is not among them — checked
/// against 2.1.226, not assumed. Interactive prompting is a property of the interactive TTY,
/// and print mode has no way to block a turn on a human.
///
/// So the question travels the only channel that exists — the assistant's own text — as a
/// fenced block the app extracts and replaces with a card. The answer goes back as an
/// ordinary user turn, which is exactly what the user would have typed anyway.
///
/// **Consequences worth knowing.** This is a cooperative protocol, not an enforced one: if
/// the model writes prose instead, nothing breaks and the question simply renders as text.
/// If the JSON is malformed, the block is deliberately left visible rather than swallowed,
/// so a bad payload is debuggable instead of invisible.
public enum QuestionProtocol {

    public static let fence = "```iris:question"

    /// Appended to every session's system prompt alongside the persona.
    ///
    /// Deliberately narrow about when to use it. A model that reaches for a picker on every
    /// turn is worse than one that never does — the whole value is that a card means "this is
    /// a real decision point", and that signal dies if it fires on rhetorical questions.
    public static let systemPrompt = """
        When you need a decision from the user and the sensible answers are a small set of \
        choices, ask with a question block rather than prose. The app renders it as real \
        buttons and sends the answer back as the user's next message.

        \(fence)
        {"question": "Which should I use?", "options": [{"label": "Option A", \
        "description": "One line on what this means or costs."}, {"label": "Option B", \
        "description": "The tradeoff against A."}], "multiSelect": false}
        ```

        Rules:
        - Only for genuine decision points where you would otherwise stop and wait. Not for \
        rhetorical questions, and not to confirm something you should just do.
        - Two to four options. If there are more, it isn't a multiple-choice question.
        - `label` is 1–5 words. `description` is one short line on what picking it means.
        - Set `multiSelect` to true only when picking several genuinely makes sense.
        - Put the block last, with nothing after it. A sentence of context before it is fine.
        - Don't list the options again in prose — they'd appear twice.
        - The user can always ignore the buttons and type something else, so don't add an \
        "other" or "something else" option.
        """

    /// Splits an assistant message into what to display and the question it carries.
    ///
    /// - `text`: the message with the block removed, ready to render.
    /// - `question`: parsed, when a complete and well-formed block was present.
    /// - `isPending`: an opening fence with no closing fence yet — i.e. the block is still
    ///   streaming in. Callers use this to hold the card's space instead of flashing raw
    ///   JSON across the transcript one delta at a time.
    public static func split(_ raw: String) -> (text: String, question: AgentQuestion?, isPending: Bool) {
        // Cheap early-out: this runs on every streamed delta, and the overwhelming majority
        // of messages never contain a block at all.
        guard raw.contains(fence) else { return (raw, nil, false) }
        guard let openRange = raw.range(of: fence) else { return (raw, nil, false) }

        let afterOpen = raw[openRange.upperBound...]
        guard let closeRange = afterOpen.range(of: "```") else {
            // Still arriving. Show everything before the fence and nothing of the payload.
            return (String(raw[..<openRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    nil, true)
        }

        let payload = afterOpen[..<closeRange.lowerBound]
        let before = String(raw[..<openRange.lowerBound])
        let after = String(afterOpen[closeRange.upperBound...])
        let remainder = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = payload.data(using: .utf8),
              let question = try? JSONDecoder().decode(AgentQuestion.self, from: data),
              !question.options.isEmpty else {
            // Malformed. Leave the raw block in place — a question that silently vanishes is
            // far worse to debug than one that renders as ugly JSON.
            return (raw, nil, false)
        }

        return (remainder, question, false)
    }
}
