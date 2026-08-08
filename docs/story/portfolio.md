# Iris — portfolio writeup (draft)

**Status:** outline seeded at inception 2026-08-07. Update as reality unfolds; do not write
the conclusion before there is one.

## Hook (candidates)

- *"I rebuilt my terminal AI workflow as a native Mac app — and set a rule that if it was ever
  slower than the terminal, I'd delete it."*
- *"The constraint that looked like it killed the native version turned out to be the reason
  it won."*
- Cold open on the subagent tree animating, then cut back to a plain terminal scroll.

The strongest angle is the **inversion**: every early assumption pointed at Electron, and each
one flipped under inspection.

## The setup

A tool at work wraps Claude Code in a GUI — persona wizard, two sidebars of small utilities.
Useful, and clearly could be much better looking. The brief: SwiftUI, real Liquid Glass, slick
animations. Build the version you'd actually want.

## The constraints that did the deciding

Two, and neither was technical taste:

1. **Subscription only.** No per-token API billing.
2. **Never slower than the terminal.** Otherwise it's a worse tool wearing a nicer coat.

## Three assumptions that flipped

Worth telling as a sequence, because each reversal is a small story:

1. **"Use Electron — it's the stack you know, and learning Swift is the real cost."**
   Wrong premise. Language familiarity stopped being a meaningful cost years ago. *"I don't
   know a single programmer worried about languages anymore."*

2. **"The Agent SDK is the right way to talk to the agent loop."**
   The SDK is TypeScript/Python only, and its documented auth path is API keys. The
   "fallback" for other languages — drive the CLI as a subprocess — is the *only* route that
   runs on a subscription. The constraint that seemed to rule out Swift actually ruled out the
   SDK.

3. **"The native permission UI will be the hard part."**
   Expected to need a locally-hosted MCP server and to risk deadlocking on a mid-turn pause.
   Reality: a denied tool completes its turn and hands back the full intended content. The
   hardest planned feature became one of the easier ones.

## Architecture

One diagram: SwiftUI ↔ an actor wrapping `Process` ↔ `claude -p` over NDJSON. Emphasize what
*isn't* there — no Node runtime, no sidecar, no API key, no vendored binary. And what comes
free: every existing skill, hook, MCP server and `CLAUDE.md`, because non-bare mode loads the
same context an interactive session does.

## Measurement as a design tool

The spike is the spine of the piece. Half a day, throwaway, with a kill criterion agreed in
advance. The table:

| Turn | `ttft_ms` | `time_to_request_ms` |
|---|---|---|
| 1 | 1434 | 20 |
| 2 | 1334 | 15 |
| 3 | 2285 | 7 |

And the reading that mattered: the scary 4.98 s first-turn wall clock was ~3.5 s of process
startup paid **once**, not per turn. Same number, opposite conclusion, depending on whether
you break it down. Good place to make the point that a measurement you don't decompose can
argue for the wrong architecture.

## Reverse-engineering an undocumented protocol

`rate_limit_event`, `system/thinking_tokens`, `system/permission_denied` — none in public
docs, all useful. On a subscription, a quota gauge beats a cost meter; live thinking-token
deltas beat a spinner. Ties to the testing strategy: captured fixtures as both regression
suite and protocol documentation.

## Liquid Glass

What `glassEffectID` + `glassEffectUnion` inside a `GlassEffectContainer` actually buy —
morphing, not just blur. Include the API-hunting anecdote (wrong framework, wrong arch, two
empty greps that nearly produced a wrong conclusion) as a lesson about negative evidence.

## Results

TODO — fill from Phase 2's head-to-head against the terminal, and whether Iris became the
daily driver. **Be honest if it didn't.**

## Lessons

- Interrogate which constraint is actually load-bearing before designing around it.
- Decompose a measurement before letting it pick an architecture.
- Spike the scariest assumption first; a half-day answer beats a three-week rewrite.
- An empty grep is not evidence of absence.
- Write the kill criterion down *before* you're emotionally invested in the thing.
