# 2026-08-08 — Committing to dark, a send-button fix, and a phase-gate audit

## Where the day started

Picking up the morning after inception night. Everything up through `95673a9` (message bubble
+ send button sizing) landed 2026-08-07 late evening: scaffold, `AgentBridge`, the chat UI,
the Liquid Glass design system, and a round of transcript/composer/glass-fusion fixes. Branch
is still `20260807-Agent-Bridge`, HEAD at `95673a9` as of this session.

## Status audit first

Before touching anything: `make test` — 24/24 AgentKit tests pass (13 decoding, 11 line
assembler). `make build` is clean. No code was changed for this part.

That audit turned up a real deviation from CLAUDE.md's "phases are sequential" rule. Phase 2's
exit bar is explicit in `docs/plan.md`: *"use it for a real task and compare against the
terminal... Constraint #3 is re-tested here with a real UI attached, before any time goes into
aesthetics."* That never happened. The Ledger card for it (`ZnjemQrp6PwfQto_R1DKN`,
"PERF GATE — head-to-head vs terminal") is still in **To Do**, and `docs/runs/README.md` is
still the untouched template — no run has ever been recorded there.

Meanwhile Phase 3 work (Liquid Glass) already landed on top of the ungated Phase 2:
`GlassContentView.swift`, `GlassMessageViews.swift`, and `DesignTokens.swift` all exist, and
`IrisApp.swift` boots straight into `GlassContentView`, not the plain Phase 2 `ContentView`
(which still exists in the tree, unused as the app's entry point). Functionally the Phase 1
and most of Phase 2 acceptance criteria check out against real code and tests when verified
line by line — see the Ledger section below — so this isn't a "nothing was built" problem.
It's that the one measurement gate CLAUDE.md calls non-negotiable (*"Never regress the perf
gate... if a change makes Iris feel slower than the terminal, it doesn't ship"*) was skipped in
practice while newer, more visually exciting work kept moving. Worth naming plainly rather than
quietly backfilling: the gate is still unmet, and Phase 3 output already exists regardless.

## Send-button glyph, take two

`SendButton` in `GlassContentView.swift` renders `arrow.up` (idle) or `stop.fill` (busy) in a
42×42 frame — 42pt chosen to match the composer text field's row height (20pt content + 11pt
padding top and bottom) so button and field read as one row. Commit `95673a9` removed a
per-glyph `.offset(y: -1)` nudge on the theory that matching frame size to row height would
center the glyph on its own.

It didn't. Cody reported the arrow still looked visually low and to the right inside the
circle. The fix — a small counter-offset restored, `.offset(x: isBusy ? 0 : -1, y: isBusy ? 0
: -1)`, applied only to the `arrow.up` case since `stop.fill` is symmetric and needs none —
was verified against a live screenshot Cody took of the running app, confirmed centered.

The underlying lesson (see `docs/research/sf-symbol-glyph-centering.md`): an SF Symbol's ink
can sit off-center within its own design box independent of the frame it's placed in. Sizing
the frame to match a sibling control does nothing for that — it's a property of the glyph, not
the layout. Worth having on file before "fixing" any other glyph-in-circle button the same
wrong way later in the project (the interrupt/stop button, any future icon-only button in a
circular frame).

## The dark theme commitment

The most consequential change of the day. Cody asked for the whole app to commit to one dark,
near-black look — neon cyan and ice white accents, still Liquid Glass — instead of following
system light/dark appearance. The prior design implicitly assumed adaptive glass:
`AuroraBackdrop` read `@Environment(\.colorScheme)` and filled its base with `Rectangle().fill(.background)`,
a system material color that changes with the OS appearance.

Changes, all in `DesignTokens.swift` unless noted:

- New `Tok.Palette.background`: `Color(red: 0.02, green: 0.035, blue: 0.045)`. Deliberately
  not pure black — flat `#000` gives Liquid Glass nothing to refract, so it carries a hair of
  blue.
- `Tok.Palette.user`: cool blue (`0.42, 0.62, 1.00`) → ice white (`0.88, 0.96, 1.00`).
- `Tok.Palette.agent`: iris violet (`0.72, 0.52, 1.00`) → neon cyan (`0.00, 0.95, 1.00`).
- `Tok.Palette.tool`: shifted to a deeper cyan-teal (`0.15, 0.70, 0.78`).
- `approve` / `warn` / `danger` kept their hue families (mint-green / amber / red) — a fully
  monochrome status/error state would hurt usability — but were re-tuned slightly for the
  darker background.
- `Tok.Palette.spectrum` (drives the `AuroraBackdrop` blobs, the `GlassEmptyState` breathing
  rings, and the streaming shimmer in `GlassMessageViews.swift`) changed from a 3-hue sweep
  (blue/violet/cyan) to `[agent, user, tool]` — cyan → ice white → teal — so the ambient drift
  reads as one theme rather than a rainbow.

In `GlassContentView.swift`, `AuroraBackdrop`'s base fill changed from `Rectangle().fill(.background)`
to `Rectangle().fill(Tok.Palette.background)`. In `IrisApp.swift`, `.preferredColorScheme(.dark)`
was added to the window content so the glass material always renders its dark variant against
the new fixed backdrop.

Cody screenshotted the result — a message exchange with the cyan/teal `AuroraBackdrop` glow
visible behind the bubbles — and reacted "BEAUTIFUL." No further visual iteration was
requested; treating that as confirmed for now. See `docs/decisions/ADR-006-commit-to-dark-theme.md`
for the full context/decision/consequences writeup, including a flagged follow-up: the
`scheme == .dark` conditional branch still in `AuroraBackdrop` (line ~215) is now dead code
since `scheme` will always read `.dark` under the forced color scheme. Left as-is — docs only,
no code touched this session — flagged for whoever next edits that file.

These three files are uncommitted in the working tree as of this entry (`DesignTokens.swift`,
`GlassContentView.swift`, `IrisApp.swift`); Cody hasn't asked for a commit yet.

## A standing process rule, for honesty's sake

Mid-session the assistant used `screencapture` + `osascript activate` directly to inspect the
send button, and separately tried `mcp__computer-use__request_access` against the Iris.app
bundle — that failed with `not_installed` (it's an ad-hoc SwiftPM-built `.app`, not registered
with LaunchServices the way computer-use's app resolution expects) even after an
`lsregister -f` attempt.

Cody's response: *"no more screenshots by you throughout this entire project — just rebuild
the app after changes and I'll screenshot for you."* This is a standing rule for the rest of
the project, not a one-off correction — future sessions should rebuild via `make` and wait for
Cody to screenshot, not attempt computer-use or `screencapture` against Iris.app.

## Ledger board reality check

Verified Phase 1 and Phase 2 folders and every task card inside them against the real code and
`make test` output rather than trusting card titles. Both folders, and every task card in
them, are still sitting in **To Do** on the Iris board even though most of the underlying work
is written and tested. Full breakdown relayed to Cody separately (session summary) rather than
duplicated here — the short version is that Phase 1 is fully backed by code and tests, most of
Phase 2 is too, and the one item that is genuinely not done is the perf-gate task itself. Cards
were not moved — Cody moves them by hand.
