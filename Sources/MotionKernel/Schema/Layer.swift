import Foundation

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

    public init(id: EntityID, name: String, sortKey: SortKey,
                content: LayerContent,
                parentId: EntityID? = nil,
                visible: Bool = true, locked: Bool = false,
                inPoint: TimeInterval = 0, outPoint: TimeInterval = .infinity,
                transform: Transform = Transform(),
                effects: [Effect] = []) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentId, sortKey, visible, locked, inPoint, outPoint, transform, content, effects
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
    }
}
