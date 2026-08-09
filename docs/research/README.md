# Research notes

Things learned that are worth citing later. Written for a future reader who wasn't here.

| File | What |
|---|---|
| `stream-json-protocol.md` | The CLI wire protocol, reverse-engineered from real captures. Several event types are undocumented publicly — this is currently our best reference. **Includes the 2026-08-08 finding that thinking text is never emitted, only a token estimate**, and the 2026-08-09 section on one-shot `-p` + `--json-schema` runs. |
| `one-shot-cost-model.md` | What a short-lived `claude -p` call actually costs, measured: 18,854 cache-creation tokens / 32.5 s / opus-5 default vs 0 / 6.6 s / haiku stripped. Why isolation isn't cheapness, and why quota — not dollars — is the constraint on subscription auth. |
| `process-termination-status-trap.md` | `Process.terminationStatus` raises an uncatchable ObjC exception on a live process and aborts the app. Plus the general rule: subprocess failure paths can't be tested with fixtures. |
| `liquid-glass-api.md` | Where the macOS 26 Liquid Glass API actually lives, its surface, why `glassEffectID`/`glassEffectUnion` define Iris's animation language — and where fusion turned out to be the wrong default. |
| `observable-state-in-swiftui.md` | `@Bindable` is for writing, not for observing. A wrapper object constructed inside `body` defeats `@Observable` tracking entirely — found and fixed while building the sidebar (2026-08-09). |
| `sf-symbol-glyph-centering.md` | An SF Symbol's ink can sit off-center in its own design box independent of the frame around it — sizing the frame to match a sibling control doesn't fix it. |
| `voice-mode-feasibility.md` | Considered and **deferred** 2026-08-09, not planned. Realtime speech-to-speech models replace the agent loop entirely; only a cascaded STT → `send()` → TTS pipeline would preserve Iris's architecture. |

Add a file whenever you learn something non-obvious about the protocol, SwiftUI/Liquid Glass
behavior, subprocess/pipe handling, or Claude Code internals. Record observed payloads and
measured numbers, not paraphrases.
