# The `stream-json` wire protocol (observed)

Reverse-engineered from real captured output, `claude` **v2.1.226**, 2026-08-07.
Re-verified against a fresh live capture 2026-08-08 (thinking section).
Extended 2026-08-09 with one-shot `-p` + `--json-schema` runs (bottom section).
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
rate_limit_event          (once, at session start — see ordering caveat below)
system/init               ← repeats EVERY turn, not once per process
system/status
system/thinking_tokens    (0..n, only when thinking — interleaves with the deltas below)
stream_event: message_start
stream_event: content_block_start
stream_event: content_block_delta   (xN — text_delta carries tokens;
                                     thinking_delta carries an estimate and NO text;
                                     signature_delta closes a thinking block)
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

**Ordering is not stable — do not depend on it.** In the persistent-session captures of
2026-08-07 this arrives *before* `system/init`. In the one-shot capture of 2026-08-09
(`oneshot_structured.ndjson`) it arrives *after*: `system/init` is line 1, `rate_limit_event`
is line 2. Same CLI version. Treat it as "arrives early in the run", nothing more precise, and
never as a signal that a session has begun.

Also worth knowing: one-shot `-p` calls emit it too, and it reports the **same** five-hour
window as the conversation. Sidebar tools and the main session draw on one pool — see
`one-shot-cost-model.md`.

### `system/init`

Key fields: `apiKeySource`, `model`, `cwd`, `permissionMode`, `claude_code_version`,
`output_style`, `mcp_servers[{name,status}]`, `plugins[{name,path,source,version}]`,
`memory_paths.auto`, `fast_mode_state`.

**`apiKeySource: "none"` means subscription/OAuth auth** — no API key in use. Iris asserts on
this. Observed `mcp_servers` statuses include `connected` and `needs-auth`, so the UI can
prompt for re-auth.

### Thinking: the text is never emitted (verified 2026-08-08)

**The single most consequential protocol finding so far, because it removes a feature rather
than adding one.** The CLI tells you that reasoning happened, how much of it there was, and
even hands you a cryptographic signature over it — but it never gives you the reasoning text.
Every `thinking` string on the wire is empty.

Verified two independent ways: a fresh live capture on 2026-08-08
(`claude -p … --output-format stream-json --verbose --include-partial-messages` with a prompt
chosen to force extended reasoning) and the Phase 0 fixtures captured 2026-08-07. Both agree.

`AgentKit/Tests/AgentKitTests/Fixtures/skills.ndjson` carries a complete thinking block. The
whole observed sequence, verbatim (`uuid`/`session_id` elided):

```json
{"type":"content_block_start","index":0,
 "content_block":{"type":"thinking","thinking":"","signature":""}}

{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50}

{"type":"content_block_delta","index":0,
 "delta":{"type":"thinking_delta","thinking":"","estimated_tokens":50}}

{"type":"system","subtype":"thinking_tokens","estimated_tokens":150,"estimated_tokens_delta":100}

{"type":"content_block_delta","index":0,
 "delta":{"type":"thinking_delta","thinking":"","estimated_tokens":100}}

{"type":"content_block_delta","index":0,
 "delta":{"type":"thinking_delta","thinking":"","estimated_tokens":null}}

{"type":"system","subtype":"thinking_tokens","estimated_tokens":219,"estimated_tokens_delta":69}

{"type":"content_block_delta","index":0,
 "delta":{"type":"signature_delta","signature":"CAIS4QYKhwEIEBgCKkDLVoHw5BVSyLw+24z/…"}}
```

Then the buffered `assistant` message, whose thinking block is *also* text-empty:

```json
{"type":"thinking","thinking":"","signature":"CAIS4QYKhwEIEBgCKkDL…"}   // signature len 1164
```

Then `content_block_stop`, and finally the turn's `message_delta`:

```json
"usage":{"output_tokens":363,"output_tokens_details":{"thinking_tokens":228}, …}
```

What that adds up to:

| Field | Observed |
|---|---|
| `content_block_start.content_block.thinking` | `""` |
| `content_block_start.content_block.signature` | `""` (filled in later, by `signature_delta`) |
| `thinking_delta.thinking` | `""` — always, on every delta, in every capture |
| `thinking_delta.estimated_tokens` | present as an *increment* (`50`, `100`), sometimes explicitly `null` |
| `signature_delta.signature` | a real 1164-char blob — so the reasoning exists, it is just withheld |
| buffered `assistant` thinking block `.thinking` | `""` |
| `message_delta.usage.output_tokens_details.thinking_tokens` | `228` — the authoritative final count |

**`estimated_tokens` is the only signal that reasoning happened.** The empty `thinking` field
is not a bug in our decoder, not a capture artifact, and not specific to a model or prompt —
the populated `signature_delta` alongside the empty text is what makes it clear this is
deliberate redaction rather than absence.

