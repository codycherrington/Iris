# Research notes

Things learned that are worth citing later. Written for a future reader who wasn't here.

| File | What |
|---|---|
| `stream-json-protocol.md` | The CLI wire protocol, reverse-engineered from real captures. Several event types are undocumented publicly — this is currently our best reference. |
| `liquid-glass-api.md` | Where the macOS 26 Liquid Glass API actually lives, its surface, and why `glassEffectID`/`glassEffectUnion` define Iris's animation language. |
| `sf-symbol-glyph-centering.md` | An SF Symbol's ink can sit off-center in its own design box independent of the frame around it — sizing the frame to match a sibling control doesn't fix it. |

Add a file whenever you learn something non-obvious about the protocol, SwiftUI/Liquid Glass
behavior, subprocess/pipe handling, or Claude Code internals. Record observed payloads and
measured numbers, not paraphrases.
