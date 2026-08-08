# Quickstart Guide

## Prerequisites

```bash
xcodebuild -version          # need Xcode 26+
swift --version              # need a macOS 26 target toolchain
claude --version             # need >= 2.1.211
env | grep ANTHROPIC         # should print NOTHING — Iris uses subscription auth
```

If `ANTHROPIC_API_KEY` is set, unset it. Iris asserts `apiKeySource == "none"` at runtime and
is designed never to fall back to per-token billing.

## Build & test

**Always use `make`.** This repo is inside iCloud Drive; the Makefile redirects SwiftPM's
build directory to `~/Library/Developer/Iris/agentkit-build` so hundreds of MB of
regenerable artifacts never sync.

```bash
make test            # AgentKit tests against captured stream-json fixtures
make build           # build AgentKit
make clean           # delete build artifacts
make scratch-path    # print where artifacts go
make fixtures        # list captured fixtures
make help            # all targets
```

Do **not** run bare `swift build` / `swift test` inside `AgentKit/` — that recreates a heavy
`.build/` in the synced tree. (SourceKit-LSP still writes a small `.build/index-build/` for
editor indexing; it's gitignored and only a few hundred KB.)

## Regenerating the test fixtures

The tests replay real CLI output. To recapture after a `claude` upgrade:

```bash
claude -p --input-format stream-json --output-format stream-json \
       --verbose --include-partial-messages --session-id "$(uuidgen)"
```

Write NDJSON user turns to stdin, one per line:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
```

Capture stdout to `AgentKit/Tests/AgentKitTests/Fixtures/`. If the tests then fail, the
protocol changed — that's the fixtures doing their job.

## Git

Branch and commit conventions follow the **git-workflow** skill. Don't freestyle branch names
or merge behavior.

```bash
git status
git add .
git commit -m "message"
```

## Common commands

| Command | What it does |
|---|---|
| `make test` | Run the AgentKit suite |
| `make clean && make build` | Full rebuild |
| `open Iris.xcodeproj` | Open the app target (once Phase 2 creates it) |
| `git log --oneline` | Commit history |

## Tips

- **Read `docs/plan.md` before implementing a phase.** It has the acceptance gates.
- Phases are sequential — don't start Phase N+1 while Phase N's gate is unmet.
- Invoke the `documentarian` agent at the end of every phase or significant session.
- Never commit anything from `*.nosync/`.
