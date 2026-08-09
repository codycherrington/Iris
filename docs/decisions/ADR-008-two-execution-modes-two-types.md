# ADR-008 — Two execution modes, two types: `OneShotQuery` is not part of `AgentBridge`

**Date:** 2026-08-09
**Status:** Accepted
**Commit:** `5d3947b`

## Context

Phase 4 needs sidebar tools — notes, prompt improver, SQL reviewer, bug checker. `docs/plan.md`
specifies how they talk to the model:

> Sidebar tools run as **separate short-lived `claude -p` calls with `--json-schema`** for
> structured results, so they never consume the main session's context.

Iris already has one way to talk to the model: `AgentBridge`, the actor from Phase 1 that owns a
long-lived `Process` and streams NDJSON over its pipes. The obvious economical move is to reuse
it — add a `query(schema:)` method, or a "detached turn" mode, and avoid a second subprocess
implementation with its own pipe handling, line assembly and auth assertion.

Two measurements, taken 2026-08-09 before any of this was built, decided against that. Both are
in `docs/research/one-shot-cost-model.md`:

1. **A default one-shot call is expensive**, and not in the way the plan assumed. It inherits
   nothing, so it rebuilds everything: **18,854 cache-creation tokens, 32,517 ms, silently on
   opus-5, $0.237 estimated** — for a six-word prompt. Stripped and pinned to Haiku, the same
   prompt is **0 cache tokens, 6,567 ms, $0.0043**. ≈55× and ≈5×.
2. **The requirements are opposite in kind, not in degree.** `AgentBridge` exists because
   per-turn process startup would break the perf gate — its whole purpose is to *keep* state
   alive across turns. A sidebar tool's purpose is to *have* no state: no context, no
   `CLAUDE.md`, no skills, no MCP, no session file, and a different model.

The plan's rationale was also half wrong and needed correcting on the record. "Never consumes
the main session's context" is true — and it is exactly *why* the call is expensive. Isolation
and cheapness are not the same property; the mechanism that delivers the first destroys the
second unless you strip the launch deliberately.

## Decision

**A separate type, `OneShotQuery`, with its own configuration type and its own defaults.**
Not a mode on `AgentBridge`, not a flag, not an optional parameter.

The public surface (`AgentKit/Sources/AgentKit/OneShotQuery.swift`):

- `StructuredOutput` — a protocol pairing a `Decodable` type with a **hand-written**
  `jsonSchema` string literal. Swift has no JSON Schema reflection, and the literal is what the
  model actually sees, so keeping it beside the properties makes drift visible in review.
- `OneShotConfiguration` — where the decision actually lives. **Every default is the cheap
  one**: `model: "haiku"`, `tools: []`, `--setting-sources ""`, `--system-prompt` (replacing,
  never appending), `--exclude-dynamic-system-prompt-sections`, `--strict-mcp-config`,
  `--disable-slash-commands`, `--no-session-persistence`, a 60 s deadline, and
  `requireSubscriptionAuth: true`. Anything that costs tokens is off, and turning it back on is
  a deliberate act at a call site.
- `OneShotUsage` — returned to the caller, not logged. Exposes `didPayColdStart`
  (`cacheCreationTokens > 0`), which should be `false` for every sidebar tool forever.
- `OneShotQuery.run` / `.runRaw`.

`RunResult` gained `structuredOutputJSON`, `usage` and `decodeStructuredOutput(_:)`, and
`AgentError` gained `timedOut`, `noStructuredOutput`, `runFailed` and
`noResult(exitCode: Int32?)`. Those are shared decoder surface, not a second protocol
implementation — the one-shot fixture decodes through the existing decoder with zero
unrecognized events.

The one deliberate inconsistency: the runner uses `--output-format stream-json` even though it
never streams, and even though `json` would give the identical result line. It does so purely
so `system/init` is visible and the `apiKeySource == "none"` assertion runs. **The hard rule
applies to sidebar tools exactly as it does to the session** — a cheaper call is not a reason
for a weaker auth check.

## Alternatives considered

- **Extend `AgentBridge` with a detached/structured query mode.** The reuse argument is real:
  pipe setup, `LineAssembler`, event decoding and the auth assertion are all already there, and
  the one-shot runner does duplicate the plumbing. Rejected because the *configuration* is the
  substance of this feature, not the plumbing. Sharing a type would mean one configuration
  surface serving two sets of defaults that are opposite on every axis that matters — model,
  tools, setting sources, session persistence, lifetime. The predictable failure mode is a
  future edit that "unifies" a default and quietly reintroduces an 18,854-token cold start on
  every sidebar press, with nothing structural to stop it. Two types make the wrong thing
  require typing.
