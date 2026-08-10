# `claude auth status --json` — answering the auth question without spending anything

Observed 2026-08-09 against **claude 2.1.226**. Undocumented publicly as far as we can tell;
recorded here with the payloads that were actually seen.

## Why it was needed

Iris's hard rule is that every session runs on subscription auth, asserted as
`system/init.apiKeySource == "none"`. The problem is *when* that answer arrives.

**`system/init` is emitted per turn, not at process start.** This was already known from Phase 0,
but "per turn" and "nothing at all until a turn" are different claims, so the stronger one was
tested directly:

> A persistent `claude` session was launched and held open for **8 seconds with no input**. It
> emitted **nothing** — no `system/init`, no status, no keepalive.

So the status indicator had no evidence to show until the user sent a first message, and sat on
`checking…` on a freshly opened window. Waiting longer is not a fix; there is nothing coming.

Running a `claude -p` probe to force an init would work and is unacceptable: it spends quota,
from the same five-hour pool as the conversation (see `one-shot-cost-model.md`).

## The command

```
claude auth status --json
```

Reads **local credentials only. No model call, no tokens, no quota.** That is what makes it safe
to run on every app launch.

## Observed payloads

Logged in, subscription, no key in the environment:

```json
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
 "email":"…","orgId":"…","subscriptionType":"pro"}
```

The **same install**, same command, with a (fake) `ANTHROPIC_API_KEY` exported:

```json
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
 "apiKeySource":"ANTHROPIC_API_KEY","email":null,"orgId":null,"subscriptionType":null}
```

## Field notes

| field | observed | what it means |
|---|---|---|
| `loggedIn` | `true` / `false` | whether credentials exist at all |
| `authMethod` | `"claude.ai"` | ⚠️ **stays `"claude.ai"` even with a key in play.** Does not answer the question it appears to answer. |
| `apiProvider` | `"firstParty"` | Anthropic direct, as opposed to Bedrock/Vertex |
| `apiKeySource` | **absent** on the subscription path; `"ANTHROPIC_API_KEY"` when a key is used | the field that actually decides it |
| `subscriptionType` | `"pro"`; `null` whenever a key is used | plan name, safe to show in a tooltip |
| `email`, `orgId` | populated; `null` whenever a key is used | identity, also nulled out by a key |

### The three things worth remembering

1. **`authMethod` is a trap.** It reports how the *account* is authenticated, not how the *next
   request* will be billed. Keying off it would report subscription auth while every token went
   through a key.

2. **`apiKeySource` uses the same name and the same semantics as `system/init.apiKeySource`.**
   That is what makes this a genuine pre-flight check of the invariant Iris already asserts,
   rather than a different and more optimistic question. The two instruments agree by
   construction.

3. **A missing key and an explicit `null` mean the same thing.** The CLI omits `apiKeySource`
   entirely on the subscription path and emits it as `null` in some other states. Any consumer
   must treat both as "no key involved":

   ```swift
   // Deliberately reads a *missing* key and an explicit null the same way.
   apiKeySource: obj["apiKeySource"] as? String
   …
   public var isSubscriptionAuth: Bool { loggedIn && apiKeySource == nil }
   ```

   Pinned by `testAuthStatusTreatsAbsentKeySourceAsSubscription` and
   `testAuthStatusWithAKeyIsNotSubscription` in `OneShotQueryTests`.

## Timing

| how it's invoked | measured |
|---|---|
| directly in a shell | **~0.25 s** |
| through Foundation's `Process` | **~1.2 s** |

The ~1 s difference is process-spawn overhead — the same tax the sidebar's one-shot calls pay,
and the same reason a self-reported `duration_ms` under-reports wall clock (see
`one-shot-cost-model.md`). Fast enough to fire detached at launch and let the indicator fill in
a moment later; **not** fast enough to block startup on.

## How Iris uses it (`AgentKit/Sources/AgentKit/AuthProbe.swift`)

- **The environment is scrubbed exactly as `AgentBridge` scrubs it** — `ANTHROPIC_API_KEY` and
  `ANTHROPIC_AUTH_TOKEN` removed before launch. Without this the probe reports a key the session
  will never see, and warns about a problem that doesn't exist. *The probe must report what the
  session sees, not what the shell exports.*
- **It does not replace the per-turn assertion in `AgentBridge.observe`**, which stays
  authoritative. The probe reports what the install is *configured* to do; `system/init` reports
  what the session *did*.
- **A probe result arriving after `system/init` has answered is discarded** (`guard
  stats.connection == .starting`). On a fast first turn init can win the race, and the
  authoritative answer must not be overwritten by the advisory one.
- **A probe failure is silent**: the indicator falls back to `checking…` until the first turn,
  which is exactly the pre-probe behaviour.

`iris-cli` runs the same probe at startup and prints its wall-clock time, so the harness shows
auth state before you type.

## Open questions

- Other subcommands under `claude auth` (`login`, `logout`, …) and whether any of them are
  scriptable enough to drive a re-auth flow from the UI.
- Whether `apiKeySource` can report values other than `"ANTHROPIC_API_KEY"` — e.g. a token from
  `ANTHROPIC_AUTH_TOKEN`, or a Bedrock/Vertex configuration. Only the one value has been
  observed.
- Whether `subscriptionType` distinguishes plan tiers beyond `"pro"` (presumably `"max"`);
  unverified on this account.
