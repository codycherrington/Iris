# ADR-002 — Drive the `claude` CLI as a subprocess, not the Agent SDK

**Date:** 2026-08-07
**Status:** Accepted

## Context

Cody's hard constraint: *"This can only use my subscription I'd rather not use an API that
costs money."*

The Claude Agent SDK ships for TypeScript and Python only — there is no Swift binding. Its
documentation states: *"Unless previously approved, Anthropic does not allow third party
developers to offer claude.ai login or rate limits for their products, including agents built
on the Claude Agent SDK. Use the API key authentication methods."*

The documented path for other languages is to run the CLI as a subprocess with `-p` and
`--output-format json`. The headless documentation notes, of `--bare` mode: *"bare mode doesn't
use your subscription login"* and *"In bare mode, Claude Code never reads OAuth credentials or
the system keychain."* By implication, non-bare `claude -p` **does** read them.

## Decision

Drive `claude` as a **persistent subprocess** in non-bare mode, speaking NDJSON both
directions:

```
claude -p --input-format stream-json --output-format stream-json \
          --verbose --include-partial-messages --session-id <uuid>
```

Iris asserts `system/init.apiKeySource == "none"` at runtime and surfaces a failure rather
than continuing, so it can never silently begin per-token billing.

## Alternatives considered

- **TypeScript Agent SDK (in Electron, or via a Node sidecar).** Typed message objects,
  `canUseTool` approval callbacks, hooks, subagents. Rejected on the auth constraint alone.
- **Raw Messages API in Swift.** Full control, but discards the entire agent harness — tools,
  sessions, skills, MCP, permissions — and still requires an API key.
- **Spawn one process per turn with `--resume`.** Simpler lifecycle. Rejected on measurement:
  process startup is ~3.5 s, which would be paid on *every* turn and would violate the
  "not slower than the terminal" constraint. `--input-format stream-json` is documented as
  *"realtime streaming input"*, making one long-lived process viable — measured per-turn
  dispatch overhead is 7–20 ms.

## Consequences

- **Runs on the subscription.** Verified: `apiKeySource: "none"`.
- **No Node runtime, no sidecar, no bundled JS.** The `claude` binary is already installed and
  self-contained.
- **Full context comes free.** Non-bare loads hooks, skills, plugins, MCP servers, memory and
  `CLAUDE.md` — Cody's existing skills work inside Iris on day one.
- We work against the CLI's wire protocol rather than a typed SDK. Much of that protocol is
  undocumented, so the decoder must be permissive and fixture-tested (ADR-003).
- Iris depends on a `claude` binary it does not vendor; version drift is a real risk, mitigated
  by the fixture tests.
- Anthropic's branding terms apply: Iris must not present as Claude Code (ADR-005).
