# Capture-worthy assets

Mark captured items. Add new ones as they come up. **Flag ones that expire** — a "first ever"
moment is gone once it happens uncaptured.

## Captured
- [x] Phase 0 raw NDJSON — `AgentKit/Tests/AgentKitTests/Fixtures/*.ndjson` (2026-08-07)
- [x] Timing table (ttft_ms / time_to_request_ms) — `docs/research/stream-json-protocol.md`
- [x] `apiKeySource: "none"` — the subscription-auth proof
- [x] `permission_denials[].tool_input` payload — basis of the diff UI
- [x] **The redacted-thinking payload** (2026-08-08) — `thinking_delta` with `thinking: ""`
  beside a 1164-char `signature_delta`, in
  `AgentKit/Tests/AgentKitTests/Fixtures/skills.ndjson` and quoted in
  `docs/research/stream-json-protocol.md`. Renders as text on screen; nothing to re-shoot.
- [x] **Phase 2 gate numbers** — terminal vs Iris, `docs/runs/2026-08-08-phase2-perf-gate.md`.
  The *numbers* are captured. The **side-by-side footage is not** — see below.
- [x] **The one-shot cost comparison** (2026-08-09) — 32,517 ms / 18,854 cache tokens / opus-5
  against 6,567 ms / 0 / haiku, in `docs/research/one-shot-cost-model.md`. The stripped run has
  a committed fixture (`Fixtures/oneshot_structured.ndjson`); ⚠️ **the expensive run does not** —
  it was measured live and only the numbers survive. Fine for a table on screen, but there is no
  NDJSON to scroll past for the default case. If the video wants both raw captures side by side,
  the unstripped call has to be re-run and saved.
- [x] **`--json-schema` as a forced tool call** (2026-08-09) — the `StructuredOutput` `tool_use`
  block and its `"Structured output provided successfully"` `tool_result`, in
  `Fixtures/oneshot_structured.ndjson`. Pure text, nothing to re-shoot.
- [x] **"Fifteen out of ten"** (2026-08-09) — `"score":15` against a `{"type":"integer"}` field
  described in prose as 1–10, in `Fixtures/oneshot_structured.ndjson`. The *payload* is captured
  and permanent. The **UI rendering a green 15/10 is not captured**, and it expires the moment
  someone adds `minimum`/`maximum` to the schema — see the expiring list below.

## Expiring — capture on first occurrence, gone otherwise
- [ ] **First streamed token rendering in the SwiftUI UI** (Phase 2)
- [~] **First Liquid Glass frame** — first time it looks like the pitch (Phase 3). Likely
  already happened uncaptured: `GlassContentView` was already the app's boot target as of
  2026-08-07, before this asset list flagged it. Ask Cody if he has any screenshot from that
  first Phase 3 build, or accept that this one is gone and let the 2026-08-08 dark-theme
  reveal (below) stand in for "first time it looked like the pitch."
- [ ] **First glass morph** — sidebar merging into composer (Phase 3)
- [x] **Dark-theme reveal** — the near-black/neon-cyan/ice-white palette (ADR-006,
  2026-08-08) shown live for the first time: a message-bubble exchange with the cyan/teal
  `AuroraBackdrop` glow visible behind the bubbles. Cody has the screenshot (reaction:
  "BEAUTIFUL") but it has not been pulled into this repo/asset library yet — worth retrieving
  from that conversation before it's lost track of. This is a strong portfolio/video candidate:
  it's the moment the aesthetic direction actually clicked.
- [ ] **First subagent tree animating on a real fan-out** (Phase 5)
- [ ] **First diff-approval accepted** — deny → review → approve → write lands (Phase 5)
- [~] First side-by-side of Iris vs terminal on the same task (Phase 2 gate). **The gate ran
  and passed on 2026-08-08 — uncaptured on video.** The numbers survive in
  `docs/runs/2026-08-08-phase2-perf-gate.md`, so nothing is lost analytically, but the footage
  of the actual head-to-head is gone. **Re-stageable**: the same prompt against the same repo
  reproduces it, and the run report follow-up calls for a re-run after Phase 4's sidebar tools
  land anyway. Shoot it then — split screen, timer visible. Downgraded from "expiring" to
  "restage" for this reason.
- [x] **The empty-screen stall, before the fix** (2026-08-08) — ⚠️ **GONE, uncaptured.** 11.5
  seconds of blank transcript at 43 ms dispatch: the single best illustration of "fast but
  feels broken" and it was fixed within minutes of being noticed. Not reproducible in the
  shipped app. **Only recoverable by reverting `61a5b01`'s `SessionModel.send()` placeholder
  locally and re-recording** — worth doing deliberately before Phase 5, because the video beat
  needs to *show* the empty screen, not describe it. Flagging as the first genuinely lost
  moment of the project.
