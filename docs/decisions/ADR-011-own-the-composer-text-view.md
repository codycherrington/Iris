# ADR-011 — Own the composer's `NSTextView` instead of styling `TextEditor`

**Date:** 2026-08-09 · **Status:** accepted · **Commit:** `c428a81`

## Context

Cody: *"the text in the text box is a little high in the chat bar. Align it correctly, not just
by adjusting pixels, but the correct way."*

He was right that it was pixel-tuning, and right that it had happened more than once. The
composer had accumulated two magic numbers:

```swift
.frame(minHeight: 20, maxHeight: 132)      // why 20?
…
Text("Message Iris…").padding(.leading, 7) // why 7?
```

Neither number describes anything. Both were arrived at by looking at a screenshot and adjusting
until it looked right, and both existed to cancel out insets that `TextEditor` does not expose:

- **`NSTextView.textContainerInset`** — unreachable through `TextEditor`.
- **`NSTextContainer.lineFragmentPadding`** — defaults to 5 pt, unreachable, and the reason the
  placeholder needed a leading nudge to sit where the real caret sat.

`.textEditorStyle(.plain)` and `.contentMargins(.all, 0, for: .scrollContent)` were already
applied and did not remove them.

The vertical symptom had a specific cause. One line of `Font.system(size: 13.5)` measures
`ceil(ascender - descender + leading)` ≈ **16 pt**. The frame forced a 20 pt floor, and the text
view lays its content out from the top, so all ~4 pt of slack fell *underneath* the line. Symmetric
`.padding(.vertical, 11)` then centred a box whose content wasn't centred within it — the text sat
about 2 pt high in the capsule, exactly as reported.

## Decision

**Wrap `NSTextView` directly in `ComposerTextView: NSViewRepresentable`, and zero both insets.**

```swift
textView.textContainerInset = .zero
textView.textContainer?.lineFragmentPadding = 0
```

With the text origin equal to the view origin, the two magic numbers stop existing rather than
being retuned:

- The placeholder overlay needs **no offset at all**. It is drawn in the same coordinate space at
  the same font, so it aligns by construction.
- Height is the measured layout height (`layoutManager.usedRect(for:)`), floored at one line
  computed from the font's own metrics. There is no slack, so the vertical padding does the
  centring exactly.

Key handling moved to a `keyDown` override, because `NSTextViewDelegate.textView(_:doCommandBy:)`
carries no modifier flags — there is no way to distinguish ⌘↵ from ↵ inside it, and plain ↵ must
keep inserting a newline.

## Alternatives considered

**Retune the numbers.** Measure the true line height, use it for `minHeight`, and set the
placeholder's leading to `lineFragmentPadding`'s documented 5 pt. Cheaper, and it would probably
have looked right. Rejected because the observed correct value was 7, not 5 — meaning something
else contributes ~2 pt that we still couldn't see or name. Landing on "looks right" without being
able to explain the number is how the original 7 got there.

**Keep `TextEditor` and compensate with negative padding.** Same objection, worse: it hides the
mismatch instead of removing it, and the compensation silently rots when the font changes.

**Reach into `TextEditor`'s underlying `NSTextView`** by walking the view hierarchy at runtime.
Rejected: undocumented, order-dependent, and breaks silently on any SwiftUI internal change —
the worst combination for something this visible.

## Consequences

- **Both magic numbers are gone**, not adjusted. Line height derives from `NSFont` metrics, so
  changing `Tok.TypeScale.body` changes the composer correctly with no re-tuning.
- **More surface owned.** Focus, auto-grow, undo, background, caret colour and key handling are
  now Iris's responsibility. Focus-on-launch moved out of `@FocusState` into
  `makeFirstResponder`, and `@FocusState private var composerFocused` was removed.
- **Height writes are deferred** (`DispatchQueue.main.async`) because recalculation runs inside
  SwiftUI's update pass, where writing state warns and can loop.
- **`string` is only assigned when it differs.** Assigning collapses the selection, so writing it
  on every update pass would fight the caret on every keystroke.
- **Untested.** `ComposerTextView` is `@MainActor` UI in the `Iris` target, which the test target
  cannot import — the same structural gap noted in ADR-009. The behaviour that matters (one line
  of 13.5 pt text is ~16 pt) is a font-metric fact, but nothing pins it.
- Set against the cost: this is the second time in one day a visible alignment defect turned out
  to be a *correction* fighting an invisible constant rather than a genuine misalignment. The
  other was the send arrow — see `sf-symbol-glyph-centering.md`. Removing the invisible constant
  is what both fixes have in common.
