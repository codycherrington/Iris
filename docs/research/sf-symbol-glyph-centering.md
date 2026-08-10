# SF Symbol centering: the correction was the bug

**Status: this note's original conclusion was wrong and is preserved below as a record.**
Written 2026-08-08, refuted 2026-08-09 by measurement (`c428a81`), then a *second*, unrelated
cause was found and fixed the same evening (`3a48e41`).

Short version, for anyone who only reads the first paragraph:

> `arrow.up` at 15 pt semibold in a 42 pt frame measures **exactly `(0.000, 0.000)`** — dead
> centre. Every SF Symbol Iris uses lands within **±0.125 pt** of centre. The
> `.offset(x: -1, y: -1)` this note recommended was not correcting an off-centre glyph; it was
> **creating** one. And when the arrow *did* visibly drift, the cause was `.scaleEffect` around
> `.glassEffect`, not the glyph at all.

---

## What the original note claimed (2026-08-08)

Recorded verbatim in substance, because a refuted claim is only useful if you can see what was
believed and why it was convincing.

`SendButton` renders `arrow.up` (idle) or `stop.fill` (busy) in a fixed 42×42 frame. Commit
`95673a9` had removed a per-glyph `.offset(y: -1)` nudge on the theory that a correctly-sized
square frame would centre the glyph. After the removal the arrow still *looked* low and to the
right, confirmed against a live screenshot.

The explanation reached for was:

> An SF Symbol's rendered ink is not necessarily centered within its own design bounding box …
> `arrow.up` is one of several SF Symbols where the visible stroke doesn't sit dead-center in its
> own metrics.

with `stop.fill` — symmetric, needing no correction — offered as the contrast case that proved
it was per-symbol rather than general. The fix was `.offset(x: -1, y: -1)` applied only to
`arrow.up`, and the note's own heading called it *"the fix, and why it's not a real fix"*: an
eyeballed correction for one glyph at one size and weight.

The takeaway it left behind was **"check the rendered result against a screenshot rather than
assuming."**

That takeaway is what kept the error alive for a day. Checking against a screenshot is how the
offset got there in the first place.

---

## Measuring it: three attempts, two of them wrong

### Attempt 1 — rasterize `NSImage(systemSymbolName:)` ❌ buggy

Reported every symbol at roughly **box/4** off-centre. Caught in minutes, because `stop.fill` is
a symmetric filled square and **must** measure zero — a known-answer control case.

The bug: drawing at *point* size into a bitmap sized in *pixels* at 2×, so the glyph occupied the
bottom-left quadrant and every measurement was really measuring the empty space around it.

> **The reusable lesson is this one, not the centering.** Include a case whose correct answer you
> already know. Without `stop.fill` in the loop, attempt 1 would have produced a table of
> confident wrong numbers, and the numbers were large enough to look meaningful.

### Attempt 2 — fix the draw rect ❌ right method, wrong question

`arrow.up` → `(+0.25, 0)`. `stop.fill` → exactly `(0, 0)`.

This looked like clean corroboration of the 2026-08-08 story: asymmetric glyph, symmetric
control, small offset. It is still the wrong measurement.

**`Image(systemName:)` does not draw an image.** It lays the symbol out as a **glyph on a text
baseline**, inside a line box derived from the font's ascender and descender. Rasterizing
`NSImage(systemSymbolName:)` answers "is the ink centred within the symbol's *image* bounds",
which is a different box that SwiftUI never uses for this.

### Attempt 3 — rasterize the SwiftUI view ✅

`ImageRenderer` over the actual view — `Image(systemName:).font(.system(size:weight:)).frame(…)`
— at 4× scale, then scan the alpha channel for the ink's bounding box and compare its centre
against the frame's centre. This measures the real pipeline, font metrics included.

```swift
let renderer = ImageRenderer(content: content)
renderer.scale = 4          // a quarter-point of asymmetry is still a whole pixel to find
…
guard raw[(y * width + x) * 4 + 3] > 32 else { continue }   // skip the AA fringe
```

