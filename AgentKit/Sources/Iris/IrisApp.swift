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
        window.isMovableByWindowBackground = true
        // The SwiftUI content paints the backdrop; an opaque window background would sit
        // on top of it and flatten the glass.
        window.backgroundColor = .clear
        window.isOpaque = false
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
