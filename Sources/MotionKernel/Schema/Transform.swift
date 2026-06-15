import Foundation

/// Per-layer transform (motion-document-schema.md §3). Every field is an `AnimatableValue`.
/// `anchor` is normalized (0–1 of layer bounds) so it survives resizes. `rotation` is in
/// degrees and unbounded (720° = two turns; never normalized). `opacity` multiplies down the
/// parent chain.
public struct Transform: Codable, Sendable, Equatable {
    public var anchor: AnimatableValue<Vec2>
    public var position: AnimatableValue<Vec2>
    public var scale: AnimatableValue<Vec2>
    public var rotation: AnimatableValue<Double>
    public var opacity: AnimatableValue<Double>
    /// Tier 2 transform extras; omitted by default.
    public var skew: AnimatableValue<Double>?
    public var skewAxis: AnimatableValue<Double>?

    public init(
        anchor: AnimatableValue<Vec2> = .static(Vec2(0.5, 0.5)),
        position: AnimatableValue<Vec2> = .static(.zero),
        scale: AnimatableValue<Vec2> = .static(.one),
        rotation: AnimatableValue<Double> = .static(0),
        opacity: AnimatableValue<Double> = .static(1),
        skew: AnimatableValue<Double>? = nil,
        skewAxis: AnimatableValue<Double>? = nil
    ) {
        self.anchor = anchor
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.skew = skew
        self.skewAxis = skewAxis
    }

    // Omitted = default (schema §1). Keeps files small and LLM output short.
    private enum CodingKeys: String, CodingKey {
        case anchor, position, scale, rotation, opacity, skew, skewAxis
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decodeIfPresent(AnimatableValue<Vec2>.self, forKey: .anchor) ?? .static(Vec2(0.5, 0.5))
        position = try c.decodeIfPresent(AnimatableValue<Vec2>.self, forKey: .position) ?? .static(.zero)
        scale = try c.decodeIfPresent(AnimatableValue<Vec2>.self, forKey: .scale) ?? .static(.one)
        rotation = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .rotation) ?? .static(0)
        opacity = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .opacity) ?? .static(1)
        skew = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .skew)
        skewAxis = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .skewAxis)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Only write non-default values so files stay compact.
        if anchor != .static(Vec2(0.5, 0.5)) { try c.encode(anchor, forKey: .anchor) }
        if position != .static(.zero) { try c.encode(position, forKey: .position) }
        if scale != .static(.one) { try c.encode(scale, forKey: .scale) }
        if rotation != .static(0) { try c.encode(rotation, forKey: .rotation) }
        if opacity != .static(1) { try c.encode(opacity, forKey: .opacity) }
        try c.encodeIfPresent(skew, forKey: .skew)
        try c.encodeIfPresent(skewAxis, forKey: .skewAxis)
    }
}
