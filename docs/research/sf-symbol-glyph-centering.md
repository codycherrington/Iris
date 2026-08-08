# SF Symbols: ink offset persists regardless of frame size

Observed 2026-08-08 in `SendButton` (`GlassContentView.swift`).

## The mistake

`SendButton` renders `arrow.up` (idle) or `stop.fill` (busy) inside a fixed 42×42 frame — 42pt
chosen to match the composer text field's row height so the two controls read as one row.
Commit `95673a9` removed a per-glyph `.offset(y: -1)` nudge that had been on `arrow.up`, on the
theory that giving the glyph a properly-sized square frame would center it without any manual
correction — the frame mismatch looked like the obvious cause of the earlier off-center look.

It wasn't. After the removal, the arrow still rendered visibly low and to the right inside the
circular button, confirmed against a live screenshot Cody took of the running app.

## What's actually going on

An SF Symbol's rendered ink is not necessarily centered within its own design bounding box.
`Image(systemName:)` sizes and positions the glyph inside whatever frame you give it, but the
glyph's *visual weight* inside that box is fixed by the symbol itself — resizing or
repositioning the frame moves the box, not the ink's position within it. `arrow.up` is one of
several SF Symbols where the visible stroke doesn't sit dead-center in its own metrics: the
mistake in `95673a9` was reasoning "the frame is now correctly sized, so the glyph must be
centered" — frame size and ink centering are unrelated properties.

Confirmed contrast case in the same button: `stop.fill` (a filled square) *is* symmetric and
needed no correction at any frame size. So this isn't a property of `Image(systemName:)` or of
frames in general — it's specific to which symbol you're using.

## The fix, and why it's not a real fix

Reintroduced a small counter-offset, applied only to the asymmetric glyph:

```swift
Image(systemName: isBusy ? "stop.fill" : "arrow.up")
    .font(.system(size: 15, weight: .semibold))
    .foregroundStyle(.white)
    .offset(x: isBusy ? 0 : -1, y: isBusy ? 0 : -1)
    .frame(width: 42, height: 42)
```

This is a manual, eyeballed correction for one glyph at one point size and weight — not a
general solution. If the point size, weight, or symbol changes, the offset will need
re-checking against a real screenshot, not assumed to still be correct.

## Takeaway for future glyph-in-circle buttons

Before adding or resizing any icon-only circular button (the interrupt/stop control, any future
toolbar icon), check the rendered result against a screenshot rather than assuming a
correctly-sized frame is sufficient. "The frame matches the sibling control's size" and "the
glyph is visually centered in that frame" are independent claims — SF Symbols do not guarantee
the second given the first.
