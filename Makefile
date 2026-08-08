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
CONFIG  := debug
# The .app is assembled outside iCloud too — it embeds the binary and would sync otherwise.
APP     := $(HOME)/Library/Developer/Iris/Iris.app

# Minimal bundle metadata. Iris is built from SwiftPM rather than an .xcodeproj, so the
# bundle is assembled here instead — same command-line workflow, no fragile project file.
define INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>CFBundleName</key><string>Iris</string>\n<key>CFBundleDisplayName</key><string>Iris</string>\n<key>CFBundleExecutable</key><string>Iris</string>\n<key>CFBundleIdentifier</key><string>com.codycherrington.iris</string>\n<key>CFBundlePackageType</key><string>APPL</string>\n<key>CFBundleShortVersionString</key><string>0.1.0</string>\n<key>CFBundleVersion</key><string>1</string>\n<key>LSMinimumSystemVersion</key><string>26.0</string>\n<key>NSHighResolutionCapable</key><true/>\n<key>NSSupportsAutomaticTermination</key><true/>\n</dict></plist>
endef
export INFO_PLIST

.DEFAULT_GOAL := help

.PHONY: help build test clean scratch-path fixtures harness bench app run

help: ## Show available targets
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build AgentKit (artifacts outside iCloud)
	@swift build --package-path $(PKG) --scratch-path $(SCRATCH)

test: ## Run AgentKit tests against the captured stream-json fixtures
	@swift test --package-path $(PKG) --scratch-path $(SCRATCH)

app: ## Build Iris.app and assemble the bundle (artifacts outside iCloud)
	@swift build -c $(CONFIG) --package-path $(PKG) --scratch-path $(SCRATCH) --product Iris
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(SCRATCH)/$(CONFIG)/Iris" "$(APP)/Contents/MacOS/Iris"
	@printf '%b\n' "$$INFO_PLIST" > "$(APP)/Contents/Info.plist"
	@echo "APPL????" > "$(APP)/Contents/PkgInfo"
	@echo "built $(APP)"

run: app ## Build and launch Iris.app
	@open "$(APP)"

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
