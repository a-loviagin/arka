#if os(macOS)
import Foundation
import Metal
import Observation
import MotionKernel
import MotionRender
import MotionAI

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
    let videoProvider: VideoFrameProvider?
    /// Base dir for resolving relative asset paths (set when a `.motion` package is opened).
    private(set) var assetBaseURL: URL?

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
        self.videoProvider = dev.map { VideoFrameProvider(device: $0) }
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

    /// The keyframe currently selected in the timeline (for delete / easing), if any.
    struct SelectedKeyframe: Equatable { var path: String; var t: TimeInterval }
    var selectedKeyframe: SelectedKeyframe?

    /// Active canvas tool (editor-ui.md §3 keymap: V select, R rect, O ellipse, T text, A anchor).
    /// Creation tools place a layer at the click point, then revert to `.select`.
    enum Tool { case select, anchor, rect, ellipse, text }
    var tool: Tool = .select

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

    /// Move the anchor (normalized) while keeping the layer visually fixed: anchor is set static and
    /// position follows so the same pixels stay put (editor-ui.md §2 anchor tool).
    func setAnchor(_ layerId: EntityID, anchor: Vec2, position: Vec2, within txn: TransactionID) {
        try? store.perform(.setProperty(path: "\(layerId)/transform/anchor", value: .vec2(anchor)), in: txn)
        setPosition(layerId, to: position, within: txn)
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

    // MARK: Patterns / presets

    /// Apply a motion preset to the selected layer(s) at the playhead — one ⌘Z, plain keyframes
    /// (ai-pipeline.md §4). Multiple selected layers stagger.
    func applyPattern(_ pattern: MotionPattern, character: MotionCharacter, duration: TimeInterval) {
        guard let comp = mainComp, !selection.isEmpty else { return }
        let layers = comp.layers.filter { selection.contains($0.id) }.sorted { $0.sortKey < $1.sortKey }
        let params = PatternParams(at: playback.currentTime, duration: duration, character: character)
        let cmds = layers.count > 1
            ? PatternLibrary.stagger(pattern, on: layers, in: comp, params: params, gap: 0.08)
            : PatternLibrary.expand(pattern, on: layers[0], in: comp, params: params)
        guard !cmds.isEmpty else { return }
        try? store.perform(.batch(commands: cmds, label: pattern.displayName), label: pattern.displayName)
    }

    // MARK: Keyframe edit (timeline)

    func deleteSelectedKeyframe() {
        guard let kf = selectedKeyframe else { return }
        try? store.perform(.removeKeyframe(path: kf.path, t: kf.t), label: "Delete Keyframe")
        selectedKeyframe = nil
    }

    enum EasingPreset: String, CaseIterable { case linear = "Linear", easeInOut = "Ease In-Out",
                                              snappy = "Snappy", bouncy = "Bouncy" }

    /// Apply an easing/interp preset to the segment starting at keyframe `t` on `path`.
    func applyEasing(_ path: String, at t: TimeInterval, _ preset: EasingPreset) {
        let command: AnyCommand
        switch preset {
        case .linear:
            command = .setKeyframeInterp(path: path, t: t, interp: .linear)
        case .easeInOut:
            command = .batch(commands: [
                .setKeyframeInterp(path: path, t: t, interp: .bezier),
                .setKeyframeEasing(path: path, t: t,
                                   easeIn: ControlPoint(0.58, 1), easeOut: ControlPoint(0.42, 0)),
            ], label: "Ease In-Out")
        case .snappy:
            command = .setKeyframeInterp(path: path, t: t, interp: .spring(.snappy))
        case .bouncy:
            command = .setKeyframeInterp(path: path, t: t, interp: .spring(.bouncy))
        }
        try? store.perform(command, label: "Easing: \(preset.rawValue)")
    }

    // MARK: Authoring — create / delete / duplicate (editor-ui.md §1,2)

    enum NewLayerKind { case rect, ellipse, text }

    /// Mints client-prefixed layer IDs for hand-authored content.
    private var ids = IDGenerator(clientId: String(UUID().uuidString.prefix(4)))

    /// A sort key above every current layer (new layers land on top of z-order).
    private func topSortKey() -> SortKey {
        SortKey.between(mainComp?.layers.map(\.sortKey).max(), nil)
    }

    /// Create a layer of `kind` centered at `compPoint`, on top and selected — one ⌘Z.
    @discardableResult
    func createLayer(_ kind: NewLayerKind, at compPoint: Vec2) -> EntityID? {
        guard let comp = mainComp else { return nil }
        let id = ids.next("layer")
        let content: LayerContent
        let name: String
        switch kind {
        case .rect:
            content = .shape(ShapeContent(geometry: .rect, size: .static(Vec2(240, 160)),
                                          fillColor: .static(ColorValue(hex: "#5B8CFF")!)))
            name = "Rectangle"
        case .ellipse:
            content = .shape(ShapeContent(geometry: .ellipse, size: .static(Vec2(200, 200)),
                                          fillColor: .static(ColorValue(hex: "#FF6B6B")!)))
            name = "Ellipse"
        case .text:
            content = .text(TextContent(string: "Text", fontFamily: "Helvetica", fontSize: .static(72),
                                        fillColor: .static(.white), alignment: .center))
            name = "Text"
        }
        let layer = Layer(id: id, name: name, sortKey: topSortKey(), content: content,
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(compPoint)))
        guard (try? store.perform(.addLayer(layer: layer, compId: comp.id), label: "Add \(name)")) != nil
        else { return nil }
        selection = [id]
        return id
    }

    /// Menu convenience: create at the composition center.
    @discardableResult
    func createLayerAtCenter(_ kind: NewLayerKind) -> EntityID? {
        guard let comp = mainComp else { return nil }
        return createLayer(kind, at: Vec2(comp.size.x / 2, comp.size.y / 2))
    }

    func deleteSelectedLayers() {
        guard let comp = mainComp else { return }
        let targets = comp.layers.map(\.id).filter { selection.contains($0) }
        guard !targets.isEmpty else { return }
        let label = targets.count == 1 ? "Delete Layer" : "Delete \(targets.count) Layers"
        try? store.perform(.batch(commands: targets.map { .removeLayer(layerId: $0) }, label: label),
                           label: label)
        selection = []
    }

    /// Duplicate the selected layers (offset static ones by 20pt; animated transforms copied as-is),
    /// select the copies — one ⌘Z. Copies are unparented to avoid dangling parent refs in v1.
    func duplicateSelectedLayers() {
        guard let comp = mainComp else { return }
        let originals = comp.layers.filter { selection.contains($0.id) }.sorted { $0.sortKey < $1.sortKey }
        guard !originals.isEmpty else { return }
        var cmds: [AnyCommand] = []
        var newIds: Set<EntityID> = []
        var top = mainComp?.layers.map(\.sortKey).max()
        for original in originals {
            var copy = original
            copy.id = ids.next("layer")
            copy.name = original.name + " copy"
            copy.parentId = nil
            let key = SortKey.between(top, nil); top = key
            copy.sortKey = key
            if case .static(let p) = original.transform.position {
                copy.transform.position = .static(Vec2(p.x + 20, p.y + 20))
            }
            cmds.append(.addLayer(layer: copy, compId: comp.id))
            newIds.insert(copy.id)
        }
        let label = originals.count == 1 ? "Duplicate Layer" : "Duplicate \(originals.count) Layers"
        try? store.perform(.batch(commands: cmds, label: label), label: label)
        selection = newIds
    }

    // MARK: AI (ai-pipeline.md §1,5,7)

    enum AIState: Equatable { case idle, generating, failed(String) }
    /// Whether the ⌘K prompt panel is showing, and the running state of a generation.
    var aiPanelVisible = false
    private(set) var aiState: AIState = .idle
    /// The conversation so far — prior prompts feed the next request (the conversation is the workflow).
    private(set) var aiHistory: [String] = []

    /// True when a live LLM backend is configured; otherwise the offline heuristic generator is used.
    var aiUsesLiveModel: Bool { AnthropicClient.fromEnvironment() != nil }

    /// Run a prompt through the generation pipeline and apply the result as one undoable `.ai`
    /// transaction. Uses the Anthropic client when `ANTHROPIC_API_KEY` is set, else the offline
    /// heuristic generator so the panel always works.
    func generate(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let comp = mainComp else { return }
        guard let digest = DocumentDigest.summarize(document, compId: comp.id,
                                                    selection: selection, at: playback.currentTime,
                                                    textMeasurer: textEngine) else {
            aiState = .failed("no composition to edit")
            return
        }
        aiState = .generating
        let request = GenerationRequest(prompt: trimmed, mode: .edit, digest: digest,
                                        playhead: playback.currentTime, history: aiHistory)
        let generator: any MotionGenerator = AnthropicClient.fromEnvironment() ?? HeuristicGenerator()
        let pipeline = GenerationPipeline(generator: generator)
        do {
            let result = try await pipeline.generate(request, against: document)
            applyGenerated(result)
            aiHistory.append(trimmed)
            aiState = .idle
            aiPanelVisible = false
        } catch {
            aiState = .failed(String(describing: error))
        }
    }

    /// Apply a validated generation as a single `.ai` transaction (one ⌘Z), tagged with a generation
    /// id so the undo record carries provenance.
    private func applyGenerated(_ result: GenerationResult) {
        guard !result.commands.isEmpty else { return }
        let command: AnyCommand = result.commands.count == 1
            ? result.commands[0]
            : .batch(commands: result.commands, label: result.label)
        _ = try? store.perform(command, label: result.label,
                               source: .ai(generationID: UUID().uuidString))
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
        assetBaseURL = url // video assets resolve relative to the package dir
        playback.seek(to: 0)
        playback.duration = doc.mainComposition?.duration ?? 5
    }
}
#endif
