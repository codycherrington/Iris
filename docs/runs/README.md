# Runs

Auto-generated reports: performance measurements, protocol captures from `claude` upgrades,
and any benchmark comparing Iris against the terminal.

The Phase 0 baseline lives in `docs/research/stream-json-protocol.md` and the README status
table. Any run that changes those numbers should be recorded here with the date and the
`claude` version it was measured against.

| Run | What | Verdict |
|---|---|---|
| `2026-08-08-phase2-perf-gate.md` | Phase 2 exit gate — Iris vs the terminal on the same real task, `claude` 2.1.226 | **PASS** — 43 ms dispatch with the full glass UI, vs 7–20 ms headless and a 100 ms threshold. Caught a perceived-stall defect a pure benchmark would have missed. |

A run report is not just numbers: record what the measurement *felt* like too. The Phase 2
gate passed on timing and still surfaced a UI that read as hung — that half of the result only
exists because a human used the thing.
