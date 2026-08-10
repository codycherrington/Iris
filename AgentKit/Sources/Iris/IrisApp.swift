import AppKit
import SwiftUI

@main
struct IrisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Iris", id: "main") {
            GlassContentView()
                // Committed to one dark, near-black look rather than following system
                // appearance — see the comment on Tok.Palette.
                .preferredColorScheme(.dark)
                .background(WindowChrome())
        }
        .defaultSize(width: 900, height: 660)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Liquid Glass needs the content to run under the titlebar, otherwise there's an opaque
/// strip across the top that the material can't refract through.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Off, deliberately. With it on, AppKit treats a drag starting anywhere that isn't a
        // control as a window move — which means dragging across a message to select it moves
        // the window instead, and there is no way for the text view to win, because the
        // decision is made before the drag is recognised as a selection. Dragging is confined
        // to `WindowDragStrip` at the top of the content instead.
        window.isMovableByWindowBackground = false
        // Off by default. Without it the window never dispatches mouseMoved, so the
        // backdrop's pointer-lean monitor would sit silent.
        window.acceptsMouseMovedEvents = true
        // The SwiftUI content paints the backdrop; an opaque window background would sit
        // on top of it and flatten the glass.
        window.backgroundColor = .clear
        window.isOpaque = false
    }
}

/// The one region where a drag moves the window.
///
/// `isMovableByWindowBackground` is the usual way to do this and is the wrong tool here: it
/// grants the whole window, so it collides with every drag gesture the content wants —
/// selecting transcript text most obviously. AppKit asks the view under the pointer whether
/// a drag starting there should move the window, so scoping it is a matter of answering that
/// question in one small view and nowhere else.
///
/// Placed *behind* the strip's contents rather than over them, so a button sitting in the
/// strip still gets its own clicks; only the empty space around it drags.
struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// Launched from a SwiftPM-built bundle, AppKit doesn't reliably promote the process to a
/// foreground app — without this the window can open behind everything and never take focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
