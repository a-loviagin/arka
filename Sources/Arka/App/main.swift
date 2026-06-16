#if os(macOS)
import AppKit
import SwiftUI

// Explicit NSApplication bootstrap rather than `@main struct App` so a plain `swift run Arka`
// reliably shows an activated window with a menu (no app bundle / Info.plist required).

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let document = DemoDocument.make()
        let content = ContentView(document: document)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Arka — Demo"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Top-level executable code runs on the main thread at process start.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    buildMainMenu(app)
    app.run()
}

/// Minimal main menu so ⌘Q and standard window commands work when launched as a bare binary.
@MainActor
func buildMainMenu(_ app: NSApplication) {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Arka", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    app.mainMenu = mainMenu
}
#endif