- **Reuse the live session for sidebar work** (send the tool's prompt as a normal turn and
  filter it out of the transcript). Genuinely the cheapest option in tokens — the session's
  cache is already warm, so there is no cold start at all. Rejected on the plan's own grounds:
  it pollutes the conversation's context with sidebar chatter, makes every sidebar press a
  turn the user has to scroll past or the app has to hide, and serializes tools behind the
  conversation. Context isolation was the requirement; cost was the surprise.
- **Keep the CLI's defaults and accept the cost.** Rejected on the numbers. At ~32 s and 18,854
  cache-creation tokens per press, a sidebar is a thing you click twice and stop using — and on
  subscription auth it would burn the same five-hour quota window the conversation needs.
- **Derive the JSON schema from the Swift type by reflection.** No standard mechanism exists,
  and hand-rolling one over `Mirror` would produce a schema that *isn't* the one the model sees
  when it inevitably diverges. A literal next to the properties is uglier and more honest.
- **Ship without a timeout.** Rejected: a hung sidebar tool leaves a spinner up forever. The
  deadline is what turned up ADR-008's most expensive bug (below), which is its own argument.

## Consequences

- **The cheap path is the default path.** Getting an expensive sidebar tool now requires
  explicitly overriding `OneShotConfiguration`.
- **Three tests are cost regression guards, not correctness tests**, and should be read that
  way: `testStrippedLaunchPaysNoColdStart` (cache creation must be 0),
  `testOneShotRunsOnHaikuOnly` (exactly one model billed, and it contains "haiku"), and
  `testArgumentsStripEverythingThatCostsTokens` — which exists specifically so nobody tidies the
  flag list. `make harness ARGS="-s"` runs the same check live and **exits 1** if cache creation
  comes back non-zero.
- **Some plumbing is duplicated** between `AgentBridge` and `OneShotQuery`: pipe setup,
  readability handlers, the stderr drain, the API-key scrub. Accepted knowingly. If a third
  execution mode ever appears, extract the plumbing then — but keep the configuration types
  separate regardless, because the configuration is the thing that must not be shared.
- **Sidebar latency is ~9 s, and that is now a UI requirement.** Process spawn adds ~2 s the
  CLI's `duration_ms` doesn't count. Every sidebar tool needs a pending state from its first
  version.
- **Phase 5's cost/quota meter must count one-shot usage or it lies.** `OneShotUsage` is
  returned rather than logged for exactly this reason. On subscription auth the dollar figure is
  a client-side estimate and nothing is billed; the shared resource is the five-hour quota
  window, and `rate_limit_event` on one-shot runs reports the same window as the conversation.
- **Adding a sidebar tool now means writing a JSON Schema literal by hand.** Slightly annoying
  four times over (notes, prompt improver, SQL reviewer, bug checker), and the schema must use
  `additionalProperties: false` with every field in `required` — the CLI is stricter about the
  schema than about your `Decodable`, so a missing `required` entry shows up as a silently
  absent field rather than an error.
- **A crash was found on the way here that fixtures could never have caught.**
  `Process.terminationStatus` raises an uncatchable Objective-C exception when read on a live
  process, and the timeout path read it while terminating one — so every one-shot timeout would
  have aborted Iris with `Abort trap: 6`, at 35/35 tests green. Guarded now by `exitedStatus(_:)`,
  which is why `AgentError.noResult` carries an **optional** exit code. Full write-up:
  `docs/research/process-termination-status-trap.md`.
- **`docs/plan.md`'s Phase 4 rationale is amended, not deleted.** The "never consumes the main
  session's context" claim stands for context and is annotated for cost. Anyone auditing Phase 4
  against the plan should read this ADR first.

## Rough edges found in review and fixed

Two defects surfaced when the documentation pass read the fixture more carefully than the
implementation had. Both are now fixed, and both are worth recording because they were
invisible to a passing test suite.

**`OneShotUsage.model` sorted alphabetically.** It was
`result.modelUsage.keys.sorted().first` — not the model that did the work. On the
Opus-escalated run that motivated this whole type (`claude-haiku-4-5` +
`claude-opus-5`), alphabetical order reports *haiku*, concealing exactly the escalation the
field exists to expose. Now sorted by output tokens, with every billed model kept in
`models`. Pinned by `testPrimaryModelIsTheHeaviestNotTheAlphabeticallyFirst`.

**`result.usage` undercounts `result.modelUsage`.** The fixture reports `usage` 956 in / 542
out against a `modelUsage` total of **1482 / 556** — a shortfall of exactly 526 in / 14 out,
which is the CLI's hidden internal call. The same 526/14 delta appears on the unstripped Opus
run, so it is a fixed cost rather than noise. `OneShotUsage` originally read the `usage`
block and therefore under-reported every sidebar call by that margin. It now sums
`modelUsage`. Anything metering quota must do the same — see
`testUsageBlockUndercountsModelUsage`.
