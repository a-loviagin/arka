import Foundation

/// The command vocabulary (properties-and-commands.md §2), as one Codable enum. Its JSON form is
/// exactly the AI's structured output and (later) the multiplayer wire protocol — three features,
/// one design. `type` is the discriminator: `{"type":"SetKeyframe","path":...,"keyframe":{...}}`.
public enum AnyCommand: Command, Codable, Sendable, Equatable {
    case addLayer(layer: Layer, compId: EntityID)
    case removeLayer(layerId: EntityID)
    case reorderLayer(layerId: EntityID, sortKey: SortKey)
    case setLayerParent(layerId: EntityID, parentId: EntityID?)
    case setLayerVisible(layerId: EntityID, visible: Bool)
    case setLayerLocked(layerId: EntityID, locked: Bool)
    case setProperty(path: String, value: AnyValue)
    case setKeyframe(path: String, keyframe: AnyKeyframe)
    case removeKeyframe(path: String, t: TimeInterval)
    case moveKeyframes(moves: [KeyframeMove])
    case setKeyframeEasing(path: String, t: TimeInterval, easeIn: ControlPoint?, easeOut: ControlPoint?)
    case setKeyframeInterp(path: String, t: TimeInterval, interp: Interpolation)
    case addAsset(asset: Asset)
    case removeAsset(assetId: EntityID)
    case addEffect(layerId: EntityID, effect: Effect)
    case removeEffect(layerId: EntityID, effectId: EntityID)
    /// Structural edits (non-animatable): rename a layer, or replace its content payload (text
    /// string/font/alignment, image fit, shape geometry). Keyframed values use Set(Property|Keyframe).
    case setLayerName(layerId: EntityID, name: String)
    case setContent(layerId: EntityID, content: LayerContent)
    case setLayerBlendMode(layerId: EntityID, blendMode: BlendMode)
    case setCompositionSetting(compId: EntityID, setting: CompositionSetting)
    /// Frames are compositions (editor-ui board): add or remove a whole composition. The main
    /// composition can't be removed (every document keeps at least one frame).
    case addComposition(composition: Composition)
    case removeComposition(compId: EntityID)
    /// AI/preset macros (ai-pipeline.md §4): expand deterministically into keyframe commands on
    /// apply, via the pattern library.
    case applyPattern(layerId: EntityID, pattern: MotionPattern, params: PatternParams)
    case stagger(layerIds: [EntityID], pattern: MotionPattern, params: PatternParams, gap: TimeInterval)
    case batch(commands: [AnyCommand], label: String)

    public struct KeyframeMove: Codable, Sendable, Equatable {
        public var path: String
        public var oldT: TimeInterval
        public var newT: TimeInterval
        public init(path: String, oldT: TimeInterval, newT: TimeInterval) {
            self.path = path; self.oldT = oldT; self.newT = newT
        }
    }

    /// A composition-level setting change (duration/fps/size/backgroundColor).
    public enum CompositionSetting: Codable, Sendable, Equatable {
        case duration(TimeInterval)
        case fps(Double)
        case size(Vec2)
        case backgroundColor(ColorValue)
        case name(String)
    }

    // MARK: Validate

