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

## The gate that passed, and the bug it caught anyway

*(2026-08-08. This is the second-strongest section in the piece after the spike, and it's the
one that argues for the whole methodology.)*

Phase 2's exit condition was "use it for a real task and compare against the terminal." The
morning's audit found the gate had been quietly skipped while more visually exciting Phase 3
work landed on top of it — worth admitting on the page, because "we skipped our own
non-negotiable gate" is the setup for what follows.

The gate ran and passed comfortably. The entire Liquid Glass UI — glass containers, animated
aurora backdrop, per-message morph IDs — cost **43 ms** of dispatch overhead against 7–20 ms
headless and a 100 ms threshold.

And the first reaction to using it was *"it felt like a stall for a minute."*

Both true. `SessionModel.send()` set `isBusy` and then appended nothing to the transcript until
the first content event, so an 11.5-second time-to-first-token showed an **empty screen**. Not
slow — silent.

> A pure benchmark would have printed 43 ms, gone green, and shipped a UI that reads as hung.

That's the thesis of the section: *fast* and *feels fast* are two different measurements, and
only one of them was in the plan. The fix was one line and a long comment. The lesson is that
a perf gate needs a human half, or it certifies the wrong thing. Pair with the Phase 0 material
above — that one was about decomposing a number before trusting it; this one is about a number
that was correct and still misleading.

## Reverse-engineering an undocumented protocol

`rate_limit_event`, `system/thinking_tokens`, `system/permission_denied` — none in public
docs, all useful. On a subscription, a quota gauge beats a cost meter; live thinking-token
deltas beat a spinner. Ties to the testing strategy: captured fixtures as both regression
suite and protocol documentation.

**The best finding is a negative one.** Chasing "show the user *something* during those 11
seconds" led into this: the CLI emits thinking events, reports a token estimate, and hands over
a 1164-character cryptographic signature over the reasoning — but the reasoning text itself is
always `""`. Verified twice, from a live capture and from day-old fixtures. Show the payload:

```json
{"type":"thinking_delta","thinking":"","estimated_tokens":50}
{"type":"thinking","thinking":"","signature":"CAIS4QYKhwEIEBgCKkDLVoHw5BVSyLw+24z/…"}
```

The signature sitting next to the empty string is what makes it obviously deliberate rather
than a decoding bug. **A planned feature — a collapsible "view reasoning" panel — was deleted
because the protocol proved it impossible.** Good material: most build stories add features on
discovery, this one removed one, and the app got simpler and better for it.

## Designing against what the data will actually support

The thinking UI took three passes, and the sequence is the point:

1. Seed a placeholder bubble so the screen isn't empty. Fixes the dead air, says nothing.
2. Three stacked collapsible bubbles — thinking / actions / output. Looked right on paper.
3. Delete the thinking bubble entirely. It was a container for text that will never arrive.
   Reasoning became one line in the assistant's header: `● Iris  thinking  50 tokens`,
   past-tensed to *thought* once the answer starts.

Iteration 2 also produced the Liquid Glass correction worth its own beat: `GlassEffectContainer`
fuses **every** sibling pair within its `spacing`, which is not a gap value. At 26 the tool chip
welded itself to the answer bubble with a visible glass tail. And `glassEffectUnion` on tool
chips — pitched in the design as the payoff of the whole glass vocabulary — made a run of three
actions unreadable as three actions. **Fuse things that are genuinely one control; never fuse
things the user has to count.** A partial reversal of my own design doc, which is the honest
kind of lesson.

## Liquid Glass

What `glassEffectID` + `glassEffectUnion` inside a `GlassEffectContainer` actually buy —
morphing, not just blur. Include the API-hunting anecdote (wrong framework, wrong arch, two
empty greps that nearly produced a wrong conclusion) as a lesson about negative evidence.

## The persona that edits itself

*(2026-08-08, Phase 4. The single most shareable moment in the project so far — lead with it if
the piece needs a second hook.)*

The persona wizard had one requirement from the plan: the persona must be **actual config, not
a stored string the app ignores**. The obvious implementation is `UserDefaults` — one line,
platform-standard, and completely opaque. Instead it writes pretty-printed JSON to
`~/Library/Application Support/Iris/persona.json`, on the theory that a file you can open,
read and diff is config, while a hashed binary plist is a setting.

Then the consequence nobody designed:

> Because the persona is a real file at a real path, it's within reach of the agent's own file
> tools. I asked Iris to change its own persona, mid-conversation, and it did.

The app doesn't own the persona and hand it to the agent. It's a shared document with two
authors, one of whom is the subject. "Make yourself less formal" becomes something you can just
say.

It also broke something immediately, which is the part that makes it a real engineering story
rather than a party trick: the store cached the file at launch, so the next wizard save would
silently clobber whatever the agent had written. **Any cached read of a file the agent can
write is a lost-update bug.** And a running session still can't pick up the change — the system
prompt is a process launch argument, so applying a persona restarts the session, and the button
says so instead of pretending.

Recorded as ADR-007. The plan's other Phase 4 instruction — write a real `CLAUDE.md` into the
target project — was deliberately *not* implemented: a first-run wizard silently overwriting a
file someone cares about is how you lose trust permanently. Deviating from your own plan, in
writing, with the reason, is a good note to land on.

## Results

Phase 2's gate: **PASS** — 43 ms dispatch with the full glass UI attached, against 7–20 ms
headless and a 100 ms threshold, with the terminal running the same prompt for comparison.
Full numbers in `docs/runs/2026-08-08-phase2-perf-gate.md`. Phases 1–3 closed 2026-08-08.

TODO — still open: whether Iris became the daily driver. **Be honest if it didn't.** Also
worth re-running the head-to-head once Phase 4's sidebar tools land, since those spawn extra
short-lived processes and are the likeliest thing to regress dispatch.

## Lessons

- Interrogate which constraint is actually load-bearing before designing around it.
- Decompose a measurement before letting it pick an architecture.
- **A number can be correct and still certify the wrong thing.** 43 ms of dispatch and "it felt
  like it stalled" were both true. Build the perceptual half of the gate.
- **Design against the data you actually get, not the data you assumed.** A feature was deleted
  because the protocol proved it impossible — and the app got better.
- **Fuse things that are one control; never fuse things the user has to count.**
- **Make config a file, and it acquires a second author.** Powerful, and a lost-update bug.
- Spike the scariest assumption first; a half-day answer beats a three-week rewrite.
- An empty grep is not evidence of absence.
- Write the kill criterion down *before* you're emotionally invested in the thing.
