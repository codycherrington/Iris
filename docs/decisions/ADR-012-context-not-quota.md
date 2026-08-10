# ADR-012 — The context readout measures context, not quota

**Date:** 2026-08-10 · **Status:** accepted (amended same day: it's a chip in the status bar,
not a bar under the composer — see *Consequences*)

## Context

Cody: *"Show usage percentage bar below the chat bar as well."*

Iris's own prompt improver, run on that sentence, flagged it before anything was built:
*"Vague success metric: 'usage percentage' undefined — what is being measured (tokens, API
calls, etc.)?"* Fair. There were two candidates, and they are not interchangeable — one is
"how close am I to being cut off today", the other is "how close is this conversation to a
compact."

**Quota was the intuitive answer, and Phase 0 had recommended it.** `docs/plan.md` records
`rate_limit_event` as *"better than a cost meter — a real quota gauge with a reset
countdown."* That is still true as far as it goes, and it does not go as far as a percentage.
The event's full payload is:

```json
{ "status": "allowed", "resetsAt": 1786167000, "rateLimitType": "five_hour",
  "overageStatus": "rejected", "overageDisabledReason": "org_level_disabled",
  "isUsingOverage": false }
```

A state, a deadline, and two overage flags. **No numerator, no denominator.** There is no
`claude usage` subcommand either — the CLI's command list is `agents`, `auth`, `auto-mode`,
`doctor`, `gateway`, `import`, `install`, `mcp`, `plugin`, `project`, `setup-token`,
`ultrareview`, `update`. Nothing reports consumption. So a quota percentage would have to be
estimated from token counts against a limit Anthropic doesn't publish to the client, and
rendered as a confident bar.

**Context, by contrast, is measured exactly** and both halves come from the same `result`
event:

- **Numerator** — `usage.input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
  This is the per-turn block, so it describes what the last prompt actually weighed. Cached
  tokens are included deliberately: a cached token occupies the window identically to an
  uncached one, it is only cheaper to send.
- **Denominator** — `modelUsage[<the model system/init reported>].contextWindow`.

## Decision

**Show a context gauge. Leave quota as the status chip it already is — status plus reset
countdown, exactly what the CLI reports and nothing more.**

The denominator is looked up **by model id**, not by taking the max or the first entry:

```swift
r.modelUsage[stats.model]?.contextWindow ?? r.modelUsage.values.compactMap(\.contextWindow).max()
```

`modelUsage` routinely carries a second entry, because the CLI makes its own small Haiku
calls alongside the session's model. In a captured transcript the two are `claude-opus-5`
(1,000,000) and `claude-haiku-4-5` (200,000). Picking `.max()` happens to be right there and
is right for the wrong reason; picking `.first` or sorting by output tokens is wrong on turn
one, where the cumulative Haiku entry (14 output tokens) outweighs Opus's 5. The only correct
key is the one `system/init` named.

The bar is absent, not zero, before the first result. A bar sitting at 0% asserts a
measurement that hasn't happened.

## Alternatives considered

**Estimate quota from cumulative tokens against a hardcoded plan limit.** Rejected. The limit
isn't published, varies by plan, and is shared with every other Claude Code session the user
is running — including Iris's own sidebar tools. An estimate would be wrong by an unknowable
factor and would be *believed*, because it looks like a measurement. Iris exists to make the
real numbers visible; inventing one in the accounting strip is the specific failure this
project should never ship.

**Wait for a CLI that reports quota.** Rejected as a reason to ship nothing: context is
independently useful and this doesn't preclude adding quota later. If `rate_limit_info` grows
a `used`/`limit` pair, the same strip can carry a second bar.

**Put it in the status bar with the other metrics.** Rejected on Cody's placement — under the
composer — which seemed like the better spot too: it's the number that should change what you
type next, so it belongs where you're typing.

**Reversed the same day, having seen it.** Cody: *"have the context percentage be another
little pill like the others with just a percentage number, no bar or chart."* He's right, and
the reasoning above was the sort that survives only until something is on screen. A progress
bar is a shape for a quantity you watch move — it earns its width by making a *rate* legible.
Context doesn't move like that; it steps once per turn and mostly sits still. What the bar
actually contributed was a second row of chrome between the composer and the status bar, and a
horizontal rule that read as a divider. As a chip it costs nothing, sits beside the quota chip
it belongs next to, and the tokens/window detail moves into the tooltip where the same detail
already lives for every other chip.

## Postscript: quota got its percentage after all (2026-08-10, same day)

This ADR's central claim — *the CLI does not report a quota percentage* — was true of every
surface it examined, and it examined the wrong set. Cody pointed at his own terminal status
line showing `5h 65% 2h 47m left · 7d 55%` and asked for exactly that.

The numbers are real and local. They live in the JSON payload the CLI pipes to a `statusLine`
command, under `rate_limits.five_hour.used_percentage` — a surface that is **interactive-only**
and that a `-p` session never invokes. Everything this ADR says about print mode still holds;
what it missed is that print mode isn't the only way to ask.

`QuotaProbe` gets them by borrowing the mechanism: a short interactive session under a pty,
with `statusLine` overridden to dump its stdin, killed as soon as the payload contains
`rate_limits`. Stripped the same way the sidebar tools are, it costs **1,132 in / 133 out, zero
cache creation, ~4 s**. Full investigation, including the three constraints that shape it and
the flag interaction that keeps the cold start at zero, is in
[`docs/research/quota-percentages.md`](../research/quota-percentages.md).

**The reasoning below stands; the conclusion narrowed.** Refusing to *invent* a quota
percentage was right, and it is exactly why the number now on screen is a measured one that
costs a turn rather than an estimate that costs nothing. The lesson is about scope: "the data
isn't available" was really "the data isn't available *through the interface I was already
using*", and those are different claims. The second one is worth checking before it gets
written down as the first.

Context stays where it is. The two chips answer different questions and both are now measured.

## Consequences

- **The plan's Phase 0 note is now half wrong** and has been annotated rather than deleted.
  `rate_limit_event` is better than a cost meter *for what it is*; it is not a gauge.
- **The Ledger card "Quota gauge + context gauge" is one half done, and the other half is
  blocked on the CLI**, not on Iris. Worth recording so it doesn't read as unfinished work.
- **Thresholds are behavioural, not decorative**: cyan under 70%, amber to 90%, red past it.
  Those are the points where what you'd do differently changes — be deliberate about pasting
  large files, then expect a compact.
- The readout reports the *last turn*, not a running maximum. After a compact it drops, which
  is correct and is the moment the number is most worth seeing.
- **A session chip landed beside it**, for the same reason and from the same event: cumulative
  tokens from `modelUsage`, which is already session-cumulative and so is assigned rather than
  accumulated — adding to it would square the count by the third turn. The headline figure is
  dominated by cache reads, which is honest: every turn re-sends the conversation and that is
  real work drawn from the same pool. The four-way breakdown and the turn count are in the
  tooltip rather than four chips wide.
- **Turns are counted client-side**, not read from `result.num_turns` — that field describes
  the run that just finished (and is 2 for a forced-tool-call run), not the conversation.