    public func validate(against doc: MotionDocument) throws {
        switch self {
        case .addLayer(let layer, let compId):
            guard let comp = doc.composition(compId) else { throw CommandError.compositionNotFound(compId) }
            if comp.layers.contains(where: { $0.id == layer.id }) { throw CommandError.duplicateID(layer.id) }
            if let p = layer.parentId, !comp.layers.contains(where: { $0.id == p }) {
                throw CommandError.layerNotFound(p)
            }
        case .removeLayer(let id):
            _ = try locateLayer(id, in: doc)
        case .reorderLayer(let id, _):
            _ = try locateLayer(id, in: doc)
        case .setLayerVisible(let id, _), .setLayerLocked(let id, _):
            _ = try locateLayer(id, in: doc)
        case .setLayerParent(let id, let parentId):
            let (compIdx, _) = try locateLayer(id, in: doc)
            let comp = doc.compositions[compIdx]
            if let p = parentId {
                guard comp.layers.contains(where: { $0.id == p }) else { throw CommandError.layerNotFound(p) }
                if DocumentRules.wouldCreateCycle(layer: id, newParent: p, in: comp) {
                    throw CommandError.parentCycle(layer: id, parent: p)
                }
            }
        case .setProperty(let path, _), .setKeyframe(let path, _),
             .removeKeyframe(let path, _), .setKeyframeEasing(let path, _, _, _),
             .setKeyframeInterp(let path, _, _):
            let pp = try PropertyPath(path)
            let (compIdx, layerIdx) = try locateLayer(pp.layerId, in: doc)
            // Confirm the path resolves to a real slot, and times are in range.
            _ = try doc.compositions[compIdx].layers[layerIdx].readSlot(pp.tail, rawPath: path)
            if case .setKeyframe(_, let kf) = self {
                try checkTime(kf.t, comp: doc.compositions[compIdx])
            }
        case .moveKeyframes(let moves):
            for m in moves {
                let pp = try PropertyPath(m.path)
                let (compIdx, layerIdx) = try locateLayer(pp.layerId, in: doc)
                _ = try doc.compositions[compIdx].layers[layerIdx].readSlot(pp.tail, rawPath: m.path)
                try checkTime(m.newT, comp: doc.compositions[compIdx])
            }
        case .addAsset(let asset):
            if doc.assets.contains(where: { $0.id == asset.id }) { throw CommandError.duplicateID(asset.id) }
        case .removeAsset(let id):
            guard doc.asset(id) != nil else { throw CommandError.assetNotFound(id) }
        case .addEffect(let layerId, let effect):
            let (ci, li) = try locateLayer(layerId, in: doc)
            if doc.compositions[ci].layers[li].effects.contains(where: { $0.id == effect.id }) {
                throw CommandError.duplicateID(effect.id)
            }
        case .removeEffect(let layerId, let effectId):
            let (ci, li) = try locateLayer(layerId, in: doc)
            guard doc.compositions[ci].layers[li].effects.contains(where: { $0.id == effectId }) else {
                throw CommandError.effectNotFound(effectId)
            }
        case .setLayerName(let layerId, _), .setContent(let layerId, _),
             .setLayerBlendMode(let layerId, _):
            _ = try locateLayer(layerId, in: doc)
        case .addComposition(let composition):
            if doc.composition(composition.id) != nil { throw CommandError.duplicateID(composition.id) }
        case .removeComposition(let compId):
            guard doc.composition(compId) != nil else { throw CommandError.compositionNotFound(compId) }
            if compId == doc.mainCompositionId { throw CommandError.valueOutOfRange("cannot remove the main composition") }
        case .setCompositionSetting(let compId, let setting):
            guard let comp = doc.composition(compId) else { throw CommandError.compositionNotFound(compId) }
            if case .duration(let d) = setting, d <= 0 {
                throw CommandError.valueOutOfRange("duration must be > 0")
            }
            if case .fps(let f) = setting, f <= 0 {
                throw CommandError.valueOutOfRange("fps must be > 0")
            }
            _ = comp
        case .applyPattern(let layerId, _, _):
            _ = try locateLayer(layerId, in: doc)
        case .stagger(let layerIds, _, _, _):
            for id in layerIds { _ = try locateLayer(id, in: doc) }
        case .batch(let commands, _):
            // Validate each against the *evolving* state: apply to a scratch copy as we go.
            var scratch = doc
            for cmd in commands {
                try cmd.validate(against: scratch)
                try cmd.apply(to: &scratch)
            }
        }
    }

    // MARK: Apply

