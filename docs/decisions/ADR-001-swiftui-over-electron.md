# ADR-001 — SwiftUI over Electron

**Date:** 2026-08-07
**Status:** Accepted

## Context

Iris needs a macOS UI wrapping an agent loop. Cody's existing desktop app (Ledger) is Electron
43 + React 19 + Tailwind 4 + Vite + vitest, with a working build, test, and packaging
pipeline. Across thirty projects there was no Swift. The visual brief called for real macOS 26
Liquid Glass, slick animations, "crisp, professional, futuristic".

The first analysis recommended Electron, weighting "learning Swift from zero" as a major cost
and noting that Electron `BrowserWindow` can use genuine `NSVisualEffectView` vibrancy, giving
real system blur with Liquid Glass approximated in CSS on top.

Cody rejected that premise: he has written Swift at work, and considers language familiarity a
non-issue. That removed the main argument for Electron.

## Decision

Build Iris as a native SwiftUI app targeting macOS 26.

## Alternatives considered

- **Electron + React.** Reuses the entire Ledger pipeline and ships fastest. Rejected once the
  language argument collapsed: it can only approximate Liquid Glass in CSS, produces a ~150 MB
  app, and — decisively — its natural agent integration (the TS Agent SDK) leads to API-key
  billing (see ADR-002).
- **SwiftUI + Node sidecar running the TS Agent SDK.** Real glass *and* the typed SDK.
  Rejected: same auth problem, plus bundling and notarizing a Node runtime inside the `.app`
  for no gain over talking to the CLI directly.
- **Electron now, SwiftUI later.** Build twice deliberately. Rejected as strictly more work
  than starting where we intended to end up.

## Consequences

- Real `glassEffect` / `GlassEffectContainer` / `glassEffectID`, not a CSS approximation.
- ~15 MB native binary; native scroll, text, and animation performance.
- Requires Xcode 26 (installed mid-conversation) and macOS 26+ to run.
- No reuse of Ledger's pipeline — new build, test, and packaging setup.
- No Swift binding for the Agent SDK, which forces the subprocess architecture in ADR-002.
  This turned out to be a benefit, not a cost.