- [~] **The `Abort trap: 6` crash, live** (2026-08-09) — `*** -[NSConcreteTask
  terminationStatus]: task still running` followed by the abort, from firing a real deadline at
  a real child. Happened uncaptured, but **cheaply restageable**: delete the `isRunning` guard
  in `exitedStatus(_:)` (`OneShotQuery.swift`, added in `5d3947b`) and run
  `make harness ARGS="-s --timeout 1"`. The shot that makes it land is a **split screen** — the
  crash on one side, `make test` reporting **35/35 green** on the other, at the same moment.
  That single frame is the whole "green in a dimension it cannot observe" argument, and it does
  not exist as a still yet. Third entry in the pattern below, and the first one that was
  restaged-by-design rather than lost.
- [ ] **The two calls, side by side, unedited** (2026-08-09) — default `claude -p` and the
  stripped launch running on the same six-word prompt, timers visible. ~32 s versus ~6.6 s is
  long enough to *feel* on camera, which is the point: the table states it, the footage sells
  it. Fully reproducible, nothing expiring, but shoot the wall clock rather than trusting
  `duration_ms` — it under-reports by the ~2 s of process spawn.
- [x] ~~**A green `15/10` in the prompt improver**~~ (2026-08-09) — ❌ **expired, never captured,
  2026-08-10.** The warning was right about the mechanism and wrong about the deadline: it
  predicted the shot would disappear when the schema was *tightened*, and it disappeared when the
  **field was deleted**. The prompt improver now returns a rewrite and nothing else — the score
  and issue list were output tokens spent on a critique nobody acts on, so `PromptRewrite` has one
  property and the schema has one key. No score field, no `scoreTint`, no way to render 15/10
  again in any build.
  **The story survives without the screenshot.** `oneshot_structured.ndjson` is committed and
  contains `"score": 15` against a bare `{"type":"integer"}`, which is the actual evidence; the
  UI rendering was only ever the shareable framing of it. Use the fixture on screen instead — see
  the "Fifteen out of ten" entry above, which was captured and is permanent.
  **The lesson for this file:** "expiring" was tracked against the fix that was anticipated. What
  actually removed it was a product decision two days later that had nothing to do with the bug.
  An asset that depends on a feature existing expires when the *feature* goes, not when the bug
  does — worth flagging that way on anything still open.
- [ ] **The sidebar's nine seconds, unedited** (2026-08-09) — click **Check** on a real query and
  hold the entire wait: the `haiku · separate process` pending row with Cancel beside it, then the
  result plus its usage footnote. Fully reproducible, nothing expiring, but it must be shot as a
  single unbroken take — the discomfort is the content, exactly like the empty-screen beat. Shoot
  the wall clock in frame; `duration_ms` under-reports by the ~2 s of process spawn.
- [~] **The usage footnote going amber on a forced cold start** (2026-08-09) — **restageable by
  design**, and the strongest single frame for "put the guard where the user will see it". Loosen
  one strip flag in `OneShotConfiguration` locally, run a tool, and the footnote comes back with
  `cold start` in amber under a result that took ~30 s instead of ~9 s. Does not exist as a
  recording. Note this is the *first* asset in the project that was designed to be restageable
  before it was needed — the pattern at the bottom of this file finally applied prospectively.
- [ ] **Iris editing its own `persona.json`, live** (Phase 4, 2026-08-08). Happened, uncaptured
  — but **fully reproducible**, unlike the two above: ask the agent to change its own persona
  and it does it again. Not expiring. Shoot it properly rather than settling for a rerun done
  badly: split screen, agent's edit on one side, the file changing on the other, then restart
  and ask it who it is. Strongest standalone clip in the project so far.

## Screen recordings wanted
- [ ] Spike harness running, NDJSON scrolling past
- [ ] Terminal vs Iris, same prompt, split screen, timer visible
- [ ] Glass morph in slow motion, ~~light and~~ dark (light mode no longer exists — ADR-006)
- [ ] Quota gauge ticking down with reset countdown
- [ ] Thinking indicator driven by real `thinking_tokens` deltas — now concretely:
  `● Iris  thinking  N tokens` climbing live in the bubble header, then past-tensing to
  *thought* as the answer starts. Needs a prompt that reasons for a while; the gate prompt in
  `docs/runs/2026-08-08-phase2-perf-gate.md` works.
- [ ] **Cursor-following aurora** (2026-08-08) — the backdrop blobs leaning toward the pointer,
  34 pt max on a 1.7 s spring with `[1.0, 0.6, 0.35]` parallax. Slow deliberate mouse arcs,
  no clicking, empty transcript so nothing competes. Shoot at native retina / high bitrate;
  three 110 pt blurs are exactly what low-bitrate encoding destroys. Best ambient B-roll in
  the app and it can sit under the outro or titles.
- [ ] **Persona wizard, full three-step flow** (2026-08-08) — including the final step showing
  the generated system prompt verbatim. That screen is the visual proof of "the persona is
  actual config", so hold on it long enough to be readable.
