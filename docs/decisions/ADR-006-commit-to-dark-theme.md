# ADR-006 — Commit to a single dark theme instead of system-adaptive appearance

**Date:** 2026-08-08
**Status:** Accepted

## Context

The Phase 3 Liquid Glass work landed 2026-08-07 with an implicit assumption baked into the
code, not stated anywhere in `docs/plan.md`: appearance would follow the system's light/dark
setting like any well-behaved macOS app. `AuroraBackdrop` in `GlassContentView.swift` read
`@Environment(\.colorScheme)` and filled its base with `Rectangle().fill(.background)` — a
system material color that resolves differently in light and dark mode — and `Tok.Palette`'s
accent colors (a cool blue for `user`, an iris-violet for `agent`) were chosen to work
reasonably in either.

Cody, looking at the running app on 2026-08-08, asked for something more specific: the whole
app committed to one dark, near-black look, with neon cyan and ice white as the accent colors,
while staying Liquid Glass. Not "dark mode support" — a single deliberate aesthetic that
doesn't change with the OS setting.

## Decision

Commit to dark, unconditionally:

- `IrisApp.swift` applies `.preferredColorScheme(.dark)` to the window content, so the glass
  material always renders its dark variant regardless of the user's system appearance setting.
- `Tok.Palette.background` is a new fixed token — `Color(red: 0.02, green: 0.035, blue: 0.045)`
  — used directly by `AuroraBackdrop`'s base fill instead of the system `.background` material.
  It's deliberately not pure black: flat `#000` gives Liquid Glass nothing to refract against,
  so a hair of blue is mixed in to give the glass something to catch.
- The accent palette moved from a blue/violet pairing chosen to survive either color scheme to
  one built for this specific dark background: `user` → ice white (`0.88, 0.96, 1.00`), `agent`
  → neon cyan (`0.00, 0.95, 1.00`), `tool` → a deeper cyan-teal (`0.15, 0.70, 0.78`). `approve`
  / `warn` / `danger` kept their existing hue families (mint-green / amber / red) — collapsing
  status colors into the monochrome cyan/white scheme would make errors and warnings harder to
  scan at a glance, which isn't worth the aesthetic purity.
- `Tok.Palette.spectrum`, which drives the `AuroraBackdrop` ambient blobs, the `GlassEmptyState`
  breathing rings, and the streaming-response shimmer, changed from an arbitrary 3-hue sweep to
  `[agent, user, tool]` (cyan → ice white → teal) so all of that ambient motion stays inside the
  committed theme instead of reading as an unrelated rainbow.

## Alternatives considered

- **Keep system-adaptive light/dark**, refining both variants. Rejected — this isn't what was
  asked for, and it works against the goal: Liquid Glass's light variant is bright and airy by
  design, which fights a palette built around a near-black base and neon accents. Maintaining
  two coherent looks would have cost real effort for a light mode nobody wants to see.
- **Dark as the default, with a light mode users can still opt into via system setting** (i.e.
  keep the `colorScheme` read, just default-bias the palette dark). Rejected as unnecessary
  complexity — there is exactly one target user right now (Cody), he asked for exactly one
  look, and shipping an unrequested light variant means testing and maintaining a path nobody
  exercises.
- **True black (`#000000`) background.** Considered and rejected in favor of the slightly
  blue-tinted near-black — pure black gives Liquid Glass's refraction and specular highlights
  nothing to work with, which would undercut the "still Liquid Glass" part of the brief.

## Consequences

- The app no longer respects the user's system light/dark setting. That's intentional for this
  project's current single-user, single-aesthetic scope, but should be revisited if Iris ever
  grows other users with different preferences.
- The `scheme == .dark` conditional branch still present in `AuroraBackdrop`
  (`GlassContentView.swift`, around line 215 — `color.opacity(scheme == .dark ? 0.30 : 0.16)`)
  is now dead code: `scheme` will always evaluate to `.dark` under the forced color scheme, so
  the `0.16` light-mode branch can never execute. Left in place as of this ADR — flagged here
  as a minor cleanup opportunity for whoever next touches that view, not fixed as part of this
  documentation pass.
- Any future UI element added to Iris should be designed against the fixed dark palette
  directly (`Tok.Palette.background` and friends), not against system materials — reaching for
  `.background`, `.secondary`, or other adaptive system colors will silently reintroduce
  light-mode assumptions that no longer make sense here.
- Visually confirmed against a live screenshot Cody took of the running app (message exchange
  with the cyan/teal `AuroraBackdrop` glow behind the bubbles); reaction was "BEAUTIFUL," no
  further visual iteration requested as of this ADR.
