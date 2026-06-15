import Foundation

/// A composition (motion-document-schema.md §2). Time is in **seconds** (Double); `fps` is
/// metadata for snapping/playback/export, not the unit of time.
public struct Composition: Codable, Sendable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var size: Vec2
    public var fps: Double
    public var duration: TimeInterval
    public var backgroundColor: ColorValue
    public var layers: [Layer]

    public init(id: EntityID, name: String = "Main",
                size: Vec2 = Vec2(1920, 1080), fps: Double = 60,
                duration: TimeInterval = 5.0,
                backgroundColor: ColorValue = .white,
                layers: [Layer] = []) {
        self.id = id
        self.name = name
        self.size = size
        self.fps = fps
        self.duration = duration
        self.backgroundColor = backgroundColor
        self.layers = layers
    }

    /// Layers in render order (bottom → top): ascending by `sortKey`.
    public var layersInRenderOrder: [Layer] {
        layers.sorted { $0.sortKey < $1.sortKey }
    }

    public func layer(_ id: EntityID) -> Layer? {
        layers.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, size, fps, duration, backgroundColor, layers
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Main"
        size = try c.decodeIfPresent(Vec2.self, forKey: .size) ?? Vec2(1920, 1080)
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 60
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 5.0
        backgroundColor = try c.decodeIfPresent(ColorValue.self, forKey: .backgroundColor) ?? .white
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(size, forKey: .size)
        try c.encode(fps, forKey: .fps)
        try c.encode(duration, forKey: .duration)
        try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(layers, forKey: .layers)
    }
}
