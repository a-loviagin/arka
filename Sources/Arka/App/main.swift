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

        model.runExport = { [weak self] settings in self?.runExportJob(settings) }
        buildMainMenu(target: self)
        NSApp.activate(ignoringOtherApps: true)

        // Crash recovery: a leftover autosave means the last session didn't quit cleanly — reopen it.
        if model.recoverIfNeeded() { window.title = "Arka — Recovered" }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model.clearRecovery() // clean exit ⇒ no recovery on next launch
    }

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

    /// Open the preset-first export sheet (export-and-format.md §3).
    @objc func showExportSheet(_ sender: Any?) { model.exportSheetVisible = true }

    /// Run one export job from the sheet's settings: prompt for a destination, then render off the
    /// main thread (building its own renderer so nothing non-Sendable is captured) and reveal it.
    func runExportJob(_ settings: ExportSettings) {
        let panel = NSSavePanel()
        if !settings.format.contentTypes.isEmpty { panel.allowedContentTypes = settings.format.contentTypes }
        panel.nameFieldStringValue = settings.format.suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let doc = model.document
        let compId = model.activeCompId
        let baseURL = model.assetBaseURL
        DispatchQueue.global(qos: .userInitiated).async {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let renderer = try? MetalRenderer(device: device),
                  let comp = doc.composition(compId) ?? doc.mainComposition else { return }
            let cache = TextureCache(device: device)
            cache.register(id: DemoDocument.logoAssetId, cgImage: DemoDocument.makeLogoImage())
            let video = VideoFrameProvider(device: device)
            let w = max(Int(comp.size.x * settings.scale), 1)
            let h = max(Int(comp.size.y * settings.scale), 1)
            let fps = max(settings.fps, 1)
            do {
                switch settings.format {
                case .mp4, .proRes:
                    let codec: VideoExporter.Settings.Codec = settings.format == .proRes ? .proRes4444 : .h264
                    let vs = VideoExporter.Settings(width: w, height: h, fps: fps, startTime: 0,
                                                    endTime: comp.duration, codec: codec,
                                                    transparentBackground: settings.format == .proRes && settings.transparent)
                    try VideoExporter(renderer: renderer, textures: cache, video: video, assetBaseURL: baseURL)
                        .export(document: doc, compId: comp.id, settings: vs, to: url)
                case .gif:
                    try GIFExporter.export(document: doc, compId: comp.id, renderer: renderer, textures: cache,
                                           video: video, assetBaseURL: baseURL, width: w, height: h, fps: fps,
                                           startTime: 0, endTime: comp.duration, to: url)
                case .webP:
                    try WebPExporter.export(document: doc, compId: comp.id, renderer: renderer, textures: cache,
                                            video: video, assetBaseURL: baseURL, width: w, height: h, fps: fps,
                                            startTime: 0, endTime: comp.duration, transparent: settings.transparent, to: url)
                case .pngSequence:
                    try ImageSequenceExporter.export(document: doc, compId: comp.id, renderer: renderer, textures: cache,
                                                     video: video, assetBaseURL: baseURL, width: w, height: h, fps: fps,
                                                     startTime: 0, endTime: comp.duration, transparent: settings.transparent, to: url)
                }
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

    /// Lottie is a document→document translation (no renderer), so it has its own simple handler:
    /// write the JSON, then surface the compatibility lint if anything didn't map cleanly.
    @objc func exportLottie(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "arka.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try LottieExporter.export(model.document, compId: model.activeCompId,
                                                   assetData: model.assetBytes)
            try result.json.write(to: url)
            if result.warnings.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                let alert = NSAlert()
                alert.messageText = "Exported with \(result.warnings.count) compatibility warning\(result.warnings.count == 1 ? "" : "s")"
                alert.informativeText = result.warnings.prefix(12).joined(separator: "\n")
                alert.addButton(withTitle: "Reveal in Finder")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Lottie export failed"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    @objc func toggleAIPanel(_ sender: Any?) { model.aiPanelVisible.toggle() }
    @objc func showTasteSheet(_ sender: Any?) { model.tasteSheetVisible = true }

    /// Paste an image from the clipboard onto the canvas as an editable image layer.
    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // SVG markup on the clipboard → editable vector layers.
        if let str = pb.string(forType: .string),
           str.contains("<svg"), let data = str.data(using: .utf8) {
            model.importSVG(data: data); return
        }
        if let data = pb.data(forType: .png) {
            model.importImage(data: data, fileExtension: "png"); return
        }
        // Most apps put images on the board as TIFF — transcode to PNG for our pipeline.
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let img = images.first,
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            model.importImage(data: png, fileExtension: "png")
        }
    }

    @objc func undo(_ sender: Any?) { model.store.undo() }
    @objc func redo(_ sender: Any?) { model.store.redo() }

    // Insert
    @objc func insertRectangle(_ sender: Any?) { model.createLayerAtCenter(.rect) }
    @objc func insertEllipse(_ sender: Any?) { model.createLayerAtCenter(.ellipse) }
    @objc func insertText(_ sender: Any?) { model.createLayerAtCenter(.text) }
    @objc func duplicateSelection(_ sender: Any?) { model.duplicateSelectedLayers() }
    @objc func groupSelection(_ sender: Any?) { model.groupSelection() }
    @objc func ungroupSelection(_ sender: Any?) { model.ungroupSelection() }

    /// ⌫ is context-aware: delete the selected keyframe if one is picked, else the selected layer(s).
    @objc func deleteSelection(_ sender: Any?) {
        if model.selectedKeyframe != nil { model.deleteSelectedKeyframe() }
        else { model.deleteSelectedLayers() }
    }

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
    add("Export…", #selector(AppDelegate.showExportSheet(_:)), "e")
    add("Export Lottie (JSON)…", #selector(AppDelegate.exportLottie(_:)), "")
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
    let dup = NSMenuItem(title: "Duplicate",
                         action: #selector(AppDelegate.duplicateSelection(_:)), keyEquivalent: "d")
    dup.target = target
    editMenu.addItem(dup)
    let group = NSMenuItem(title: "Group",
                           action: #selector(AppDelegate.groupSelection(_:)), keyEquivalent: "g")
    group.target = target
    editMenu.addItem(group)
    let ungroup = NSMenuItem(title: "Ungroup",
                             action: #selector(AppDelegate.ungroupSelection(_:)), keyEquivalent: "G")
    ungroup.target = target
    editMenu.addItem(ungroup)
    let del = NSMenuItem(title: "Delete",
                         action: #selector(AppDelegate.deleteSelection(_:)),
                         keyEquivalent: "\u{8}") // ⌫
    del.keyEquivalentModifierMask = []
    del.target = target
    editMenu.addItem(del)
    editMenu.addItem(.separator())
    let paste = NSMenuItem(title: "Paste", action: #selector(AppDelegate.paste(_:)), keyEquivalent: "v")
    paste.target = target
    editMenu.addItem(paste)
    editItem.submenu = editMenu

    let insertItem = NSMenuItem()
    mainMenu.addItem(insertItem)
    let insertMenu = NSMenu(title: "Insert")
    func addInsert(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        insertMenu.addItem(item)
    }
    addInsert("Rectangle", #selector(AppDelegate.insertRectangle(_:)))
    addInsert("Ellipse", #selector(AppDelegate.insertEllipse(_:)))
    addInsert("Text", #selector(AppDelegate.insertText(_:)))
    insertItem.submenu = insertMenu

    let aiItem = NSMenuItem()
    mainMenu.addItem(aiItem)
    let aiMenu = NSMenu(title: "AI")
    let generate = NSMenuItem(title: "Generate…",
                              action: #selector(AppDelegate.toggleAIPanel(_:)), keyEquivalent: "k")
    generate.target = target
    aiMenu.addItem(generate)
    let teach = NSMenuItem(title: "Teach Style from Clips…",
                           action: #selector(AppDelegate.showTasteSheet(_:)), keyEquivalent: "")
    teach.target = target
    aiMenu.addItem(teach)
    aiItem.submenu = aiMenu

    NSApp.mainMenu = mainMenu
}
#endif
