# Liquid Glass API surface (macOS 26)

Verified 2026-08-07 against the Xcode 26.5 SDK on macOS 26.5.

## Where it actually lives

**Not in `SwiftUI.framework`.** That module only exposes the button styles:

```
GlassButtonStyle, GlassProminentButtonStyle, glassProminent, glassEffectOverlay
```

The real API is in **`SwiftUICore`**, and the path has a `Versions/A` component that's easy to
miss when grepping:

```
$(xcrun --show-sdk-path)/System/Library/Frameworks/SwiftUICore.framework/
  Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface
```

Note the arch is **`arm64e`**, not `arm64`. Two earlier greps returned empty because of these
two details and nearly produced a wrong "Liquid Glass isn't available" conclusion. An empty
grep is not evidence of absence.

## Surface

```swift
// availability: macOS 26.0+
func glassEffect(_ glass: Glass = .regular,
                 in shape: some Shape = DefaultGlassEffectShape()) -> some View
func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
func glassEffectTransition(_ transition: GlassEffectTransition) -> some View

struct GlassEffectContainer<Content: View>: View
struct DefaultGlassEffectShape
struct Glass                    // .regular, .interactive(), …
```

Plus `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` from `SwiftUI` (macOS 26.1+ for
some members).

## Why this shapes Iris's animation language

`glassEffect` alone is a material. The *morphing* — shapes merging and splitting fluidly, with
refraction tracking the motion — comes from combining three things:

1. a `GlassEffectContainer` wrapping the region,
2. `@Namespace` + `.glassEffectID(_:in:)` on each element, and
3. `.glassEffectUnion(id:namespace:)` to fuse elements that should read as one blob.

That's the vocabulary for the sidebar-into-composer merge and tool cards coalescing into a
result — the effects that make Iris look unlike a normal chat window. Treat these as the
primary tool, not decoration layered on afterwards.

## Practical notes

- Set the deployment target to macOS 26 for the app; `AgentKit` itself is UI-free and targets
  macOS 15 so it stays testable on older toolchains.
- Honor `accessibilityReduceMotion` — glass morphing is exactly the kind of motion that needs
  a reduced path.
- Verify in both light and dark, and over a busy desktop background: glass reads very
  differently against a photo than against a flat colour.

## Toolchain (verified)

```
xcrun --show-sdk-version   → 26.5
swift --version            → 6.3.3, target arm64-apple-macosx26.0
```
