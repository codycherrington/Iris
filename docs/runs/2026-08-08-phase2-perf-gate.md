# 2026-08-08 — Phase 2 perf gate: Iris vs. the terminal

**Verdict: PASS**, with one real defect found and fixed — which is exactly what the gate was
for.

Measured against `claude` 2.1.226, model `claude-opus-5`, on macOS 26.5.

## The task

The same prompt run both ways, chosen to be realistic rather than a toy — it requires reading
project files and reasoning about a design tradeoff:

> Explain the tradeoff between Iris's deny-then-retry permission model (catch
> `system/permission_denied`, show a diff, re-issue with the tool allowed) and a hypothetical
> mid-turn pause via `--permission-prompt-tool`. Which is more robust against a UI deadlock,
> and why did Phase 0 pick the first one? Answer in 4-6 sentences.

## Numbers

**Terminal baseline** — fresh `claude -p --output-format json`, cwd = repo root:

| Metric | Value |
|---|---|
| wall clock | 20.44 s |
| `duration_ms` | 17607 |
| `duration_api_ms` | 18858 |
| `num_turns` | 3 |
| `total_cost_usd` | 0.1509 |

**Iris** — same prompt, warm session:

| Metric | Value |
|---|---|
| `ttft` | 11470 ms |
| `dispatch` (`time_to_request_ms`) | **43 ms** |
| session cost | $0.1224 |

Two further Iris turns that day, on different prompts, for dispatch spread: **21 ms** and
**67 ms**.

## Reading the numbers honestly

Wall clock is **not** comparable between the two runs and shouldn't be quoted as if it were.
The model took different tool paths each time — the terminal run did three turns re-verifying
against the repo, the Iris run did a single `Read` — so the totals measure the model's choices,
not the client's overhead.

`dispatch` is the number that isolates what Iris itself costs, which is why Phase 0 chose it.
Against the Phase 0 baseline:

| | dispatch |
|---|---|
| Phase 0 (headless, no UI) | 7–20 ms |
| Phase 2/3 (full Liquid Glass UI attached) | 21–67 ms |
| App's own "concerning" threshold | 100 ms |

Attaching the entire glass UI cost tens of milliseconds, not hundreds. TTFT remains dominated
by the API round-trip in both cases. **Constraint #3 holds.**

## The defect the gate caught

Cody's first read of the live app was that it "felt like a stall for a minute" — despite
43 ms dispatch. Both things were true: the app was fast and it felt slow.

`SessionModel.send()` set `isBusy = true` but appended nothing to the transcript until the
first content event arrived. For most of an 11 s TTFT the transcript showed **nothing at all**.
No stall — just no feedback.

Fixes, in order:

1. Seed an empty assistant message on send, so the "…" placeholder appears immediately.
2. Show reasoning progress beside Iris's name — `thinking · N tokens`, counting up live off
   `thinking_delta`, so there is a moving number during the dead air.
3. Correct a related bug: thinking only attached to *unconfirmed* messages, so on a multi-step
   turn (reason → tool → reason again) every later round of reasoning had nowhere to render
   and reached only the status bar.

This is the case for having a gate at all. A pure benchmark would have passed at 43 ms and
shipped a UI that felt broken.

## Follow-up

Re-run this comparison after Phase 4 lands sidebar tools, since those spawn additional
short-lived `claude -p` processes and are the most likely thing to regress dispatch.
