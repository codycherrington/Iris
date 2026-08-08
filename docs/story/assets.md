# Capture-worthy assets

Mark captured items. Add new ones as they come up. **Flag ones that expire** — a "first ever"
moment is gone once it happens uncaptured.

## Captured
- [x] Phase 0 raw NDJSON — `AgentKit/Tests/AgentKitTests/Fixtures/*.ndjson` (2026-08-07)
- [x] Timing table (ttft_ms / time_to_request_ms) — `docs/research/stream-json-protocol.md`
- [x] `apiKeySource: "none"` — the subscription-auth proof
- [x] `permission_denials[].tool_input` payload — basis of the diff UI

## Expiring — capture on first occurrence, gone otherwise
- [ ] **First streamed token rendering in the SwiftUI UI** (Phase 2)
- [ ] **First Liquid Glass frame** — first time it looks like the pitch (Phase 3)
- [ ] **First glass morph** — sidebar merging into composer (Phase 3)
- [ ] **First subagent tree animating on a real fan-out** (Phase 5)
- [ ] **First diff-approval accepted** — deny → review → approve → write lands (Phase 5)
- [ ] First side-by-side of Iris vs terminal on the same task (Phase 2 gate)

## Screen recordings wanted
- [ ] Spike harness running, NDJSON scrolling past
- [ ] Terminal vs Iris, same prompt, split screen, timer visible
- [ ] Glass morph in slow motion, light and dark
- [ ] Quota gauge ticking down with reset countdown
- [ ] Thinking indicator driven by real `thinking_tokens` deltas
- [ ] Subagent tree building live during a parallel fan-out

## Stills / diagrams
- [ ] Architecture diagram (SwiftUI ↔ actor ↔ claude subprocess)
- [ ] The three-assumptions-that-flipped graphic
- [ ] Annotated `result` JSON showing the self-reported timing fields
- [ ] Before/after: terminal y/n approval vs Iris diff sheet

## Notes
- Record at the native retina resolution; glass artifacts badly at low bitrate. Prefer
  ProRes for the morph shots.
- Capture the *ugly* Phase 2 UI too — the before/after against Phase 3 is the payoff.
