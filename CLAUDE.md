# Iris — project conventions

Native macOS agent workbench: SwiftUI + Liquid Glass over the `claude` CLI driven as a
persistent subprocess. The authoritative design is `docs/plan.md` — architecture, phase
breakdown, acceptance gates, and the recorded Phase 0 measurements. Read the relevant phase
before implementing anything.

## Hard rules

- **Subscription auth only.** Iris must never require or accept `ANTHROPIC_API_KEY`. Every
  session asserts `system/init.apiKeySource == "none"`. If that assertion ever fails, surface
  it to the user — do not silently continue, because continuing means per-token billing.
- **Always build via `make`.** This repo is in iCloud Drive; the Makefile redirects SwiftPM's
  scratch path to `~/Library/Developer/Iris/agentkit-build`. A bare `swift build` inside
  `AgentKit/` recreates a heavy `.build/` in the synced tree. No symlinks for build dirs —
  iCloud mangles them. A side effect of the redirect: **SourceKit's in-editor diagnostics go
  stale** against newly-added files and changed module interfaces — phantom "Cannot find type
  X in scope" errors persist while `make build` is clean. `make build` is the source of truth;
  don't "fix" working code to satisfy the squiggles.
- **The stream-json schema is reverse-engineered, not documented.** Several event types
  (`rate_limit_event`, `system/thinking_tokens`, `system/permission_denied`, `system/status`)
  appear nowhere in public docs. Decode permissively: unknown types go to
  `.unrecognized(type:raw:)` and get logged, never thrown. Adding a case is cheap; a crash in
  front of the user is not.
- **Never regress the perf gate.** Phase 0 measured 7–20 ms per-turn dispatch overhead on a
  persistent process. If a change makes Iris feel slower than the terminal, it doesn't ship.
- **Sidebar tools launch stripped, on Haiku.** A one-shot `claude -p` inherits nothing from
  the session, so an unstripped call rebuilds the whole prompt cache: measured **18,854
  cache-creation tokens / 32.5 s / opus-5** versus **0 tokens / 6.6 s / haiku** for the same
  prompt. `OneShotConfiguration`'s defaults encode that; don't loosen them casually. The
  dollar figure in `total_cost_usd` is a client-side estimate — on subscription auth the real
  cost is **quota**, drawn from the same pool as the conversation, so a chatty sidebar can
  rate-limit the main session.
- Phases are sequential: don't start Phase N+1 while Phase N's gate is unmet.
- **Branding:** Iris is not "Claude Code" and must not imitate its visual identity. "Powered
  by Claude" is permitted. Keep Iris's own name and look everywhere user-visible.

## Protocol gotchas (learned the hard way in Phase 0)

- `system/init` repeats **per turn**, not once per process. Don't treat it as a new session.
- The buffered `assistant` message arrives **before** `content_block_stop`. Reconcile the
  streamed deltas against `assistant`, not against block close.
- `result.total_cost_usd` is **cumulative for the session**, not per turn. Diff consecutive
  results for a per-turn figure.
- A denied tool **does not block the stream** — the turn completes, and
  `result.permission_denials[].tool_input` carries the full intended content. That is what
  the diff-approval UI is built on.
- `parent_tool_use_id` is `null` on the main thread and set inside subagents at every nesting
  depth; following it reconstructs the whole tree.
- `--json-schema` puts the payload in its own `result.structured_output` field (already
  parsed) *and* mirrors it into `result` as a string. Decode the former — `result` is the
  assistant's text channel and the mirroring is incidental. It costs an extra turn
  (`num_turns: 2`, `stop_reason: "tool_use"`): the schema is a forced tool call underneath.

## AppKit / Foundation gotchas

- **`Process.terminationStatus` raises an ObjC exception if the process is still running**,
  and Swift cannot catch it — the app aborts with `Abort trap: 6`. Always guard on
  `isRunning` first (see `exitedStatus` in `OneShotQuery.swift`). This crashed every
  one-shot timeout until it was caught by actually firing a deadline, which is the argument
  for exercising failure paths against a real process rather than only fixtures.

## Testing

`make test` from the repo root. AgentKit tests replay real captured CLI output from
`AgentKit/Tests/AgentKitTests/Fixtures/`. If they fail after a `claude` upgrade, the protocol
drifted — investigate before "fixing" the test. Recapture instructions are in QUICKSTART.md.

## Versioning

**Bump `VERSION` in the Makefile on every push**, by branch: `dev` **+0.0.1**, `test`
**+0.1.0**, `main` **+1.0.0**. A bump resets everything below it — a `test` push from 0.0.23
is `0.1.0`, not `0.1.23`. Patch does **not** carry: 0.0.9 → 0.0.10, because rolling into
0.1.0 would collide with what a `test` push means. `BUILD` tracks the cumulative patch count
so it never goes backwards when a minor or major reset zeroes the patch.

This **overrides the `git-workflow` skill**, which bumps only on the `dev`→`test` promotion
and forbids it on routine `dev` commits. Cody's rule wins here; the skill is unchanged for
other repos.

The version lives only in the Makefile (`VERSION` / `BUILD`, substituted into the generated
Info.plist) — there is no `package.json`, so `npm version` doesn't apply. Tag `test` and
`main` promotions.

## Documentation is a deliverable

This project is being documented end-to-end for a portfolio writeup / YouTube video.
**After every push, invoke the `documentarian` agent** (defined in
`.claude/agents/documentarian.md`) to write the devlog entry, capture any ADRs, and update
the story drafts. Not just at phase boundaries — every push, while the reasoning behind the
commits is still recoverable. Don't skip this — the docs are half the point.

Ledger board: "Iris". Remind Cody at session end which cards are done (he moves them
manually). Use the **ledger-tasks** skill rather than editing Ledger's CSVs by hand.

## Related skills

`git-workflow` for branches/commits/merges · `dev-scaffolder` for placement ·
`ledger-tasks` for the board · `claude-api` before touching anything Claude/LLM-shaped.
