#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Metal
import MotionKernel
import MotionRender

// Explicit NSApplication bootstrap rather than `@main struct App` so a plain `swift run Arka`
// reliably shows an activated window with a menu (no app bundle / Info.plist required).

let motionType = UTType(filenameExtension: "motion") ?? .package

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let model = DocumentModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Arka"
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        buildMainMenu(target: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: File menu actions

    @objc func savePackage(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [motionType]
        panel.nameFieldStringValue = "Untitled.motion"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.save(to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { presentError(error) }
    }

    @objc func openPackage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [motionType]
        panel.canChooseDirectories = true // .motion is a package directory in v1
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.open(url) } catch { presentError(error) }
    }

    /// Shared export plumbing: prompt for a destination, then run `work` off the main thread
    /// (building its own renderer so nothing non-Sendable is captured), revealing the result.
    private func runExport(suggestedName: String, contentTypes: [UTType],
                           _ work: @escaping @Sendable (MotionDocument, MetalRenderer, TextureCache, Composition, URL) throws -> Void) {
        let panel = NSSavePanel()
        if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let doc = model.document
        DispatchQueue.global(qos: .userInitiated).async {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let renderer = try? MetalRenderer(device: device),
                  let comp = doc.mainComposition else { return }
            let cache = TextureCache(device: device)
            cache.register(id: DemoDocument.logoAssetId, cgImage: DemoDocument.makeLogoImage())
            do {
                try work(doc, renderer, cache, comp, url)
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    let alert = NSAlert(); alert.messageText = "Export failed"
                    alert.informativeText = message; alert.runModal()
                }
            }
        }
    }

    @objc func exportMovie(_ sender: Any?) {
        runExport(suggestedName: "arka.mp4", contentTypes: [.mpeg4Movie]) { doc, renderer, cache, comp, url in
            try VideoExporter(renderer: renderer, textures: cache)
                .export(document: doc, compId: comp.id, settings: .standard(for: comp), to: url)
        }
    }

    @objc func exportProRes(_ sender: Any?) {
        runExport(suggestedName: "arka.mov", contentTypes: [.quickTimeMovie]) { doc, renderer, cache, comp, url in
            try VideoExporter(renderer: renderer, textures: cache)
                .export(document: doc, compId: comp.id, settings: .proResAlpha(for: comp), to: url)
        }
    }

    @objc func exportGIF(_ sender: Any?) {
        runExport(suggestedName: "arka.gif", contentTypes: [.gif]) { doc, renderer, cache, comp, url in
            try GIFExporter.export(document: doc, compId: comp.id, renderer: renderer, textures: cache,
                                   width: Int(comp.size.x), height: Int(comp.size.y), fps: 25,
                                   startTime: 0, endTime: comp.duration, to: url)
        }
    }

    @objc func exportPNGSequence(_ sender: Any?) {
        runExport(suggestedName: "arka-frames", contentTypes: []) { doc, renderer, cache, comp, url in
            try ImageSequenceExporter.export(document: doc, compId: comp.id, renderer: renderer, textures: cache,
                                             width: Int(comp.size.x), height: Int(comp.size.y), fps: comp.fps,
                                             startTime: 0, endTime: comp.duration, transparent: true, to: url)
        }
    }

    @objc func undo(_ sender: Any?) { model.store.undo() }
    @objc func redo(_ sender: Any?) { model.store.redo() }
    @objc func deleteKeyframe(_ sender: Any?) { model.deleteSelectedKeyframe() }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Operation failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
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

/// App (Quit) + File (Open / Save Package / Export Movie). Built once the delegate exists so the
/// items can target it.
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
    func add(_ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        fileMenu.addItem(item)
    }
    add("Open…", #selector(AppDelegate.openPackage(_:)), "o")
    add("Save Package…", #selector(AppDelegate.savePackage(_:)), "s")
    fileMenu.addItem(.separator())
    add("Export Movie…", #selector(AppDelegate.exportMovie(_:)), "e")
    add("Export ProRes (Alpha)…", #selector(AppDelegate.exportProRes(_:)), "")
    add("Export GIF…", #selector(AppDelegate.exportGIF(_:)), "")
    add("Export PNG Sequence…", #selector(AppDelegate.exportPNGSequence(_:)), "")
    fileItem.submenu = fileMenu

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    let undo = NSMenuItem(title: "Undo", action: #selector(AppDelegate.undo(_:)), keyEquivalent: "z")
    undo.target = target
    editMenu.addItem(undo)
    let redo = NSMenuItem(title: "Redo", action: #selector(AppDelegate.redo(_:)), keyEquivalent: "Z")
    redo.target = target
    editMenu.addItem(redo)
    editMenu.addItem(.separator())
    let del = NSMenuItem(title: "Delete Keyframe",
                         action: #selector(AppDelegate.deleteKeyframe(_:)),
                         keyEquivalent: "\u{8}") // ⌫
    del.keyEquivalentModifierMask = []
    del.target = target
    editMenu.addItem(del)
    editItem.submenu = editMenu

    NSApp.mainMenu = mainMenu
}
#endif
