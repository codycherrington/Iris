# 2026-08-08 — Dark theme, the perf gate, thinking with no text, and a persona that edits itself

*One entry for the whole of 2026-08-08. It started as a documentation-and-audit morning and
ended with Phase 2's gate closed, a protocol discovery that deleted a planned feature, and
Iris rewriting its own identity file. Read top to bottom; the sections are in the order things
happened. (Renamed from `2026-08-08-dark-theme-and-phase-audit.md` once the day outgrew that
slug.)*

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

*(Later that day: they landed in `7ceb518`, the docs in `56393b7`, and the whole
`20260807-Agent-Bridge` branch merged to `dev` via PR #1 as `6f363ad`, then `f652bd3` bumped
the version to v0.0.1. Everything from here on is on `dev`.)*

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

---

# Evening: the gate, the thinking discovery, and Phase 4's first feature

Two commits, `61a5b01` and `6c5a663`, twenty minutes apart at the end of the day. Between them
they close the gate the morning audit flagged as skipped, and open Phase 4.

## The perf gate: passed, and it caught something a benchmark wouldn't have

The full write-up is `docs/runs/2026-08-08-phase2-perf-gate.md` — first entry in a `docs/runs/`
directory that had been an untouched template since inception. Headlines only here.

| | value |
|---|---|
| Terminal baseline, wall clock | 20.44 s (`duration_api_ms` 18858, 3 turns, $0.1509) |
| Iris, same prompt, `ttft` | 11470 ms |
| Iris, `dispatch` (`time_to_request_ms`) | **43 ms** — plus 21 ms and 67 ms on two other turns |
| Phase 0 headless baseline | 7–20 ms |
| App's own "concerning" threshold | 100 ms |

So: attaching the entire Liquid Glass UI — glass containers, an animated aurora backdrop,
per-message morph IDs — cost **tens of milliseconds, not hundreds**. Constraint #3 holds with
room to spare. Wall clock isn't comparable between the two runs (the model took different tool
paths) and the run report says so explicitly rather than quoting the flattering number.

**And then the part that matters.** Cody's first reaction to a live turn was that it *"felt
like a stall for a minute."* At 43 ms dispatch. Both things were true at once: the app was
fast, and it felt broken.

The cause was three lines of nothing. `SessionModel.send()` set `isBusy = true` and appended
**nothing** to the transcript until the first content event arrived. With an 11.5 s TTFT, that
is eleven and a half seconds of an empty screen with a spinner-free status bar. No stall — no
feedback.

This is the whole argument for having a gate that involves a human using the thing, rather
than a benchmark. A pure timing harness would have printed 43 ms, gone green, and shipped a UI
that reads as hung. **"Fast" and "feels fast" are different measurements and only one of them
was in the plan.** Worth carrying into every later phase: the gate needs a perceptual half.

The immediate fix is a one-liner with a long comment:

```swift
// Nothing else appends a message until the first token/tool-call/buffered assistant
// event arrives, which can be many seconds out — without this placeholder the
// transcript shows nothing at all for that whole stretch and reads as a stall, even
// though dispatch overhead is ~40ms.
messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
```

A matching cleanup in the `result` handler removes the placeholder again if a turn ends having
produced nothing at all, so an empty bubble can't linger.

`README.md`'s status table went from `1 🟡 / 2 ⬜ / 3 ⬜` to **✅ / ✅ / ✅**, with Phase 2
pointing at the run report. Phase 3 is marked done on the strength of work that had already
landed — the audit's point was never that Phase 3 wasn't built, it was that it was built on an
ungated Phase 2. That ordering error is now retired rather than hidden.

## The discovery: the CLI emits thinking, but never emits reasoning

Chasing "show the user something during those 11 seconds" led straight into the most valuable
protocol finding of the project so far, and it's a **negative** one.

The CLI tells you reasoning happened. It tells you roughly how many tokens of it there were.
It even hands you a 1164-character cryptographic signature over it. It never gives you the
text. Every `thinking` string on the wire is `""`.