Keys observed on a `thinking_delta` are exactly `['type', 'thinking', 'estimated_tokens']`.

#### Consequences for any consumer

- **There is no expandable "view reasoning" affordance possible.** Any UI that offers to open
  a thinking block will open an empty box. Iris removed a planned three-bubble
  thinking/actions/output layout for exactly this reason and reports reasoning as a live
  token count beside the assistant's name instead. See
  `docs/devlog/2026-08-08-perf-gate-thinking-and-persona.md`.
- **Treat "thinking occurred, no text" as a first-class state.** Do not gate the indicator on
  `!thinking.isEmpty` — it will never fire. Gate it on the token estimate. `AgentKit`'s
  `ChatMessage.didThink` is `!thinking.isEmpty || (thinkingTokens ?? 0) > 0` for this reason,
  and the empty-text branch is the one that actually runs.
- **`system/thinking_tokens` and `thinking_delta` are independent signals, and either can
  arrive first.** In the fixture above the `content_block_start` leads, then the system event,
  then the matching delta — but ordering is not guaranteed, and a consumer that listens to
  only one of the two gets an indicator that fires inconsistently across turns. Handle both
  and let them converge on the same counter.
- **The two counters mean different things.** `system/thinking_tokens.estimated_tokens` is a
  running *total* (50 → 150 → 219) with `estimated_tokens_delta` as its increment;
  `thinking_delta.estimated_tokens` is an *increment* (50, 100) that tracks
  `estimated_tokens_delta`. Both are estimates — the turn's real figure lands later in
  `message_delta.usage.output_tokens_details.thinking_tokens` (219 estimated vs **228**
  actual here). Don't mix them in one accumulator.
- Turns with no reasoning still report the field: `output_tokens_details.thinking_tokens: 0`
  appears in `transcript.ndjson` and `perms.ndjson`.

Open question: whether `--forward-subagent-text` (documented as forwarding subagent
"text/thinking") changes any of this for nested agents. Not yet tested.

### `system/thinking_tokens` — undocumented

```json
{"type":"system","subtype":"thinking_tokens",
 "estimated_tokens":150,"estimated_tokens_delta":100,"uuid":"…","session_id":"…"}
```

Streams while the model thinks. Enables a real progress indicator rather than a spinner —
which, given the section above, is the *only* thinking UI available.

### `system/permission_denied` — undocumented

```json
{"type":"system","subtype":"permission_denied",
 "tool_name":"Write","tool_use_id":"toolu_…","message":"Claude requested permissions to…"}
```

Does **not** block the stream — see `result.permission_denials` below and ADR-004.

### `stream_event`

Wraps standard Anthropic streaming events under `.event`. Token text is at
`.event.delta.text` when `.event.delta.type == "text_delta"`. Observed `.event.delta.type`
values: `text_delta`, `thinking_delta`, `signature_delta`. See the thinking section above —
`thinking_delta.thinking` is always `""`.

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

## One-shot `-p` runs with `--json-schema` (observed 2026-08-09)

Capture: `AgentKit/Tests/AgentKitTests/Fixtures/oneshot_structured.ndjson` — 22 lines, a real
stripped sidebar-style call. This is the mode Phase 4's sidebar tools use; the cost side is in
`one-shot-cost-model.md`, the wire shapes are here.

### It is the same protocol, not a different one

The whole fixture decodes through the existing session decoder with **zero `.unrecognized`
events** (`OneShotQueryTests.testOneShotRunDecodesWithNoUnrecognizedEvents` pins this). A
one-shot run is a normal stream-json run that happens to end after one exchange. No new event
types, no new envelope. That's a useful invariant: if it ever breaks, the main transcript path
is about to break too.

Observed order in the fixture:

```
system/init                    ← line 1 (see rate_limit_event ordering caveat above)
rate_limit_event               ← line 2
system/thinking_tokens ×16     ← yes, on Haiku, on a six-word prompt
assistant                      ← thinking block
assistant                      ← tool_use block (the schema tool)
user                           ← tool_result: "Structured output provided successfully"
result/success
```

No `stream_event` lines: the probe runs without `--include-partial-messages`, since a sidebar
tool wants one answer, not tokens.

### `--json-schema` is a forced tool call underneath

This is the single most useful thing to know about the flag. The schema is injected as a tool
named **`StructuredOutput`**, and the model *calls* it:

```json
{"type":"tool_use","id":"toolu_01YBPNfM49dfUAgaMm2aJkcr","name":"StructuredOutput",
 "input":{"score":15,"issues":["Extremely vague and lacks context - 'it' is undefined", …],
          "rewrite":"Please review and improve the following …"},
 "caller":{"type":"direct"}}
```

followed by a synthetic `tool_result`:

```json
{"tool_use_id":"toolu_01YBPNfM49dfUAgaMm2aJkcr","type":"tool_result",
 "content":"Structured output provided successfully"}
```

