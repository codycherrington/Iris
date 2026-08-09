import AppKit
import SwiftUI

/// The composer's text field, wrapping `NSTextView` directly.
///
/// `TextEditor` was doing the job, but it hides the two insets that decide where the first
/// glyph lands — `NSTextView.textContainerInset` and `NSTextContainer.lineFragmentPadding`
/// (5pt by default) — so every alignment correction against it is a guess measured from a
/// screenshot. That's how the composer ended up with `minHeight: 20` next to a placeholder
/// nudged by `.padding(.leading, 7)`: two numbers tuned by eye to cancel out insets nobody
/// could see or reach.
///
/// Owning the text view removes the guesswork rather than re-tuning it:
///
/// - **Both insets are zeroed**, so the text origin *is* the view origin. The placeholder
///   overlay then needs no offset at all — it aligns by construction, because it's drawn in
///   the same coordinate space at the same font.
/// - **Height is the measured layout height**, floored at exactly one line as reported by
///   the font's own metrics. The old `minHeight: 20` was ~4pt taller than a 13.5pt line, and
///   because the text sat at the top of that box, all the slack fell underneath — which is
///   precisely why the text looked high in the capsule. With the frame matching the line,
///   there's no slack to distribute and the symmetric vertical padding does the centering.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let font: NSFont
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    let onEscape: () -> Void

    /// One line, straight from the typeface. This is the number `minHeight` should always
    /// have been.
    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(Tok.Palette.agent)
        // The whole point of this type.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.documentView = textView

        // Focus on open. The composer is the one control the window exists for.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        // Only write when it actually differs: assigning `string` collapses the selection,
        // so doing it every update pass would fight the caret on every keystroke.
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        context.coordinator.recalculateHeight(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)

            let line = ComposerTextView.lineHeight(for: parent.font)
            let used = ceil(layoutManager.usedRect(for: container).height)
            // An empty text view lays out to zero, not to one line — floor it so the
            // composer doesn't collapse when you clear it.
            let next = min(max(used, line), parent.maxHeight)

            guard abs(next - parent.height) > 0.5 else { return }
            // Deferred: this runs inside SwiftUI's update pass, and writing state there
            // warns and can loop.
            DispatchQueue.main.async { [parent] in
                parent.height = next
            }
        }
    }
}

/// `keyDown` rather than `doCommandBy(_:)`: the delegate callback doesn't carry modifier
/// flags, so there's no way to tell ⌘↵ from ↵ inside it — and plain ↵ has to keep inserting
/// a newline.
final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    private enum Key {
        static let ret: UInt16 = 36
        static let escape: UInt16 = 53
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Key.ret, event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        if event.keyCode == Key.escape {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
