# ADR-004 — Deny-then-retry for the permission/diff approval UI

**Date:** 2026-08-07
**Status:** Accepted (revisit if `--permission-prompt-tool` proves viable)

## Context

One of Iris's main reasons to exist is replacing terminal y/n approvals with a real diff view:
see exactly what a write will do, approve or reject per hunk.

The plan flagged this as the least-verified piece, assuming it would require
`--permission-prompt-tool` backed by a locally-hosted MCP server that Iris would have to run
and route through a SwiftUI sheet. The feared failure mode: the CLI blocks mid-turn waiting
for an approval that never arrives, deadlocking the UI.

The Phase 0 spike tested a `Write` under `permissionMode: default`. It does not block. It:

1. emits `system/permission_denied` with `{tool_name, tool_use_id, message}`
2. returns a `tool_result` with `is_error: true`
3. **completes the turn normally** (`subtype: success`, `stop_reason: end_turn`)
4. and reports, in the result:

```json
"permission_denials": [{
  "tool_name": "Write",
  "tool_use_id": "toolu_01Me9CB9xbzFRrVW5TbBxt9i",
  "tool_input": {"file_path": ".../out_default.txt", "content": "hello\n"}
}]
```

The full intended content is returned — everything needed to render a diff.

## Decision

Run in `permissionMode: default`. On `system/permission_denied`, read the corresponding entry
from `result.permission_denials[]`, render a diff sheet from `tool_input`, and on approval
re-issue the request with the tool allowlisted (or persist a rule to `.claude/settings.json`).

Provide `--permission-mode acceptEdits` as an explicit "trust this session" fast path.

## Alternatives considered

- **`--permission-prompt-tool` + local MCP server.** Would give true mid-turn pause — the
  agent waits rather than being denied and retrying. Rejected *for now*: unverified, needs
  Iris to host an MCP server, and carries the deadlock risk. Worth a later spike; this ADR
  should be revisited if it works.
- **`acceptEdits` everywhere.** Simplest, but discards the diff review that motivates the
  feature.
- **`dontAsk` with a curated allowlist.** Safe and fast, but static — no interactive approval
  at all.

## Consequences

- **No MCP server required**, and no deadlock risk: the turn always completes.
- Costs one extra round trip per approved tool call — the agent is denied, we approve, it
  retries. Acceptable; the alternative risks hanging the UI.
- UX is *deny → review → approve → retry* rather than *pause → approve → continue*. The
  transcript will show a denial before the eventual success, which the UI should present as a
  single pending-approval state rather than an error.
- Unblocks Phase 5's most valuable feature far earlier than planned.