Consequences that are easy to trip over:

- **`num_turns: 2`, not 1**, and **`stop_reason: "tool_use"`, not `end_turn`** — on a
  successful run. Anything asserting `stop_reason == "end_turn"` will report false failures.
- The tool shows up in `system/init.tools` **even with `--tools ""`**:
  `"tools":["StructuredOutput"]`. `--tools ""` removes the *built-in* tools; the schema tool is
  added back by `--json-schema`.
- `caller: {"type":"direct"}` is present on the `tool_use` block. Not seen elsewhere yet.

### The payload lands in two places; only one of them means it

```json
"structured_output":{"score":15,"issues":[…],"rewrite":"…"},
"result":"{\"score\":15,\"issues\":[…],\"rewrite\":\"…\"}"
```

`result.structured_output` is **already-parsed JSON**. `result` is the same content **mirrored
as a string**. Decode `structured_output`: `result` is the assistant's text channel and the
mirroring is incidental — a future version that puts prose there alongside the payload would
silently break anyone parsing `result`.
`OneShotQueryTests.testStructuredPayloadComesFromItsOwnFieldNotResultText` exists to keep the
typed path pointed at the real field even though both parse identically today.

A run launched **without** `--json-schema` has no `structured_output` key at all — verified
against `transcript.ndjson`.

### `modelUsage` totals exceed `usage` — there is a hidden internal call

In this fixture, the top-level `usage` and the `modelUsage` breakdown disagree, consistently:

| | `input_tokens` | `output_tokens` |
|---|---|---|
| `result.usage` | 956 | 542 |
| `result.modelUsage["claude-haiku-4-5-20251001"]` | 1482 | 556 |
| **difference** | **526** | **14** |

That extra 526-in / 14-out is an internal call the CLI makes on its own behalf; it never appears
as an `assistant` event on the wire. A comparable extra Haiku call was observed on the
unstripped Opus run too, so it is not an artifact of the stripped launch.

**Use `modelUsage` for a quota meter, not `usage`** — `usage` undercounts. `modelUsage` is also
the only place the model that actually ran is named, which is how
`testOneShotRunsOnHaikuOnly` can assert exactly one model was billed.

### Timing fields on a one-shot run

```json
"duration_ms":7755, "duration_api_ms":8738,
"ttft_ms":5207, "ttft_stream_ms":1935, "time_to_request_ms":15
```

Two things to note. **`duration_api_ms` (8738) is larger than `duration_ms` (7755)** here, so
the fields are not nested the way the names imply — don't subtract one from the other to derive
client overhead. And `duration_ms` **excludes process spawn**: measured end-to-end through the
Swift API, wall clock ran ~2 s longer than the CLI's self-report (~9.25 s vs ~7.2 s on a live
run). Budget for that in any UI that shows progress.

`time_to_request_ms: 15` sits right in the 7–20 ms persistent-session band, which makes sense —
it measures dispatch after the process is up, and says nothing about the cost of getting there.

## Measured performance (2026-08-07, v2.1.226)

| Turn | `ttft_ms` | `ttft_stream_ms` | `time_to_request_ms` |
|---|---|---|---|
| 1 | 1434 | 971 | 20 |
| 2 | 1334 | 761 | 15 |
| 3 | 2285 | 1548 | 7 |

Process startup ≈ 3.5 s, paid **once per session**. Naive wall-clock for turn 1 was 4.98 s;
turns 2–3 were 0.77 s and 1.55 s.

### Re-measured 2026-08-08 with the full Liquid Glass UI attached

`time_to_request_ms` rose to **21–67 ms** (three turns), against 7–20 ms headless and a
100 ms internal threshold. Full write-up, including the terminal head-to-head, in
`docs/runs/2026-08-08-phase2-perf-gate.md`. `ttft_ms` on the gate turn was 11470 — a reminder
that the client's overhead is a rounding error next to the API round-trip, and that the
*perceived* latency problem is a UI problem, not a dispatch problem.

## Open questions

- Does `--permission-prompt-tool` give true mid-turn pause, and what does it require? (ADR-004)
- Exact shape of `system/api_retry` in practice — documented but not yet observed.
- Behaviour of `--replay-user-messages`; useful for optimistic-send UI acknowledgment.
- Whether `--fork-session` mid-conversation is usable for a "branch this conversation" feature.
- **What the 526-in / 14-out internal call in `modelUsage` actually is** (2026-08-09). It is
  present but invisible on the wire. Whatever it is, it counts against quota.
- **Why `duration_api_ms` can exceed `duration_ms`** (2026-08-09, one-shot run). Blocks any
  attempt to derive client-side overhead by subtraction.
- Whether a `--json-schema` run can ever succeed *without* `structured_output` — i.e. can the
  model answer in prose and still report `subtype: "success"`? `AgentError.noStructuredOutput`
  assumes yes and handles it; not yet observed.
