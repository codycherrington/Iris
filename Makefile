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
ICON    := Resources/AppIcon.icns
# Where `make install` puts a real, launchable copy.
INSTALLED := /Applications/Iris.app

# The version, in one place.
#
# Bumped on every push, by branch: `dev` +0.0.1, `test` +0.1.0, `main` +1.0.0, with a bump
# resetting everything below it (a `test` push from 0.0.23 is 0.1.0, not 0.1.23). Patch does
# not carry — 0.0.9 goes to 0.0.10, because rolling into 0.1.0 would collide with what a
# `test` push means.
#
# It lives here rather than inline in the plist below because it now changes on every push,
# and hunting for it inside a single-line XML blob is how a bump gets skipped.
VERSION := 0.0.24
# Monotonic build number. Kept equal to the patch count so far, so it never goes backwards
# when the minor or major resets the patch to 0.
BUILD   := 24

# Minimal bundle metadata. Iris is built from SwiftPM rather than an .xcodeproj, so the
# bundle is assembled here instead — same command-line workflow, no fragile project file.
define INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>CFBundleName</key><string>Iris</string>\n<key>CFBundleDisplayName</key><string>Iris</string>\n<key>CFBundleExecutable</key><string>Iris</string>\n<key>CFBundleIdentifier</key><string>com.codycherrington.iris</string>\n<key>CFBundlePackageType</key><string>APPL</string>\n<key>CFBundleIconFile</key><string>AppIcon</string>\n<key>NSMicrophoneUsageDescription</key><string>Iris uses the microphone only if you enable voice input.</string>\n<key>CFBundleShortVersionString</key><string>$(VERSION)</string>\n<key>CFBundleVersion</key><string>$(BUILD)</string>\n<key>LSMinimumSystemVersion</key><string>26.0</string>\n<key>NSHighResolutionCapable</key><true/>\n<key>NSSupportsAutomaticTermination</key><true/>\n</dict></plist>
endef
export INFO_PLIST

.DEFAULT_GOAL := help

.PHONY: help build test clean scratch-path fixtures harness bench app run icon install uninstall

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
	@cp "$(ICON)" "$(APP)/Contents/Resources/AppIcon.icns"
	@printf '%b\n' "$$INFO_PLIST" > "$(APP)/Contents/Info.plist"
	@echo "APPL????" > "$(APP)/Contents/PkgInfo"
# Ad-hoc signature. Not a Developer ID — this isn't for distribution, it's so macOS treats
# the bundle as a real app: without any signature, TCC has nothing stable to attach a
# microphone or automation grant to.
	@codesign --force --sign - --timestamp=none "$(APP)" >/dev/null 2>&1 \
		&& echo "signed (ad-hoc)" || echo "warning: codesign failed; app still runnable"
	@echo "built $(APP)"

run: app ## Build and launch Iris.app
	@open "$(APP)"

icon: ## Regenerate Resources/AppIcon.icns from the design tokens
	@swift tools/make-icon.swift Resources
	@iconutil -c icns Resources/Iris.iconset -o $(ICON)
	@echo "wrote $(ICON)"

install: ## Build a release copy and install it to /Applications
	@$(MAKE) --no-print-directory app CONFIG=release
# Quit a running copy first: replacing the bundle underneath a live process leaves it
# running against files that no longer exist.
	@osascript -e 'quit app "Iris"' >/dev/null 2>&1 || true
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP)" "$(INSTALLED)"
# Nudge Launch Services so Spotlight and the Dock pick up the new bundle and its icon
# immediately rather than whenever they next rescan.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(INSTALLED)" >/dev/null 2>&1 || true
	@echo "installed $(INSTALLED) — open it from Spotlight, Launchpad or /Applications"

uninstall: ## Remove Iris from /Applications
	@osascript -e 'quit app "Iris"' >/dev/null 2>&1 || true
	@rm -rf "$(INSTALLED)"
	@echo "removed $(INSTALLED)"

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
