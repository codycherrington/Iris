# What a one-shot `claude -p` call actually costs

Measured 2026-08-09 against `claude` **v2.1.226**, on subscription auth (`apiKeySource: "none"`).
Captured evidence for the *stripped* case:
`AgentKit/Tests/AgentKitTests/Fixtures/oneshot_structured.ndjson`. The *unstripped* case was
measured live and **not** captured to a fixture — its numbers below come from the live run and
are repeated in `OneShotQueryTests.swift` and `CLAUDE.md`, but there is no NDJSON to re-read.
If you need to re-derive them, re-run the comparison rather than trusting the retelling.

## The premise this note corrects

`docs/plan.md` Phase 4 justified sidebar tools like this:

> Sidebar tools run as **separate short-lived `claude -p` calls with `--json-schema`** for
> structured results, so they never consume the main session's context.

That is **true about context and false about cost and latency**, and the two get conflated
easily. A one-shot call inherits nothing from the running session — which is the point — and
therefore has nothing cached, so it rebuilds the entire system prompt, tool definitions,
`CLAUDE.md`, skills and MCP config from scratch on every single press.

*Isolation is not the same as cheapness. The mechanism that gives you the first takes away the
second.*

## The two measurements

Same prompt both times — `Rate this prompt: 'make it better'`, six words asking about three —
same schema, same machine, minutes apart.

| | Default `claude -p` + `--json-schema` | Stripped launch |
|---|---|---|
| `duration_ms` | **32,517** | **6,567** |
| cache-creation tokens | **18,854** | **0** |
| `total_cost_usd` (client-side estimate) | **$0.237** | **$0.0043** |
| model actually used | **`opus-5`**, silently | `claude-haiku-4-5` |
| output tokens | 1,932 | 542 |

**≈55× cheaper, ≈5× faster, for identical work.** The default run spent 1,932 Opus output
tokens rating a three-word prompt, because a one-shot call with no `--model` inherits whatever
the CLI's default is, and nothing in the invocation says "this is a trivial classification job."

## The stripped launch, flag by flag

Encoded as the defaults of `OneShotConfiguration` in
`AgentKit/Sources/AgentKit/OneShotQuery.swift`. Each flag earned its place by measurably moving
the token count, not by looking sensible in `--help`:

```
--model haiku
--system-prompt <short, tool-specific>      # replaces, not appends
--exclude-dynamic-system-prompt-sections
--setting-sources ""                        # no CLAUDE.md, skills, plugins, user settings
--strict-mcp-config
--disable-slash-commands
--no-session-persistence
--tools ""
--json-schema <schema>
--output-format stream-json --verbose
```

Three notes on choices that are not obvious:

- **`--system-prompt`, never `--append-system-prompt`.** Appending keeps the full Claude Code
  system prompt, which is most of the cold start. Replacing it is where the biggest single
  saving lives. (`OneShotQueryTests.testArgumentsStripEverythingThatCostsTokens` asserts
  `--append-system-prompt` is *absent*, precisely so nobody "helpfully" switches them.)
- **`--setting-sources ""`** is also a correctness property, not only a cost one: a sidebar tool
  must behave identically regardless of which project happens to be open. Without it, the
  prompt improver's answers would drift with the current repo's `CLAUDE.md`.
- **`--output-format stream-json` rather than `json`.** The result line is identical either
  way. stream-json is used solely so `system/init` is visible and the
  `apiKeySource == "none"` assertion can run on sidebar calls too — the same hard rule as the
  main session, not a weaker one. `--verbose` is required alongside it.

`--no-session-persistence` is there for hygiene rather than tokens: these runs are ephemeral,
and leaving session files behind would fill the Phase 5 session library with sidebar noise.

## Subscription auth: the dollar figure is not the constraint

Verified 2026-08-09: a one-shot `claude -p` reports `apiKeySource: "none"`, the same as the
persistent session (fixture line 1). It rides the subscription; **nothing is billed**.

Which means `total_cost_usd` is a *client-side estimate at API rates* and is not a bill. The
scarce resource is **quota**, and `rate_limit_event` shows it is drawn from the same pool as
the conversation:

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1786267200,
 "rateLimitType":"five_hour","overageStatus":"rejected",
 "overageDisabledReason":"org_level_disabled","isUsingOverage":false}}
```

Two consequences that outlive this note:

1. **A chatty sidebar can rate-limit the main conversation.** That is the real reason the
   stripped launch matters — not saving fictional dollars, but not spending the five-hour
   window on a notes panel.
2. **The Phase 5 cost/quota meter must count sidebar usage or it lies.** This is why
   `OneShotUsage` is returned to the caller rather than logged and dropped, and why it exposes
   `didPayColdStart` (`cacheCreationTokens > 0`) as a first-class signal: a stripped one-shot
   should never create cache, so a non-zero value means a flag stopped working.

## Wall clock is not `duration_ms`

Measured live end-to-end through the Swift API: **~9.25 s wall clock against a self-reported
`duration_ms` of ~7.2 s**. The gap — roughly **2 s** — is process spawn, which the CLI's own
timing does not count because it starts the clock after it is already running.

The committed fixture's own numbers, for a comparable run:

| Field | Value |
|---|---|
| `duration_ms` | 7755 |
| `duration_api_ms` | 8738 |
| `ttft_ms` | 5207 |
| `ttft_stream_ms` | 1935 |
| `time_to_request_ms` | 15 |

Note `duration_api_ms` (8738) **exceeds** `duration_ms` (7755) on this run. Whatever the two
fields measure, they are not nested the way the names suggest — don't compute a "client
overhead" by subtracting them. Unexplained; recorded so the next person doesn't rediscover it
as a bug in their own arithmetic.

**Design consequence:** a sidebar click lands around **9 s**. That is not a spinner-free
interaction. Every sidebar tool needs a pending state from the first version — the same lesson
Phase 2's gate taught about the 11 s TTFT (`docs/runs/2026-08-08-phase2-perf-gate.md`), arriving
a second time by a different route.

## Comparison to the persistent session

Worth holding both numbers in view at once, because they pull in opposite directions:

| | Persistent session (`AgentBridge`) | One-shot (`OneShotQuery`) |
|---|---|---|
| Process startup | ~3.5 s, **once per session** | ~2 s, **every call** |
| Per-turn dispatch | 7–20 ms headless, 21–67 ms with the glass UI | n/a — there are no later turns |
| Cache creation | paid once at session start | 0 *only because* the launch is stripped |
| Context | accumulates | none, by design |

The persistent bridge exists because per-turn startup would break the perf gate.
`OneShotQuery` does the opposite deliberately. See
`docs/decisions/ADR-008-two-execution-modes-two-types.md`.