The alpha threshold matters: antialiasing is softer on some edges than others, and including the
fringe biases the bounding box toward whichever side blurs more.

**Results, 42 pt frame, 15 pt semibold:**

| symbol | measured offset from frame centre |
|---|---|
| `arrow.up` | **(0.000, 0.000)** |
| `stop.fill` | (0.000, 0.000) |
| every other symbol in the app | within **±0.125 pt** |

So the premise of the original note was false. `arrow.up` is not asymmetric in the box SwiftUI
lays it out in, and the hand-tuned `-1, -1` was pushing a centred glyph up and left by a full
point — roughly **eight times** the largest genuine asymmetry anywhere in the app.

### Why `SymbolInk` keeps measuring instead of hardcoding zero

Two reasons, both in `AgentKit/Sources/Iris/SymbolInk.swift`:

- A computed zero is worth more than a hardcoded one. It stays correct if a future symbol, size
  or weight genuinely is asymmetric.
- It carries a **threshold**:

  ```swift
  /// Below this, a correction is measurement noise rather than a real asymmetry, and
  /// applying it would only push the glyph onto a fractional pixel and blur it.
  private static let threshold: CGFloat = 0.25
  ```

  A sub-quarter-point offset is snapped to zero. Applying a "more accurate" fractional offset
  lands the stroke off the pixel grid and renders **worse** than not correcting at all. Accuracy
  and sharpness are in tension below half a pixel.

Measurements are cached per (name, pointSize, weight, side). Use `CenteredSymbol` rather than
`Image(systemName:).frame(…)` for any icon-only control, so the centering claim is computed
rather than asserted.

---

## The second cause, which had nothing to do with glyphs (2026-08-09 evening, `3a48e41`)

After the offset was removed, the arrow was **still visibly off — but only before typing.**

Both states were screenshotted from the running app and measured directly (find the white glyph,
scan outward to the glass circle's edge, compare centres):

| state | glass circle | arrow offset from *circle* centre |
|---|---|---|
| empty, `.scaleEffect(0.9)` | 36 pt | **+1.75 pt right, +2.25 pt down** |
| with text, scale 1.0 | 39 pt | +0.00, +0.50 pt |

**First hypothesis, tested and wrong:** scaling a 42 pt button by 0.9 gives 37.8 pt, so the glyph
lands on a fractional pixel. Rendering the glyph alone under the same 0.9 scale moves it
**0.062 pt** — about 36× too small to explain 2.25 pt.

**Actual cause:** the arrow and the glass circle **do not scale about the same point**.
`.scaleEffect` sat outside `.glassEffect` in the modifier chain, and the two resolve against
different geometry, so the content slides within the shape. Nothing about the glyph moves; the
*shape around it* does.

**Fix — express the size change as a frame, not a transform:**

```swift
private var side: CGFloat { hasText || isBusy ? 42 : 38 }
```

38 → 42, both whole points, with the animation driven by `value: side`. Content and glass stay
in one geometry, and both resting sizes are on the pixel grid. `CenteredSymbol` measures for
whichever side is in use; both measure exactly zero.

This finding is about Liquid Glass, not SF Symbols — it is also recorded in
`liquid-glass-api.md`.

---

## What to actually do

1. **Don't hand-nudge a glyph.** If it looks off-centre, measure it through `ImageRenderer` on
   the real view. `SymbolInk` already does this and caches.
2. **Measure the thing SwiftUI renders**, not an `NSImage` of the same symbol. Text layout and
   image layout use different boxes.
3. **Always include a control case with a known answer** (`stop.fill` measures zero). Two of the
   three attempts above were thrown out by it.
4. **If a glass control changes size, animate the frame, not `.scaleEffect`.** A transform around
   `.glassEffect` decouples the content from the shape.
5. **Ignore corrections under ~0.25 pt.** Below that you are trading sharpness for arithmetic.
6. **A screenshot is evidence that something is wrong, never evidence of what.** Every wrong
   conclusion in this note's history came from reading a cause off an image.
