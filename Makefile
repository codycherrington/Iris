# Iris
#
# This repo lives in iCloud Drive. SwiftPM's .build/ directory is large and churns on
# every build, so it is redirected OUTSIDE iCloud via --scratch-path. Always build through
# `make`; a bare `swift build` inside AgentKit/ would recreate .build/ in the synced tree.
#
# (Xcode's DerivedData already defaults to ~/Library/Developer/Xcode/DerivedData, which is
# outside iCloud, so the app target needs no equivalent handling.)

SCRATCH := $(HOME)/Library/Developer/Iris/agentkit-build
PKG     := AgentKit

.DEFAULT_GOAL := help

.PHONY: help build test clean scratch-path fixtures harness bench

help: ## Show available targets
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build AgentKit (artifacts outside iCloud)
	@swift build --package-path $(PKG) --scratch-path $(SCRATCH)

test: ## Run AgentKit tests against the captured stream-json fixtures
	@swift test --package-path $(PKG) --scratch-path $(SCRATCH)

harness: ## Interactive multi-turn conversation through AgentBridge (no UI)
	@swift run --package-path $(PKG) --scratch-path $(SCRATCH) iris-cli $(ARGS)

bench: ## Scripted 3-turn run; reports per-turn dispatch overhead vs the Phase 0 baseline
	@swift run --package-path $(PKG) --scratch-path $(SCRATCH) iris-cli --benchmark

clean: ## Remove build artifacts
	@rm -rf $(SCRATCH)
	@echo "removed $(SCRATCH)"

scratch-path: ## Print where build artifacts go
	@echo $(SCRATCH)

fixtures: ## List captured stream-json fixtures
	@ls -la $(PKG)/Tests/AgentKitTests/Fixtures/
