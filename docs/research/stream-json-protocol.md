# The `stream-json` wire protocol (observed)

Reverse-engineered from real captured output, `claude` **v2.1.226**, 2026-08-07.
Raw captures: `AgentKit/Tests/AgentKitTests/Fixtures/*.ndjson`.

Several of these event types appear in **no public documentation**. This file is currently the
best reference we have. Update it whenever a new shape is observed — and cite the observed
payload, not a paraphrase.

## Invocation

```bash
claude -p \
  --input-format stream-json \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  --session-id <uuid>
```

`--include-partial-messages` requires `--verbose`. `--replay-user-messages` (echoes user
messages back for acknowledgment) requires both stream-json formats.

**Input** — one JSON object per line on stdin:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
```

The process stays alive across turns. Closing stdin ends the session; SIGTERM aborts the
in-flight turn, runs `SessionEnd` hooks, and exits 143.

## Per-turn event order

```
rate_limit_event          (once, at session start, BEFORE system/init)
system/init               ← repeats EVERY turn, not once per process
system/status
system/thinking_tokens    (0..n, only when thinking)
stream_event: message_start
stream_event: content_block_start
stream_event: content_block_delta   (xN — text_delta carries tokens)
assistant                 ← full buffered message, arrives BEFORE content_block_stop
stream_event: content_block_stop
stream_event: message_delta
stream_event: message_stop
result/success
```

With a tool call, `assistant` carries a `tool_use` block and a `user` event follows with the
matching `tool_result`, then the cycle repeats before the final `result`.

## Event reference

### `rate_limit_event` — undocumented

```json
{"type":"rate_limit_event",
 "rate_limit_info":{"status":"allowed","resetsAt":1786167000,
   "rateLimitType":"five_hour","overageStatus":"rejected",
   "overageDisabledReason":"org_level_disabled","isUsingOverage":false},
 "uuid":"…","session_id":"…"}
```

On a subscription this is more useful than cost tracking: a live quota gauge with a reset
countdown. `resetsAt` is Unix epoch seconds.

### `system/init`

Key fields: `apiKeySource`, `model`, `cwd`, `permissionMode`, `claude_code_version`,
`output_style`, `mcp_servers[{name,status}]`, `plugins[{name,path,source,version}]`,
`memory_paths.auto`, `fast_mode_state`.

**`apiKeySource: "none"` means subscription/OAuth auth** — no API key in use. Iris asserts on
this. Observed `mcp_servers` statuses include `connected` and `needs-auth`, so the UI can
prompt for re-auth.

### `system/thinking_tokens` — undocumented

```json
{"type":"system","subtype":"thinking_tokens",
 "estimated_tokens":150,"estimated_tokens_delta":100,"uuid":"…","session_id":"…"}
```

Streams while the model thinks. Enables a real progress indicator rather than a spinner.

### `system/permission_denied` — undocumented

```json
{"type":"system","subtype":"permission_denied",
 "tool_name":"Write","tool_use_id":"toolu_…","message":"Claude requested permissions to…"}
```

Does **not** block the stream — see `result.permission_denials` below and ADR-004.

### `stream_event`

Wraps standard Anthropic streaming events under `.event`. Token text is at
`.event.delta.text` when `.event.delta.type == "text_delta"`.

### `assistant` / `user`

`.message` holds a normal Messages-API message. `.parent_tool_use_id` is `null` on the main
thread and set to the spawning tool-use id inside a subagent — **at every nesting depth**, so
following it reconstructs the full subagent tree. `--forward-subagent-text` (or
`CLAUDE_CODE_FORWARD_SUBAGENT_TEXT`) is needed to receive subagent text/thinking; requires
≥ v2.1.211.

### `result`

Self-reported timings — no client instrumentation needed:

| Field | Meaning |
|---|---|
| `ttft_ms` | time to first token |
| `ttft_stream_ms` | time to first streamed chunk |
| `time_to_request_ms` | per-turn dispatch overhead (**7–20 ms** on a persistent process) |
| `duration_ms` / `duration_api_ms` | turn wall clock / API time |

Also: `total_cost_usd` (**cumulative for the session — diff consecutive results for per-turn
cost**), `modelUsage[model]` with `costUSD`, `contextWindow`, `maxOutputTokens` (enables a
context gauge), `usage.iterations[]`, `stop_reason`, `terminal_reason`, and:

```json
"permission_denials":[{"tool_name":"Write","tool_use_id":"toolu_…",
  "tool_input":{"file_path":"…","content":"hello\n"}}]
```

The **full intended tool input** — the basis for the diff-approval UI (ADR-004).

## Measured performance (2026-08-07, v2.1.226)

| Turn | `ttft_ms` | `ttft_stream_ms` | `time_to_request_ms` |
|---|---|---|---|
| 1 | 1434 | 971 | 20 |
| 2 | 1334 | 761 | 15 |
| 3 | 2285 | 1548 | 7 |

Process startup ≈ 3.5 s, paid **once per session**. Naive wall-clock for turn 1 was 4.98 s;
turns 2–3 were 0.77 s and 1.55 s.

## Open questions

- Does `--permission-prompt-tool` give true mid-turn pause, and what does it require? (ADR-004)
- Exact shape of `system/api_retry` in practice — documented but not yet observed.
- Behaviour of `--replay-user-messages`; useful for optimistic-send UI acknowledgment.
- Whether `--fork-session` mid-conversation is usable for a "branch this conversation" feature.
