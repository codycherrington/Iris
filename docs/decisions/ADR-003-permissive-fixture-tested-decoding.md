# ADR-003 — Permissive, fixture-tested decoding of an undocumented protocol

**Date:** 2026-08-07
**Status:** Accepted

## Context

ADR-002 puts Iris on the CLI's `stream-json` wire protocol. That protocol is only partly
documented. The Phase 0 spike captured three event types that appear nowhere in public docs:

- `rate_limit_event` — `{status, resetsAt, rateLimitType, overageStatus, isUsingOverage}`
- `system/thinking_tokens` — `{estimated_tokens, estimated_tokens_delta}`
- `system/permission_denied` — `{tool_name, tool_use_id, message}`

(plus `system/status`). It also surfaced shape details that would be easy to get wrong:
`system/init` repeats per turn rather than once per process; the buffered `assistant` message
arrives *before* `content_block_stop`; `total_cost_usd` is cumulative for the session rather
than per turn.

Iris does not control this protocol and cannot pin it — the user's `claude` binary updates
independently.

## Decision

1. **Decode permissively.** `AgentEventDecoder.decode(line:)` never throws. Unknown types,
   malformed JSON, and unexpected shapes all land in `.unrecognized(type:raw:)`, preserved
   verbatim for logging.
2. **Test against real captured output.** Five NDJSON fixtures from the spike live in
   `AgentKit/Tests/AgentKitTests/Fixtures/` and are replayed by the suite. They are the
   canary for protocol drift.
3. **Assert on the facts that matter**, not just on parsing: subscription auth
   (`apiKeySource == "none"`), per-turn overhead under 100 ms, cumulative cost ordering,
   and that a denied write still completes its turn.

## Alternatives considered

- **Strict `Codable` conformance throwing on unknown keys.** Type-safe and concise, but a
  single new event type in a `claude` release would crash the UI in front of the user. The
  failure mode is unacceptable for a daily driver.
- **Ignore unknown events silently.** Avoids crashes but hides drift until something subtler
  breaks. `.unrecognized` keeps the payload so it can be logged and diagnosed.
- **Pin a `claude` version.** Not enforceable — Iris invokes whatever binary is installed.

## Consequences

- A `claude` upgrade that changes the protocol degrades Iris's UI rather than crashing it.
- Fixture tests fail loudly on drift; QUICKSTART documents how to recapture. A failing fixture
  test means *investigate*, not *fix the test*.
- Decoding is hand-written against `JSONSerialization` rather than derived `Codable`, so
  adding a case is a small manual edit. Accepted as the cost of the failure mode we want.
- The captured fixtures double as protocol documentation — currently the best reference we
  have for several of these event types.