Verified two independent ways before believing it: a fresh live capture with a deliberately
thinking-inducing prompt, and the Phase 0 fixtures captured the day before. Both agree.
`AgentKit/Tests/AgentKitTests/Fixtures/skills.ndjson` has the whole sequence:

```json
{"type":"content_block_start","index":0,
 "content_block":{"type":"thinking","thinking":"","signature":""}}
{"type":"content_block_delta","index":0,
 "delta":{"type":"thinking_delta","thinking":"","estimated_tokens":50}}
{"type":"content_block_delta","index":0,
 "delta":{"type":"thinking_delta","thinking":"","estimated_tokens":null}}
{"type":"content_block_delta","index":0,
 "delta":{"type":"signature_delta","signature":"CAIS4QYKhwEIEBgCKkDLVoHw5BVSyLw+24z/…"}}
```

and the buffered `assistant` message's thinking block is `{"type":"thinking","thinking":"",
"signature":"CAIS4QYK…"}` — signature present, text empty. The populated signature next to the
empty string is what settles it: this is deliberate redaction, not a decoder bug, not a
capture artifact, and not an absence of reasoning. The turn's real count shows up later in
`message_delta.usage.output_tokens_details.thinking_tokens: 228`, against a running estimate
that had reached 219.

**`estimated_tokens` is the only signal that reasoning happened.** Full payload table and the
consumer rules are in `docs/research/stream-json-protocol.md`.

Two consequences that cost real design work:

1. **There is no "view reasoning" affordance possible.** Not deferred — impossible. Any
   expander opens an empty box. This is why the UI below ended up where it did.
2. **`system/thinking_tokens` and `thinking_delta` are independent signals and either can
   arrive first.** Listening to only one gives an indicator that fires on some turns and not
   others. `SessionModel` now handles both and lets them converge on the same counter — the
   comment in the code says exactly this, because it is not discoverable from the outside.

## Three iterations to a thinking indicator, told in order

None of the intermediate states survive in git — they were replaced within the same working
session — so this is the only record of them.

**Iteration 1 — the placeholder.** Seed an empty assistant message on send so the existing "…"
bubble appears instantly. Fixes the dead screen. Says nothing about what's happening.

**Iteration 2 — three bubbles.** Thinking / actions / output, stacked, each collapsible. This
is where `Tok.Fusion.transcript = 26` bit. `GlassEffectContainer`'s `spacing` fuses *every*
sibling pair within that distance, so with three adjacent glass shapes the tool chip welded
itself to the output bubble with a visible glass tail strung between them. Set to `0`, and
separately dropped the `tools-pending` `glassEffectUnion` from `ToolChip` so a run of actions
reads as distinct steps rather than one blob.

That is a **partial reversal of a Phase 3 design idea**, and worth naming as such. The plan
treated `glassEffectUnion` as the payoff of the whole glass vocabulary — "tool cards coalescing
into a result." In practice fusion is the wrong default for anything the user needs to *count*
or *read as separate*. It's a punctuation mark, not a layout mode. The old comment said "this
is the `glassEffectUnion` payoff"; the new one says adjacent chips fusing "made a run of tool
calls unreadable as distinct steps." Both are true — it looks great and it destroyed the
information. Fusion survives where it belongs: the composer field and its send button still
share `composerCluster` and still read as one piece of liquid, because they *are* one control.

**Iteration 3 — no thinking bubble at all.** Given the protocol finding, a collapsible thinking
bubble was a container for nothing. It was deleted outright, along with the `ThinkingChip`
struct and the `GlassID.thinking` union id, and replaced with a line in the assistant bubble's
own header:

```
● Iris   thinking   ⟨breathing⟩   50 tokens
```

past-tensed to `thought` the moment the answer starts — the reasoning is over, but how much of
it there was stays on the record — with the count climbing live. Tool chips moved *above* the
answer at the same time, since they're the lead-up to it and not a trailing footnote. The
status bar's separate `thinking` metric came out as redundant: the number now lives next to
the name of the thing that did the thinking, not in the chrome.

**The bug found on the way there.** Thinking only attached to *unconfirmed* messages. On a
single-step turn that's fine. On a multi-step turn — reason → tool call → reason again — the
first reply confirms the message, and every later round of reasoning has nowhere to render and
reaches only the status bar. Which is also why removing the status-bar metric was blocked until
this was fixed. `appendThinking` now starts a fresh message when there's no unconfirmed one to
attach to.

**And the pulse got cut.** `StreamingPulse` — a spectral capsule sweeping a gradient mask,
genuinely a nice piece of code — was judged "not pretty" in situ: beside the name it read as a
loading spinner bolted onto the glass, a second object competing for attention. Replaced by a
`Breathing` view modifier that just dims the label itself to 35% on a 1.2 s ease. The name and
its accent dot are wrapped in one `HStack` and the modifier applied to the group, because
animating them separately let them drift out of phase. `StreamingPulse` was deleted. Lesson,
such as it is: when the glass is already the visual interest, adding a second animated element
subtracts.

## Phase 4 opens: the persona wizard

`AgentKit/Sources/Iris/Persona.swift` and `PersonaWizard.swift`, both new. A three-step
first-run sheet — assistant name + personality, then user name + role, then standing context —
rendered into a system prompt and handed to every session via `--append-system-prompt`, which
`AgentConfiguration` already supported from Phase 1.

The last step of the wizard prints the generated prompt **verbatim on screen**. That's not a
debug affordance, it's the point. `docs/plan.md` is explicit that the persona must be *actual
config, not a stored string the app ignores*, and the only way to make that legible to the
person filling in the form is to show them the exact text that will be sent. If the rendered
prompt looks like nothing, the form was worth nothing.

The store writes pretty-printed, sorted-key JSON to
`~/Library/Application Support/Iris/persona.json` rather than `UserDefaults` — for the same
reason: a file you can open, read, diff and hand-edit is config; an opaque plist entry is a
setting. Application Support rather than the repo, because it's machine state and the repo is
in iCloud.

### The consequence nobody designed: the agent is the second author

Because the persona is a real file at a real path, it sits **within reach of the agent's own
file tools**. Cody had Iris edit its own persona mid-conversation, and it worked.

That immediately broke something. `PersonaStore` read the file once at launch and held it in
memory, so the next time the wizard saved, the stale launch-time copy would silently overwrite
whatever the agent had written. The fix is `reload()`, called from the status bar's persona
button before the sheet opens, with the reason spelled out in the code:

```swift
/// Necessary because `persona.json` has a second author: Iris itself can edit the file,
/// since it's real config sitting in reach of the agent's own file tools.
```

The remaining limitation is honest and unfixable at this layer: **a running session can't pick
up a persona change without a restart**, because the system prompt is a process launch
argument and there is no way to re-prompt a live process. `applyPersona` therefore stops and
restarts the bridge, and the status-bar button's tooltip says "Edit persona — restarts the
session" rather than pretending otherwise. First run skips starting a session at all until the
wizard is answered, so it doesn't have to tear one down immediately.

This is written up as `docs/decisions/ADR-007-persona-as-an-inspectable-file.md` — it's a real
architectural stance ("agent-legible config") with real costs, not just an implementation note.

### Deviation from the plan, recorded on purpose

`docs/plan.md` Phase 4 says the wizard "writes a real `CLAUDE.md` + `.claude/settings.json` in
the target project." **That was deliberately not implemented.** Iris opens in `$HOME` by
default, and its own repo has a carefully written `CLAUDE.md` — either target would mean
clobbering a real file the user cares about, silently, during a first-run wizard. Writing an
unrequested `CLAUDE.md` into whatever directory happens to be open is the kind of thing that
loses a user's trust permanently.

Proposed instead, not yet built: an **opt-in export** that writes a marked block —

```markdown
<!-- iris:persona -->
…generated persona…
<!-- /iris:persona -->
```

— so it's idempotent, re-runnable, and leaves everything outside the markers alone. Open item;
the plan's acceptance criterion for Phase 4 ("persona wizard output actually changes agent
behavior in a fresh session, verify by asking the agent who it is") is met by
`--append-system-prompt` regardless.

## The backdrop leans toward the cursor

Also in `6c5a663`, and the most purely aesthetic thing in it. The `AuroraBackdrop` blobs now
lean toward the pointer — bounded to **34 pt** maximum, on a long spring
(`response: 1.7, dampingFraction: 0.95`), with per-blob parallax factors `[1.0, 0.6, 0.35]` so
the front blob leans furthest and the back ones lag. The comment sets the taste boundary
better than any spec would: *"past roughly 40 it stops looking like light bending and starts
looking like a cursor-tracking gimmick."* It's a lean, not a chase.

Two non-obvious things fell out of it, both worth knowing before anyone tries this again:

- **`onContinuousHover` is useless here.** The backdrop sits underneath the entire UI, so hover
  is swallowed by whatever chrome is on top. It needs a local `NSEvent` monitor for
  `.mouseMoved`.
- **Which then does nothing**, because `window.acceptsMouseMovedEvents` is **off by default**
  in AppKit. `WindowChrome` in `IrisApp.swift` now sets it to `true`. Without that line the
  monitor sits silent forever and the feature looks like it just doesn't work.

And a genuine perf consideration, in a project with a perf gate: `mouseMoved` fires roughly
100×/s, and each event would redraw three 110 pt gaussian blurs. The handler is gated on a
movement threshold (0.01 in normalised units, ≈0.3 pt of actual lean) and lets the spring
interpolate across the gaps. Ambient decoration is exactly where a UI quietly starts costing
frames.

The same commit finally removed the dead `scheme == .dark ? 0.30 : 0.16` light-mode branch
that ADR-006 flagged as unreachable when the theme was fixed to dark, and dropped the now-stale
`@Environment(\.colorScheme)` read with it. Flagged in docs on 2026-08-08 morning, deleted the
same evening — about the best possible outcome for an ADR's "minor cleanup opportunity" note.

## Process change

`CLAUDE.md` now says to invoke the documentarian **after every push**, not just at phase
boundaries or session end — *"while the reasoning behind the commits is still recoverable."*
This entry is a direct argument for it: three UI iterations, an intermediate three-bubble
design, a deleted `ThinkingChip` and a deleted `StreamingPulse` all happened and vanished
inside a single working session. None of them are in git. The only reason they're recorded at
all is that the session that did them was still around to say so. That edit is uncommitted in
the working tree as of this entry.

## Repo state

- `make test` — **24/24 passing** (13 decoding, 11 line assembler), unchanged all day, and
  still passing after the `AgentEvent` additions for `thinkingDelta` /
  `thinkingEstimatedTokens`. `make build` clean.
- Branch `dev`, HEAD `6c5a663`.
- Uncommitted at the time of writing: `CLAUDE.md`, plus this documentation pass.

### A trap for whoever edits this repo next

SourceKit's in-editor diagnostics go **stale** against newly-added files and changed module
interfaces here — persistent phantom errors like `Cannot find type 'Persona' in scope` and
`value has no member 'thinkingDelta'` sitting in the editor while `make build` is completely
clean. It's a consequence of the Makefile redirecting SwiftPM's `--scratch-path` out of the
iCloud tree (ADR-005): the editor's index and the build's artifacts live in different places,
and the editor doesn't always notice.

**`make build` is the source of truth, not the squiggles.** Don't "fix" code that isn't broken
to satisfy a stale index. Noted in `CLAUDE.md` next to the build rule so it's found before an
hour is lost to it.
