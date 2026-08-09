import AgentKit
import Foundation
import Observation

/// Which model the session runs on and how hard it's allowed to think.
///
/// Both are launch arguments (`--model`, `--effort`), so changing either restarts the
/// session — the same constraint the persona has. There's no way to re-flag a running
/// process.
struct SessionSettings: Codable, Equatable, Sendable {
    /// A CLI alias rather than a pinned id: `sonnet` always resolves to the current Sonnet,
    /// so this doesn't silently strand the app on an old model when a new one ships.
    var model: String = "sonnet"
    var effort: AgentConfiguration.Effort = .medium

    /// Sonnet at medium. Fast enough to feel like the terminal, and the effort level where
    /// reasoning still helps without every turn paying for `xhigh`.
    static let `default` = SessionSettings()
}

/// The models worth offering. Deliberately not every id the CLI accepts — this is a picker,
/// not a catalogue. `label` is what shows in the chip.
struct ModelChoice: Identifiable, Sendable {
    let id: String
    let label: String
    let note: String

    static let all: [ModelChoice] = [
        ModelChoice(id: "sonnet", label: "Sonnet 5", note: "Balanced. The default."),
        ModelChoice(id: "opus", label: "Opus 5", note: "Deepest reasoning, slowest, most quota."),
        ModelChoice(id: "haiku", label: "Haiku 4.5", note: "Fastest, cheapest on quota."),
        ModelChoice(id: "fable", label: "Fable 5", note: "Writing and prose."),
    ]

    /// Map whatever `system/init` reports back onto a short label. The CLI answers with a
    /// full id (`claude-sonnet-4-5-20250929`), which is too long for the status bar.
    static func label(forReportedModel model: String) -> String {
        if let match = all.first(where: { model.contains($0.id) }) { return match.label }
        return model
    }
}

extension AgentConfiguration.Effort: Codable {}

extension AgentConfiguration.Effort {
    var note: String {
        switch self {
        case .low: "Barely reasons. Quickest turns."
        case .medium: "Reasons when it helps. The default."
        case .high: "Thinks hard on most turns."
        case .xhigh: "Very deep. Noticeably slower."
        case .max: "Everything it has. Slowest, heaviest on quota."
        }
    }
}

/// Persists session settings to `UserDefaults`.
///
/// Not a JSON file like the persona: the persona is deliberately *inspectable config* the
/// agent itself can read and edit (ADR-007), whereas this is an app preference with no reason
/// to be in the agent's reach.
@MainActor
@Observable
final class SessionSettingsStore {
    static let shared = SessionSettingsStore()

    private(set) var settings: SessionSettings

    private static let key = "iris.sessionSettings"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(SessionSettings.self, from: data) else {
            settings = .default
            return
        }
        settings = decoded
    }

    func save(_ settings: SessionSettings) {
        self.settings = settings
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
