import AppKit
import SwiftUI

@main
struct IrisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Iris", id: "main") {
            ContentView()
        }
        .defaultSize(width: 820, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Running from a SwiftPM-built bundle, AppKit doesn't always promote the process to a
/// regular foreground app on its own — without this the window can open behind everything
/// and never take focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
