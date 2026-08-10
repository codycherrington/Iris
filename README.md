# Iris

A native macOS agent workbench — SwiftUI, real Liquid Glass, driving Claude Code as a
persistent subprocess. Runs on your Claude subscription; never uses a paid API key.

> Iris is an independent project. It is not Claude Code, and is not an Anthropic product.

## Why it exists

The terminal interface is excellent and fast. Iris only earns its place if it stays that fast
while adding what a GUI can do better: a real diff view before a write lands, a live tree of
spawned subagents, a quota gauge, a searchable session library, and sidebar tools that don't
eat the main conversation's context.

**Performance is a gate, not a polish item.** If Iris ever feels slower than the terminal,
that's a bug at the top of the list.

## Status

| Phase | What | State |
|---|---|---|
| 0 | Spike: auth, streaming, perf, permissions | ✅ **GO** — see `docs/devlog/2026-08-07-inception.md` |
| 1 | `AgentKit` headless core | ✅ bridge, decoder, one-shot runner, auth probe, question protocol, 48 tests |
| 2 | Minimal chat UI — perf gate | ✅ **PASS** — see `docs/runs/2026-08-08-phase2-perf-gate.md` |
| 3 | Liquid Glass design system | ✅ dark theme, glass transcript, composer |
| 4 | Persona wizard, sidebars, file picker, project switcher | 🟡 persona wizard (ADR-007), sidebar runner (ADR-008), tool system + four tools (ADR-009), question cards (ADR-010), model/effort picker, pre-flight auth; **file picker and project switcher next** |
| 5 | Subagent tree, session library, permission UI | ⬜ |

The authoritative design is **`docs/plan.md`**. Read the relevant phase before implementing.

## Phase 0 results (measured, not assumed)

| Turn | `ttft_ms` | `time_to_request_ms` |
|---|---|---|
| 1 | 1434 | 20 |
| 2 | 1334 | 15 |
| 3 | 2285 | 7 |

`time_to_request_ms` is per-turn dispatch overhead inside the persistent process — **7–20 ms**.
TTFT is dominated by the API round-trip, so it matches the terminal. Process startup (~3.5 s)
is paid **once per session**, not per turn. That result is what makes the whole design viable.

Also confirmed: `apiKeySource: "none"` (subscription auth), user skills load, and a denied
write completes the turn rather than hanging — handing back the full intended content, which
is what makes a native diff-approval UI possible without an MCP permission server.

## Sidebar tools: also measured, and the plan was half wrong (2026-08-09)

Sidebar tools run as short-lived `claude -p` calls so they don't touch the conversation's
context. That isolation is real — and it is exactly why an unstripped call is expensive, since
it inherits nothing and rebuilds everything. Same prompt, two launches:

| | default `claude -p` | stripped launch |
|---|---|---|
| `duration_ms` | 32,517 | 6,567 |
| cache-creation tokens | 18,854 | **0** |
| model | opus-5, silently | haiku |

≈55× cheaper, ≈5× faster. Those flags are the defaults in `OneShotConfiguration`, and three
tests plus `make harness ARGS="-s"` exist to keep them there. On subscription auth nothing is
billed — the shared resource is **quota**, so a chatty sidebar can rate-limit the main session.
See `docs/research/one-shot-cost-model.md` and ADR-008.

Even stripped, a click lands around **9 s** — ~7.2 s of model time plus ~2 s of process spawn the
CLI's own `duration_ms` doesn't count. That number designed the panel (ADR-009): the pending state
says *"haiku · separate process"* rather than showing a bare spinner, the tool picker marks which
tools spend quota, and every result carries a usage footnote that warns on a cold start — so a
cost regression is visible in the app, not just in the test suite.

## Architecture

```
SwiftUI (macOS 26)
   LeftRail │ ChatTranscript │ RightPanel
                  ▲
                  │ @Observable SessionModel
                  ▼
   AgentBridge (actor) — Process + pipes, NDJSON codec
                  │
       stdin ▼    ▲ stdout
   claude -p --input-format stream-json
             --output-format stream-json
             --verbose --include-partial-messages
```

No Node runtime, no sidecar, no API key. The `claude` CLI is already installed and
self-contained; Iris speaks NDJSON to it over a pipe.

## Requirements

- macOS 26+ (Liquid Glass is `macOS 26.0+`)
- Xcode 26+
- `claude` CLI ≥ 2.1.211 (subagent text forwarding); developed against 2.1.226
- An active Claude subscription, logged in via `claude` — **no `ANTHROPIC_API_KEY`**

## Build

This repo lives in iCloud Drive, so build artifacts are redirected outside it.
**Always build through `make`.**

```bash
make test     # run AgentKit tests against captured stream-json fixtures
make build    # build AgentKit
make run      # build and launch the app (debug)
make install  # build release, sign, and install to /Applications
make icon     # regenerate the app icon from the design tokens
make help     # all targets
```

A bare `swift build` inside `AgentKit/` would recreate a heavy `.build/` in the synced tree.

## Layout

```
AgentKit/          Swift package — headless core, no UI, unit tested
  Sources/AgentKit/
    AgentEvent.swift     stream-json schema + permissive decoder
    AgentBridge.swift    actor: one long-lived process, many turns
    OneShotQuery.swift   the opposite: short-lived, stripped, structured (sidebar tools)
  Tests/AgentKitTests/
    Fixtures/*.ndjson    real captured CLI output from the spikes
docs/              plan, devlog, ADRs, research, story  (see CLAUDE.md)
Makefile           build wrapper that keeps artifacts out of iCloud
```
