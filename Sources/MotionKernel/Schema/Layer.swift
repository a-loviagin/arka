import Foundation

/// How a layer composites onto what's beneath it (render-engine.md §3). v1 supports the modes
/// expressible as premultiplied fixed-function blends; more (overlay, darken, …) need a backdrop pass.
public enum BlendMode: String, Codable, Sendable, Equatable, CaseIterable {
    case normal, multiply, screen, add, lighten
}

/// Track matte (properties-and-commands.md §Tier 3): this layer is masked by the layer directly
/// above it in render order — by the matte's alpha or luminance, optionally inverted. The matte
/// layer is consumed (not drawn on its own).
public enum TrackMatte: String, Codable, Sendable, Equatable, CaseIterable {
    case alpha, alphaInverted, luma, lumaInverted
}

/// A layer in a composition (motion-document-schema.md §3).
///
/// Grouping is **flat** — prefer a single layer array + `parentId` over nested arrays. Flat lists
/// make AI patches, reordering, and diffing far simpler; the tree is derived at runtime.
///
/// z-order is a fractional `sortKey` (multiplayer.md §2 "do now"), not array position.
public struct Layer: Codable, Sendable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var parentId: EntityID?
    public var sortKey: SortKey
    public var visible: Bool
    public var locked: Bool
    /// Layer is active in [inPoint, outPoint] (comp seconds).
    public var inPoint: TimeInterval
    public var outPoint: TimeInterval
    public var transform: Transform
    public var content: LayerContent
    public var effects: [Effect]
    public var blendMode: BlendMode
    /// When set, this layer is matted by the layer directly above it (omitted-default nil).
    public var trackMatte: TrackMatte?

    public init(id: EntityID, name: String, sortKey: SortKey,
                content: LayerContent,
                parentId: EntityID? = nil,
                visible: Bool = true, locked: Bool = false,
                inPoint: TimeInterval = 0, outPoint: TimeInterval = .infinity,
                transform: Transform = Transform(),
                effects: [Effect] = [],
                blendMode: BlendMode = .normal,
                trackMatte: TrackMatte? = nil) {
        self.id = id
        self.name = name
        self.sortKey = sortKey
        self.content = content
        self.parentId = parentId
        self.visible = visible
        self.locked = locked
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.transform = transform
        self.effects = effects
        self.blendMode = blendMode
        self.trackMatte = trackMatte
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentId, sortKey, visible, locked, inPoint, outPoint, transform, content, effects, blendMode, trackMatte
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        parentId = try c.decodeIfPresent(EntityID.self, forKey: .parentId)
        sortKey = try c.decode(SortKey.self, forKey: .sortKey)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        inPoint = try c.decodeIfPresent(TimeInterval.self, forKey: .inPoint) ?? 0
        outPoint = try c.decodeIfPresent(TimeInterval.self, forKey: .outPoint) ?? .infinity
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform) ?? Transform()
        content = try c.decode(LayerContent.self, forKey: .content)
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? .normal
        trackMatte = try c.decodeIfPresent(TrackMatte.self, forKey: .trackMatte)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !name.isEmpty { try c.encode(name, forKey: .name) }
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encode(sortKey, forKey: .sortKey)
        if !visible { try c.encode(visible, forKey: .visible) }
        if locked { try c.encode(locked, forKey: .locked) }
        if inPoint != 0 { try c.encode(inPoint, forKey: .inPoint) }
        if outPoint != .infinity { try c.encode(outPoint, forKey: .outPoint) }
        try c.encode(transform, forKey: .transform)
        try c.encode(content, forKey: .content)
        if !effects.isEmpty { try c.encode(effects, forKey: .effects) }
        if blendMode != .normal { try c.encode(blendMode, forKey: .blendMode) }
        try c.encodeIfPresent(trackMatte, forKey: .trackMatte)
    }
}