    public func apply(to doc: inout MotionDocument) throws {
        switch self {
        case .addLayer(let layer, let compId):
            guard let ci = doc.compositionIndex(compId) else { throw CommandError.compositionNotFound(compId) }
            doc.compositions[ci].layers.append(layer)
        case .removeLayer(let id):
            let (ci, li) = try locateLayer(id, in: doc)
            // Re-parent orphans to the removed layer's parent (AE behavior: don't strand children).
            let removed = doc.compositions[ci].layers[li]
            for i in doc.compositions[ci].layers.indices where doc.compositions[ci].layers[i].parentId == id {
                doc.compositions[ci].layers[i].parentId = removed.parentId
            }
            doc.compositions[ci].layers.remove(at: li)
        case .reorderLayer(let id, let sortKey):
            let (ci, li) = try locateLayer(id, in: doc)
            doc.compositions[ci].layers[li].sortKey = sortKey
        case .setLayerVisible(let id, let visible):
            let (ci, li) = try locateLayer(id, in: doc)
            doc.compositions[ci].layers[li].visible = visible
        case .setLayerLocked(let id, let locked):
            let (ci, li) = try locateLayer(id, in: doc)
            doc.compositions[ci].layers[li].locked = locked
        case .setLayerParent(let id, let parentId):
            let (ci, li) = try locateLayer(id, in: doc)
            doc.compositions[ci].layers[li].parentId = parentId
        case .setProperty(let path, let value):
            try mutateSlot(path: path, in: &doc) { try $0.setStatic(value) }
        case .setKeyframe(let path, let kf):
            try mutateSlot(path: path, in: &doc) { try $0.upsertKeyframe(kf) }
        case .removeKeyframe(let path, let t):
            try mutateSlot(path: path, in: &doc) { $0.removeKeyframe(at: t) }
        case .setKeyframeEasing(let path, let t, let easeIn, let easeOut):
            try mutateSlot(path: path, in: &doc) { $0.setSegmentEasing(at: t, easeIn: easeIn, easeOut: easeOut) }
        case .setKeyframeInterp(let path, let t, let interp):
            try mutateSlot(path: path, in: &doc) { $0.setInterp(at: t, interp) }
        case .moveKeyframes(let moves):
            for m in moves {
                try mutateSlot(path: m.path, in: &doc) { $0.moveKeyframe(from: m.oldT, to: m.newT) }
            }
        case .addAsset(let asset):
            doc.assets.append(asset)
        case .removeAsset(let id):
            doc.assets.removeAll { $0.id == id }
        case .addEffect(let layerId, let effect):
            let (ci, li) = try locateLayer(layerId, in: doc)
            doc.compositions[ci].layers[li].effects.append(effect)
        case .removeEffect(let layerId, let effectId):
            let (ci, li) = try locateLayer(layerId, in: doc)
            doc.compositions[ci].layers[li].effects.removeAll { $0.id == effectId }
        case .setLayerName(let layerId, let name):
            let (ci, li) = try locateLayer(layerId, in: doc)
            doc.compositions[ci].layers[li].name = name
        case .setContent(let layerId, let content):
            let (ci, li) = try locateLayer(layerId, in: doc)
            doc.compositions[ci].layers[li].content = content
        case .setLayerBlendMode(let layerId, let blendMode):
            let (ci, li) = try locateLayer(layerId, in: doc)
            doc.compositions[ci].layers[li].blendMode = blendMode
        case .addComposition(let composition):
            doc.compositions.append(composition)
        case .removeComposition(let compId):
            doc.compositions.removeAll { $0.id == compId }
        case .setCompositionSetting(let compId, let setting):
            guard let ci = doc.compositionIndex(compId) else { throw CommandError.compositionNotFound(compId) }
            switch setting {
            case .duration(let d): doc.compositions[ci].duration = d
            case .fps(let f): doc.compositions[ci].fps = f
            case .size(let s): doc.compositions[ci].size = s
            case .backgroundColor(let c): doc.compositions[ci].backgroundColor = c
            case .name(let n): doc.compositions[ci].name = n
            }
        case .applyPattern(let layerId, let pattern, let params):
            let (ci, li) = try locateLayer(layerId, in: doc)
            let expanded = PatternLibrary.expand(pattern, on: doc.compositions[ci].layers[li],
                                                 in: doc.compositions[ci], params: params)
            for cmd in expanded { try cmd.apply(to: &doc) }
        case .stagger(let layerIds, let pattern, let params, let gap):
            guard let first = layerIds.first else { return }
            let (ci, _) = try locateLayer(first, in: doc)
            let layers = layerIds.compactMap { id in doc.compositions[ci].layers.first { $0.id == id } }
            let expanded = PatternLibrary.stagger(pattern, on: layers, in: doc.compositions[ci],
                                                  params: params, gap: gap)
            for cmd in expanded { try cmd.apply(to: &doc) }
        case .batch(let commands, _):
            for cmd in commands { try cmd.apply(to: &doc) }
        }
    }

    // MARK: Helpers

    private func mutateSlot(path: String, in doc: inout MotionDocument,
                            _ body: (inout AnimatableSlot) throws -> Void) throws {
        let pp = try PropertyPath(path)
        let (ci, li) = try locateLayer(pp.layerId, in: doc)
        var slot = try doc.compositions[ci].layers[li].readSlot(pp.tail, rawPath: path)
        try body(&slot)
        try doc.compositions[ci].layers[li].writeSlot(slot, tail: pp.tail, rawPath: path)
    }

    private func locateLayer(_ id: EntityID, in doc: MotionDocument) throws -> (compIdx: Int, layerIdx: Int) {
        for (ci, comp) in doc.compositions.enumerated() {
            if let li = comp.layers.firstIndex(where: { $0.id == id }) { return (ci, li) }
        }
        throw CommandError.layerNotFound(id)
    }

    private func checkTime(_ t: TimeInterval, comp: Composition) throws {
        guard t >= 0, t <= comp.duration + 1e-6 else {
            throw CommandError.timeOutOfRange(t: t, duration: comp.duration)
        }
    }
}
