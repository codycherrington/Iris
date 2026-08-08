import Foundation
import Observation

// MARK: - Model

/// The assistant's identity and the user's context.
///
/// This is deliberately *configuration*, not decoration. `systemPrompt` is handed to every
/// session via `--append-system-prompt`, so editing a field here changes how the agent
/// actually behaves — the acceptance test for this phase is asking a fresh session who it is
/// and getting the configured name back.
struct Persona: Codable, Equatable, Sendable {
    var assistantName: String = "Iris"
    /// Voice and manner. Free text: it's pasted into the system prompt as written.
    var personality: String = ""
    var userName: String = ""
    var userRole: String = ""
    /// Team, manager, domain — whatever the agent should assume without being told again.
    var workContext: String = ""

    /// Rendered system prompt, or `nil` when nothing has been filled in and there is
    /// genuinely nothing to append. Never send an empty `--append-system-prompt`.
    var systemPrompt: String? {
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [String] = []

        let name = clean(assistantName)
        if !name.isEmpty {
            lines.append(
                "Your name is \(name). When asked who you are, answer as \(name) — not as "
                + "Claude Code, and not as a generic assistant."
            )
        }
        if !clean(personality).isEmpty {
            lines.append("Voice and manner: \(clean(personality))")
        }

        var about: [String] = []
        if !clean(userName).isEmpty { about.append("goes by \(clean(userName))") }
        if !clean(userRole).isEmpty { about.append("works as \(clean(userRole))") }
        if !about.isEmpty {
            lines.append("You are working with someone who " + about.joined(separator: ", and ") + ".")
        }
        if !clean(workContext).isEmpty {
            lines.append("Context you should assume without being reminded: \(clean(workContext))")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }
}

// MARK: - Store

/// Persists the persona to `~/Library/Application Support/Iris/persona.json`.
///
/// A plain JSON file rather than `UserDefaults` on purpose: the whole point of this phase is
/// that the persona is real config, so it should be a file you can open, read, diff, and
/// hand-edit. Application Support, not the repo — this is machine state, and the repo is in
/// iCloud.
@MainActor
@Observable
final class PersonaStore {
    static let shared = PersonaStore()

    private(set) var persona: Persona
    /// True when no persona file existed at launch — i.e. this is a genuine first run.
    /// Writing the file on completion is what clears it, so skipping the wizard still counts
    /// as answering it and you don't get asked forever.
    private(set) var needsSetup: Bool

    private static var directoryURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Iris", isDirectory: true)
    }
    private static var fileURL: URL {
        directoryURL.appendingPathComponent("persona.json")
    }

    init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode(Persona.self, from: data) else {
            persona = Persona()
            needsSetup = true
            return
        }
        persona = decoded
        needsSetup = false
    }

    /// Re-read from disk, discarding the in-memory copy.
    ///
    /// Necessary because `persona.json` has a second author: Iris itself can edit the file,
    /// since it's real config sitting in reach of the agent's own file tools. Without this,
    /// opening the wizard would show the stale launch-time values and saving would quietly
    /// overwrite whatever the agent wrote.
    func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode(Persona.self, from: data) else { return }
        persona = decoded
        needsSetup = false
    }

    /// Save and mark setup done. Throwing is swallowed deliberately — a persona that fails to
    /// persist should not block the user from using the app this session.
    func save(_ persona: Persona) {
        self.persona = persona
        needsSetup = false
        do {
            try FileManager.default.createDirectory(
                at: Self.directoryURL, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(persona).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Iris: failed to persist persona — \(error)")
        }
    }
}
