#if os(macOS)
import AppKit
import SwiftUI
import Metal
import MotionKernel
import MotionRender

// Explicit NSApplication bootstrap rather than `@main struct App` so a plain `swift run Arka`
// reliably shows an activated window with a menu (no app bundle / Info.plist required).

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var document = DemoDocument.make()

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        buildMainMenu(target: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// File ▸ Export Movie… — render the demo comp to an H.264 .mp4 via the offscreen export path.
    @objc func exportMovie(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "arka-demo.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let doc = document // value type, Sendable
        DispatchQueue.global(qos: .userInitiated).async {
            // Build everything inside the background closure so no non-Sendable state is captured.
            guard let device = MTLCreateSystemDefaultDevice(),
                  let renderer = try? MetalRenderer(device: device),
                  let comp = doc.mainComposition else { return }
            let cache = TextureCache(device: device)
            cache.register(id: DemoDocument.logoAssetId, cgImage: DemoDocument.makeLogoImage())
            let exporter = VideoExporter(renderer: renderer, textures: cache)
            do {
                try exporter.export(document: doc, compId: comp.id,
                                    settings: .standard(for: comp), to: url)
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export failed"
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
    }
}

// Top-level executable code runs on the main thread at process start.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

/// Minimal main menu: app (Quit) + File (Export Movie…). Built once the delegate exists so the
/// export item can target it.
@MainActor
func buildMainMenu(target: AppDelegate) {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Arka", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    let export = NSMenuItem(title: "Export Movie…", action: #selector(AppDelegate.exportMovie(_:)), keyEquivalent: "e")
    export.target = target
    fileMenu.addItem(export)
    fileItem.submenu = fileMenu

    NSApp.mainMenu = mainMenu
}
#endif
