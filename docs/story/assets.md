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

## Notes
- Record at the native retina resolution; glass artifacts badly at low bitrate. Prefer
  ProRes for the morph shots.
- Capture the *ugly* Phase 2 UI too — the before/after against Phase 3 is the payoff.
- **Standing constraint (2026-08-08):** the assistant does not screenshot or screen-record
  Iris — it rebuilds via `make` and Cody captures. Every item on this list is a request to
  Cody, not something a session can quietly self-serve.
- **Pattern noticed 2026-08-08:** the most valuable moments are the *broken* states, and they
  have the shortest lives — the empty-screen stall and the glass-fusion tail were both fixed
  within minutes of being seen. Both are now recoverable only by reverting known commits. When
  something looks wrong in a way that's interesting, record it *before* fixing it.
