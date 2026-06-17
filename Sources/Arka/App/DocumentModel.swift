#if os(macOS)
import Foundation
import Metal
import Observation
import MotionKernel
import MotionRender

/// App-wide state: the live document plus the shared GPU resources used to render and export it.
/// One device/renderer/text-engine for the whole app so textures (demo or loaded from a package)
/// are always created on the device the canvas draws with. Save/Open live here (editor-ui.md §1:
/// the document is the only truth).
@MainActor
@Observable
final class DocumentModel {
    private(set) var document: MotionDocument
    /// Source-of-truth asset bytes by package path, for writing `.motion` packages.
    private(set) var assetBytes: [String: Data]
    private(set) var textures: TextureCache?

    let device: MTLDevice?
    let renderer: MetalRenderer?
    let textEngine: TextEngine?
    let playback: PlaybackController

    init() {
        let doc = DemoDocument.make()
        self.document = doc
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.renderer = dev.flatMap { try? MetalRenderer(device: $0) }
        self.textEngine = dev.flatMap { TextEngine(device: $0) }
        self.playback = PlaybackController(duration: doc.mainComposition?.duration ?? 5)

        var bytes: [String: Data] = [:]
        if let asset = doc.assets.first { bytes[asset.path] = DemoDocument.logoPNG() }
        self.assetBytes = bytes
        if let dev {
            let cache = TextureCache(device: dev)
            cache.register(id: DemoDocument.logoAssetId, cgImage: DemoDocument.makeLogoImage())
            self.textures = cache
        }
    }

    /// Write the current document + assets + a fresh 25%-duration thumbnail to a `.motion` package.
    func save(to url: URL) throws {
        var thumbnail: Data?
        if let renderer, let comp = document.mainComposition {
            thumbnail = Thumbnail.png(document: document, compId: comp.id, renderer: renderer,
                                      textEngine: textEngine, textures: textures)
        }
        try MotionPackage.write(document, to: url, assetData: assetBytes, thumbnailPNG: thumbnail)
    }

    /// Open a `.motion` package: migrate the document, reload its assets into a fresh texture cache,
    /// and reset playback. The canvas reads `document`/`textures` live, so it refreshes next tick.
    func open(_ url: URL) throws {
        let doc = try MotionPackage.read(at: url)
        let bytes = MotionPackage.assetData(in: url, for: doc)
        var cache: TextureCache?
        if let device {
            let c = TextureCache(device: device)
            for asset in doc.assets where asset.type == .image {
                c.load(asset: asset, baseURL: url)
            }
            cache = c
        }
        document = doc
        assetBytes = bytes
        textures = cache
        playback.seek(to: 0)
        playback.duration = doc.mainComposition?.duration ?? 5
    }
}
#endif
