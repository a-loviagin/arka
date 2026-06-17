import Foundation

/// The top-level document (motion-document-schema.md §1). A pure Swift value type — copying is
/// O(1) via copy-on-write, which is what makes snapshot-based undo (undo-system.md §1) cheap.
public struct MotionDocument: Codable, Sendable, Equatable {
    /// Current schema version this kernel writes. Bump with every migration.
    public static let currentSchemaVersion = "0.1.0"

    public var schemaVersion: String
    public var id: EntityID
    public var meta: Meta
    public var assets: [Asset]
    public var compositions: [Composition]
    public var mainCompositionId: EntityID

    public init(id: EntityID,
                meta: Meta = Meta(),
                assets: [Asset] = [],
                compositions: [Composition],
                mainCompositionId: EntityID,
                schemaVersion: String = MotionDocument.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.meta = meta
        self.assets = assets
        self.compositions = compositions
        self.mainCompositionId = mainCompositionId
    }

    // Omitted = default (schema §1): meta/assets/schemaVersion may be absent in a hand-written or
    // minimal document.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, meta, assets, compositions, mainCompositionId
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? MotionDocument.currentSchemaVersion
        id = try c.decode(EntityID.self, forKey: .id)
        meta = try c.decodeIfPresent(Meta.self, forKey: .meta) ?? Meta()
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        compositions = try c.decode([Composition].self, forKey: .compositions)
        mainCompositionId = try c.decode(EntityID.self, forKey: .mainCompositionId)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(meta, forKey: .meta)
        if !assets.isEmpty { try c.encode(assets, forKey: .assets) }
        try c.encode(compositions, forKey: .compositions)
        try c.encode(mainCompositionId, forKey: .mainCompositionId)
    }

    public struct Meta: Codable, Sendable, Equatable {
        public var title: String
        public var createdAt: String?
        public var modifiedAt: String?
        public var generator: String?
        public init(title: String = "Untitled",
                    createdAt: String? = nil, modifiedAt: String? = nil,
                    generator: String? = nil) {
            self.title = title
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
            self.generator = generator
        }
    }

    // MARK: Lookups

    public var mainComposition: Composition? {
        composition(mainCompositionId)
    }
    public func composition(_ id: EntityID) -> Composition? {
        compositions.first { $0.id == id }
    }
    public func asset(_ id: EntityID) -> Asset? {
        assets.first { $0.id == id }
    }

    /// Index of a composition by id, or nil. Used by commands to mutate in place.
    public func compositionIndex(_ id: EntityID) -> Int? {
        compositions.firstIndex { $0.id == id }
    }
}
