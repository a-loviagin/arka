#if os(macOS)
import Foundation
import Metal
import Observation
import MotionKernel
import MotionRender

/// App-wide state: the live document (owned by a `CommandStore` — the only write path), the current
/// selection, and the shared GPU resources used to render/export. One device/renderer/text-engine
/// for the whole app so textures are always made on the device the canvas draws with.
///
/// `document` is an observable mirror of `store.document`, refreshed on every command (and on
/// undo/redo) so SwiftUI panels and the canvas follow edits live.
@MainActor
@Observable
final class DocumentModel {
    let store: CommandStore
    private(set) var document: MotionDocument

    /// Selected layer ids. Mirrored into the store so undo records capture/restore selection.
    var selection: Set<EntityID> = [] {
        didSet { store.selection = Selection(layerIds: selection) }
    }

    private(set) var assetBytes: [String: Data]
    private(set) var textures: TextureCache?

    let device: MTLDevice?
    let renderer: MetalRenderer?
    let textEngine: TextEngine?
    let playback: PlaybackController

    init() {
        let doc = DemoDocument.make()
        self.store = CommandStore(document: doc)
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

        store.onChange = { [weak self] _ in
            guard let self else { return }
            self.document = self.store.document
            self.selection = self.store.selection.layerIds
        }
    }

    var mainComp: Composition? { document.mainComposition }
    func layer(_ id: EntityID) -> Layer? { mainComp?.layer(id) }
    var selectedLayer: Layer? { selection.first.flatMap { layer($0) } }

    // MARK: Editing

    /// Move a layer to a new comp-space position, auto-keyframing per editor-ui.md §2: a static
    /// track becomes a `SetProperty`; an animated track gets a `SetKeyframe` at the playhead.
    func setPosition(_ layerId: EntityID, to position: Vec2, within txn: TransactionID) {
        guard let layer = layer(layerId), let comp = mainComp else { return }
        let path = "\(layerId)/transform/position"
        let command: AnyCommand
        if layer.transform.position.isAnimated {
            let t = min(max(playback.currentTime, 0), comp.duration)
            command = .setKeyframe(path: path, keyframe: AnyKeyframe(t: t, v: .vec2(position)))
        } else {
            command = .setProperty(path: path, value: .vec2(position))
        }
        try? store.perform(command, in: txn)
    }

    /// Set a layer's scale, auto-keyframing the same way.
    func setScale(_ layerId: EntityID, to scale: Vec2, within txn: TransactionID) {
        guard let layer = layer(layerId), let comp = mainComp else { return }
        let path = "\(layerId)/transform/scale"
        let command: AnyCommand
        if layer.transform.scale.isAnimated {
            let t = min(max(playback.currentTime, 0), comp.duration)
            command = .setKeyframe(path: path, keyframe: AnyKeyframe(t: t, v: .vec2(scale)))
        } else {
            command = .setProperty(path: path, value: .vec2(scale))
        }
        try? store.perform(command, in: txn)
    }

    /// Set a layer's rotation (degrees), auto-keyframing the same way.
    func setRotation(_ layerId: EntityID, to degrees: Double, within txn: TransactionID) {
        guard let layer = layer(layerId), let comp = mainComp else { return }
        let path = "\(layerId)/transform/rotation"
        let command: AnyCommand
        if layer.transform.rotation.isAnimated {
            let t = min(max(playback.currentTime, 0), comp.duration)
            command = .setKeyframe(path: path, keyframe: AnyKeyframe(t: t, v: .scalar(degrees)))
        } else {
            command = .setProperty(path: path, value: .scalar(degrees))
        }
        try? store.perform(command, in: txn)
    }

    /// Set a layer's opacity (0…1), auto-keyframing the same way.
    func setOpacity(_ layerId: EntityID, to opacity: Double, within txn: TransactionID) {
        guard let layer = layer(layerId), let comp = mainComp else { return }
        let path = "\(layerId)/transform/opacity"
        let value = min(max(opacity, 0), 1)
        let command: AnyCommand
        if layer.transform.opacity.isAnimated {
            let t = min(max(playback.currentTime, 0), comp.duration)
            command = .setKeyframe(path: path, keyframe: AnyKeyframe(t: t, v: .scalar(value)))
        } else {
            command = .setProperty(path: path, value: .scalar(value))
        }
        try? store.perform(command, in: txn)
    }

    // MARK: Layer list

    func setVisible(_ layerId: EntityID, _ visible: Bool) {
        try? store.perform(.setLayerVisible(layerId: layerId, visible: visible),
                           label: visible ? "Show Layer" : "Hide Layer")
    }

    func setSortKey(_ layerId: EntityID, _ sortKey: SortKey) {
        try? store.perform(.reorderLayer(layerId: layerId, sortKey: sortKey), label: "Reorder Layer")
    }

    // MARK: Keyframe authoring

    enum KeyframeProperty { case position, opacity }

    /// Toggle a keyframe at the playhead for the given property: remove it if one sits at (within
    /// half a frame of) the playhead, otherwise add one capturing the current resolved value.
    func toggleKeyframe(_ layerId: EntityID, _ property: KeyframeProperty) {
        guard let layer = layer(layerId), let comp = mainComp else { return }
        let t = min(max(playback.currentTime, 0), comp.duration)
        let tolerance = 0.5 / max(comp.fps, 1)

        switch property {
        case .opacity:
            let av = layer.transform.opacity
            let path = "\(layerId)/transform/opacity"
            if let existing = TimelineDigest.keyframeTimes(of: av).first(where: { abs($0 - t) <= tolerance }) {
                try? store.perform(.removeKeyframe(path: path, t: existing), label: "Remove Keyframe")
            } else {
                try? store.perform(.setKeyframe(path: path,
                    keyframe: AnyKeyframe(t: t, v: .scalar(av.resolve(at: t)))), label: "Add Keyframe")
            }
        case .position:
            let av = layer.transform.position
            let path = "\(layerId)/transform/position"
            if let existing = TimelineDigest.keyframeTimes(of: av).first(where: { abs($0 - t) <= tolerance }) {
                try? store.perform(.removeKeyframe(path: path, t: existing), label: "Remove Keyframe")
            } else {
                try? store.perform(.setKeyframe(path: path,
                    keyframe: AnyKeyframe(t: t, v: .vec2(av.resolve(at: t)))), label: "Add Keyframe")
            }
        }
    }

    func hasKeyframeAtPlayhead(_ layerId: EntityID, _ property: KeyframeProperty) -> Bool {
        guard let layer = layer(layerId), let comp = mainComp else { return false }
        let t = min(max(playback.currentTime, 0), comp.duration)
        let tolerance = 0.5 / max(comp.fps, 1)
        let times: [TimeInterval]
        switch property {
        case .position: times = TimelineDigest.keyframeTimes(of: layer.transform.position)
        case .opacity: times = TimelineDigest.keyframeTimes(of: layer.transform.opacity)
        }
        return times.contains { abs($0 - t) <= tolerance }
    }

    // MARK: Files

    func save(to url: URL) throws {
        var thumbnail: Data?
        if let renderer, let comp = mainComp {
            thumbnail = Thumbnail.png(document: document, compId: comp.id, renderer: renderer,
                                      textEngine: textEngine, textures: textures)
        }
        try MotionPackage.write(document, to: url, assetData: assetBytes, thumbnailPNG: thumbnail)
    }

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
        store.replaceDocument(doc) // also clears selection via onChange
        assetBytes = bytes
        textures = cache
        playback.seek(to: 0)
        playback.duration = doc.mainComposition?.duration ?? 5
    }
}
#endif
