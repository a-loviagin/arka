import Foundation

/// Compact context for the AI request (ai-pipeline.md §2): summarize, never dump. Each layer becomes
/// a small digest; selected layers also travel as full JSON so the model can edit their keyframes
/// precisely. Foundation-only and deterministic, so it's testable and identical on a server.
public struct DocumentDigest: Codable, Sendable, Equatable {
    public struct CompSettings: Codable, Sendable, Equatable {
        public var size: [Double]
        public var fps: Double
        public var duration: Double
        public var backgroundColor: ColorValue
    }

    public struct LayerSummary: Codable, Sendable, Equatable {
        public var id: String
        public var type: String
        public var name: String
        public var text: String?
        /// [x, y, w, h] axis-aligned bounds in comp space at the sample time (omitted when unknown).
        public var frame: [Double]?
        /// Relative animated property paths, e.g. "transform/opacity".
        public var animated: [String]
        public var keyframeCount: Int
        public var parentId: String?
        public var selected: Bool
    }

    public var comp: CompSettings
    public var selectionIds: [String]
    public var layers: [LayerSummary]
    /// Full JSON of the selected layers (precise editing).
    public var selectedLayers: [Layer]

    public static func summarize(_ document: MotionDocument, compId: EntityID,
                                 selection: Set<EntityID> = [], at t: TimeInterval = 0) -> DocumentDigest? {
        guard let comp = document.composition(compId) else { return nil }
        let evaluated = SceneEvaluator(document: document).evaluate(compId: compId, at: t)
        let boundsById = Dictionary(uniqueKeysWithValues: evaluated.map { ($0.layerId, $0.boundingBox) })

        let summaries = comp.layersInRenderOrder.map { layer -> LayerSummary in
            let tracks = TimelineDigest.tracks(for: layer)
            let animated = tracks.map { String($0.path.dropFirst(layer.id.rawValue.count + 1)) }
            let keyframeCount = tracks.reduce(0) { $0 + $1.times.count }
            var text: String?
            if case .text(let tc) = layer.content { text = tc.string }
            var frame: [Double]?
            if let b = boundsById[layer.id], b.max.x > b.min.x {
                frame = [b.min.x, b.min.y, b.max.x - b.min.x, b.max.y - b.min.y].map { ($0 * 10).rounded() / 10 }
            }
            return LayerSummary(id: layer.id.rawValue, type: layer.content.typeName, name: layer.name,
                                text: text, frame: frame, animated: animated, keyframeCount: keyframeCount,
                                parentId: layer.parentId?.rawValue, selected: selection.contains(layer.id))
        }

        return DocumentDigest(
            comp: CompSettings(size: [comp.size.x, comp.size.y], fps: comp.fps,
                               duration: comp.duration, backgroundColor: comp.backgroundColor),
            selectionIds: selection.map(\.rawValue).sorted(),
            layers: summaries,
            selectedLayers: comp.layers.filter { selection.contains($0.id) })
    }
}
