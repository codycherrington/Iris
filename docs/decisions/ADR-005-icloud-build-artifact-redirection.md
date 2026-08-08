# ADR-005 — Redirect build artifacts out of iCloud Drive

**Date:** 2026-08-07
**Status:** Accepted

## Context

Cody's convention places projects in `Development/Projects/`. That tree is inside iCloud Drive
— `~/Documents/Development` and
`~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Development` resolve to the same
inode.

quoridor-zero was previously bitten by heavy runtime artifacts syncing to iCloud, which is why
the dev-scaffolder and project-inception skills both warn about it and mandate `*.nosync/`
directories for heavy output, with text pointer files instead of symlinks (iCloud mangles
symlinks).

Swift adds its own version: `swift build` / `swift test` create a `.build/` directory inside
the package. Measured at **176 MB** for AgentKit alone with a single dependency-free target —
all of it regenerable, and rewritten on every build.

Xcode's DerivedData already defaults to `~/Library/Developer/Xcode/DerivedData`, outside
iCloud, so the app target needs no equivalent treatment.

## Decision

Keep the repo at `Development/Projects/iris` (preserving the convention), and redirect
SwiftPM's scratch directory outside iCloud via a Makefile:

```make
SCRATCH := $(HOME)/Library/Developer/Iris/agentkit-build
test:
	@swift test --package-path AgentKit --scratch-path $(SCRATCH)
```

`make` is the documented build entry point in README, QUICKSTART, and CLAUDE.md.

## Alternatives considered

- **Repo at `~/Developer/iris`, fully outside iCloud.** Apple's own convention, zero sync
  friction, bare `swift build` just works. Rejected: breaks the Development/ convention shared
  by thirty other projects, and gives up iCloud backup of source.
- **Accept `.build/` syncing.** Simplest. Rejected: 176 MB of regenerable artifacts in iCloud
  plus file-lock contention during builds — the exact failure that hit quoridor-zero.
- **Symlink `.build` to an external path.** Rejected outright: the scaffolding skills
  explicitly forbid symlinks in iCloud trees.

## Consequences

- Source is synced and backed up; 176 MB of build output is not.
- **`make` is mandatory.** A bare `swift build` inside `AgentKit/` silently recreates `.build/`
  in the synced tree. Documented in three places for that reason.
- SourceKit-LSP still writes a small `.build/index-build/` in-repo (~64 KB) for editor
  indexing. Gitignored, and small enough to accept; noted here so it isn't mistaken for the
  redirection failing.
- `make clean` removes the external scratch directory, not anything in the repo.
