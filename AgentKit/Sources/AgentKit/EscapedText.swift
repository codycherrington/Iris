import Foundation

// MARK: - Double-escaped model output

public extension String {

    /// Reverse **one** layer of JSON string escaping, but only when the string is
    /// unambiguously double-escaped.
    ///
    /// Structured output goes through `JSONDecoder` already, so a `\n` the model wrote
    /// correctly arrives here as a real newline — there is nothing left to undo. What this
    /// repairs is the case where the model escaped its own escapes: it emitted `\\n` and
    /// `\\"` into the tool-call JSON, the decoder faithfully produced a backslash followed
    /// by `n`, and the panel rendered
    ///
    /// ```
    /// three changes:\n\n**1. Input keybindings:**\n- Return key sends the message.
    /// ```
    ///
    /// instead of formatted text. Observed live in the prompt improver on 2026-08-10; five
    /// attempts to reproduce it against the same model, prompt and schema all came back with
    /// real newlines, so it is intermittent rather than a property of the pipeline. That is
    /// the argument for repairing it here rather than in the prompt: the prompt cannot make
    /// an intermittent failure impossible, and the failure is trivially detectable.
    ///
    /// The trigger is deliberately narrow — a correctly-decoded multi-line string contains
    /// **real** control characters, so the presence of escape *sequences* alongside the
    /// complete absence of the characters they stand for is the signature. A string that is
    /// merely talking about `\n` on a single line will be rewritten by this; that is the
    /// known false positive, and it is preferred to leaving genuinely broken output on
    /// screen.
    var repairingDoubleEscapedJSON: String {
        guard contains(#"\n"#) || contains(#"\t"#) || contains(#"\""#) else { return self }
        guard !contains("\n"), !contains("\t") else { return self }
        // Re-parse as the body of a JSON string. Anything that isn't valid at that level —
        // a bare quote, a trailing lone backslash, an invalid `\x` — fails to decode and the
        // original is returned untouched.
        guard let data = "\"\(self)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data)
        else { return self }
        return decoded
    }
}

public extension Array where Element == String {
    /// `repairingDoubleEscapedJSON` across a list — model output arrives as often in arrays
    /// of prose (issues, findings) as in single fields.
    var repairingDoubleEscapedJSON: [String] { map(\.repairingDoubleEscapedJSON) }
}
