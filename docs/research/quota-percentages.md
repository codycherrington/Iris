# Where the rate-limit percentages actually live

Investigated 2026-08-10 against `claude` 2.1.226. Prompted by Cody pointing at his terminal
status line — `5h [████░░] 65% 2h 47m left · $77.80 · 7d 55%` — and asking for that number in
Iris.

## Print mode does not have it

Not an inference from the captured fixture. Checked live, today:

**`rate_limit_event`, full payload:**

```json
{ "status": "allowed", "resetsAt": 1786342800, "rateLimitType": "five_hour",
  "overageStatus": "rejected", "overageDisabledReason": "org_level_disabled",
  "isUsingOverage": false }
```

A state, a deadline and two overage flags. No numerator, no denominator.

**Every event type a `-p --output-format stream-json --verbose --include-partial-messages`
session emits**, enumerated from a real run:

```
system/init · system/status · system/thinking_tokens · stream_event · assistant ·
rate_limit_event · result/success
```

`system/status` is `{"status":"requesting"}` and nothing more. None of the others carries a
percentage.

**There is no `usage` subcommand.** The full list is `agents`, `auth`, `auto-mode`, `doctor`,
`gateway`, `import`, `install`, `mcp`, `plugin`, `project`, `setup-token`, `ultrareview`,
`update`.

**Nothing on disk caches it.** `~/.claude/{cache,daemon,sessions,session-env}` and the session
transcripts under `~/.claude/projects/**/*.jsonl` contain no rate-limit figures. (Grep hits for
`used_percentage` in that tree are conversations *about* this problem, which is its own small
lesson about grepping a directory full of transcripts.)

## The status line has it

Claude Code pipes a JSON blob to the configured `statusLine` command on stdin. It contains:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 72, "resets_at": 1786342800 },
  "seven_day": { "used_percentage": 55.00000000000001, "resets_at": 1786413600 }
}
```

Note `55.00000000000001` — these are floats, not integers.

The same payload also carries `context_window.used_percentage`, `cost.total_cost_usd`,
`model.id`, `effort.level` and `exceeds_200k_tokens`. It is by some distance the richest
observability surface the CLI exposes, and none of it reaches print mode.

### Three constraints, each found by hitting it

1. **`statusLine` is never invoked in print mode.** Tested directly: `claude -p --settings
   <file with a statusLine command>` runs to completion and the command is not called. So the
   payload requires an *interactive* session.
2. **An interactive session needs a pty.** Without one, `script: tcgetattr/ioctl: Operation not
   supported on socket`. `/usr/bin/script -q /dev/null <cmd>` supplies it.
3. **`rate_limits` is absent until the session has made an API call.** A session that starts and
   idles produces a payload with `context_window.used_percentage: null` and *no `rate_limits`
   key at all* — the numbers come from response headers. So the probe has to say something and
   wait for a later render.

And one that isn't about the mechanism:

4. **Interactive sessions refuse to start in an untrusted folder.** They show
   `❯ 1. Yes, I trust this folder`, which in an unattended pty is a hang. Trust is per-directory
   in `~/.claude.json` under `projects[path].hasTrustDialogAccepted`. Iris reads that to find a
   folder already trusted; it does not flip the flag and does not answer the prompt, because
   trusting a directory is a decision about file access that belongs to the user.

## Cost, measured

Same prompt, same probe, with and without the sidebar's stripping flags:

| launch | cache creation | in / out | wall |
|---|---|---|---|
| interactive defaults | **7,555** | 10 / 166 | ~5 s |
| `--setting-sources '' --tools '' --exclude-dynamic-system-prompt-sections --system-prompt …` | **0** | 1,132 / 133 | ~4 s |

The stripped launch is the one Iris uses. The flag interaction worth recording: **`--setting-sources ''`
does not disable `--settings`.** The status-line override still applies, so the probe keeps its
dump script while dropping `CLAUDE.md`, skills, plugins and MCP config. That was tested rather
than assumed — if it had gone the other way, the probe would have had to pay the 7.5k every
time.

Verified end-to-end through `AgentKit` (`make harness ARGS="-q"`):

```
running in       /Users/codycherrington/Documents/Development/Courses/OdinProject/Ruby
5-hour           75%  ·  2h35m left
7-day            56%  ·  22h15m left
wall             4.103271167 seconds
```

## The part to be honest about

**The probe spends the thing it measures.** ~1.1k tokens and one turn, per reading. Iris runs it
at launch and then at most every 15 minutes, and clicking the chip forces a refresh — which is
also why the tooltip shows the reading's age rather than implying it's live.

It is also a scrape of a surface with no compatibility promise. If a future CLI renames
`rate_limits` or stops shipping percentages to the status line, this breaks — and it breaks
visibly, as a `—` in the chip with the error in the tooltip, rather than as a wrong number.
The moment print mode reports these directly, delete `QuotaProbe` and read them from the stream.
