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

## Fusion is punctuation, not a layout mode (learned 2026-08-08)

The paragraph above is still true and was still, in practice, over-applied. Two corrections
from building the real transcript, both partially reversing how Phase 3 used these APIs:

**`GlassEffectContainer(spacing:)` fuses *every* sibling pair within that distance — it is not
a gap or a padding value.** `Tok.Fusion.transcript` was `26`, chosen as if it were spacing. The
moment a message turn became more than one glass shape (tool chips above, answer bubble below)
those two welded into a single blob with a visible glass tail strung between them. It is now
**`0`**, with the reason recorded in the token itself. If two glass shapes must read as
separate, the container spacing between them has to be `0` — there is no "close but distinct."

**`glassEffectUnion` destroys countability.** `ToolChip` shared a `"tools-pending"` union id so
unresolved calls would fuse and split apart as they resolved. It looked excellent and made a
run of tool calls unreadable as distinct steps — you could not tell three actions from one.
The union was removed; each chip is now its own shape.

The rule that came out of it: **fuse things that are genuinely one control, never things the
user needs to count or read separately.** Fusion survives in Iris exactly where it earns its
place — the composer field and its send button share `GlassID.composerCluster` and read as one
piece of liquid, because they *are* one control. Everything in the transcript is information,
and information wants edges.

A related non-API lesson from the same session: a separate animated element beside static
content reads as a spinner bolted onto the glass. A sweeping-capsule `StreamingPulse` was
replaced by dimming the existing label to 35% on a 1.2 s ease (`Breathing` in
`GlassMessageViews.swift`). When the glass is already the visual interest, adding a second
moving object subtracts. Group co-animated elements under one modifier, too — driven
separately, a label and its dot drift out of phase.

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