- [ ] **The glass-fusion bug** — `Tok.Fusion.transcript = 26`, tool chip welded to the answer
  bubble with a visible tail, and three tool chips fused into one blob by
  `glassEffectUnion(id: "tools-pending")`. **Reproducible by reverting two values** (see
  `61a5b01`). Worth staging: it's the before/after that makes the fusion lesson land visually
  instead of verbally.
- [ ] **The sidebar rail sliding in on ⌘⌥S** (2026-08-09) — `.move(edge: .trailing)` combined with
  opacity, four glass cards stacked with fusion at 0 so they read as separate panels. Good short
  B-roll for the sidebar section and it doubles as a Liquid Glass shot. Shoot with the rail
  toggling a few times; the window's minimum width jumps 640 → 940 when it opens, which is
  visible if the window is near its floor.
- [ ] **The tool picker, with the amber "uses quota" chips** (2026-08-09) — hold long enough that
  the blurbs are readable. This is the screen that carries "sidebar calls draw from the same pool
  as your conversation" without any narration.
- [ ] Subagent tree building live during a parallel fan-out

## Stills / diagrams
- [ ] Architecture diagram (SwiftUI ↔ actor ↔ claude subprocess)
- [ ] The three-assumptions-that-flipped graphic
- [ ] Annotated `result` JSON showing the self-reported timing fields
- [ ] Before/after: terminal y/n approval vs Iris diff sheet
- [ ] **The redacted-thinking payload, annotated** — `"thinking": ""` next to the 1164-char
  signature, with the signature circled. One image carries the whole "the feature was deleted
  by the protocol" beat.
- [ ] **Dispatch-overhead bar chart** — Phase 0 headless 7–20 ms · Phase 2/3 full glass UI
  21–67 ms · threshold 100 ms. Three bars, one line. From
  `docs/runs/2026-08-08-phase2-perf-gate.md`.
- [ ] **The cold-start bar** (2026-08-09) — 18,854 cache-creation tokens against 0, one pair of
  bars, no axis needed. The whole sidebar-cost section reduces to this image. From
  `docs/research/one-shot-cost-model.md`.
- [ ] **"Isolation is not cheapness"** as a title card — the plan's original sentence on top,
  struck through or highlighted, the correction beneath. The single most quotable line the
  project has produced so far and it's a still, not a clip.
- [ ] **Self-reported vs lived latency**, two pairs on one chart (2026-08-09) — Phase 2's 43 ms
  dispatch against an 11 s empty screen, and the one-shot's 7.2 s `duration_ms` against 9.25 s
  wall clock. Makes "the honest number was the one the instrument wasn't reporting" a picture
  instead of a paragraph.

## Notes
- Record at the native retina resolution; glass artifacts badly at low bitrate. Prefer
  ProRes for the morph shots.
- Capture the *ugly* Phase 2 UI too — the before/after against Phase 3 is the payoff.
- **Standing constraint (2026-08-08):** the assistant does not screenshot or screen-record
  Iris — it rebuilds via `make` and Cody captures. Every item on this list is a request to
  Cody, not something a session can quietly self-serve.
- **Pattern noticed 2026-08-08, confirmed 2026-08-09:** the most valuable moments are the
  *broken* states, and they have the shortest lives — the empty-screen stall, the glass-fusion
  tail and the `Abort trap: 6` crash were each fixed within minutes of being seen. All three are
  now recoverable only by reverting a known commit. When something looks wrong in a way that's
  interesting, record it *before* fixing it.
- **Partial mitigation (2026-08-09):** for the crash, the exact revert *and* the exact command
  that re-triggers it were written down at fix time rather than reconstructed later. That is the
  cheapest possible insurance and it costs one line in the devlog. Do it every time — three
  losses in three days is a pattern, not bad luck.
- **Applied prospectively (2026-08-09, afternoon):** the cold-start footnote and the 15/10 render
  were both logged as capture targets *with their reproduction steps* on the day they shipped,
  before either was needed or fixed. The 15/10 one has a real expiry — tightening the schema is
  the correct next change and it destroys the shot. First time this list got ahead of the loss
  instead of recording it afterwards.

- **New capture targets (2026-08-09, evening):**
  - The **question card** in the transcript — this is the most demo-able single feature in the
    app. Ask something with a genuine either/or (the caching question in `QuestionProtocolTests`
    reproduces it) and screenshot the card, then the answer landing as a normal user turn.
  - The **app icon in the Dock and Spotlight**, now that `make install` puts a real bundle in
    `/Applications`. First time Iris looks like software rather than a build artifact.
  - **`/context` producing nothing**, if anyone wants the before-shot for the slash-command
    fix — revert `0a557f0`, type `/context`, and the turn completes with an empty transcript.
    Expires the moment that commit is in the build.
  - The **send button's two states side by side**, which is the payoff shot for the arrow story:
    the measurement table means the claim "both are centred" is checkable, not asserted.
