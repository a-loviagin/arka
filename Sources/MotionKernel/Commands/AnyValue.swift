import Foundation

/// A type-erased animatable value used in the command wire format. The receiving property's kind
/// decides how it's interpreted; decoding is shape-based to match the schema's bare JSON
/// (`"v": -3`, `"v": [960, 1200]`, `"v": "#FF0000"`).
public enum AnyValue: Codable, Sendable, Equatable {
    case scalar(Double)
    case vec2(Vec2)
    case color(ColorValue)

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let d = try? single.decode(Double.self) {
            self = .scalar(d)
            return
        }
        if let hex = try? single.decode(String.self), let c = ColorValue(hex: hex) {
            self = .color(c)
            return
        }
        // Array: length 2 → vec2, length 4 → color.
        var unkeyed = try decoder.unkeyedContainer()
        var nums: [Double] = []
        while !unkeyed.isAtEnd { nums.append(try unkeyed.decode(Double.self)) }
        switch nums.count {
        case 2: self = .vec2(Vec2(nums[0], nums[1]))
        case 4: self = .color(ColorValue(r: nums[0], g: nums[1], b: nums[2], a: nums[3]))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized AnyValue (got \(nums.count) numbers)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .scalar(let d): try single.encode(d)
        case .vec2(let v): try single.encode(v)
        case .color(let c): try single.encode(c)
        }
    }

    // Typed coercion — fail loudly when a property expects a different kind.
    public func asScalar() throws -> Double {
        guard case .scalar(let d) = self else { throw CommandError.typeMismatch(expected: "scalar", got: kindName) }
        return d
    }
    public func asVec2() throws -> Vec2 {
        guard case .vec2(let v) = self else { throw CommandError.typeMismatch(expected: "vec2", got: kindName) }
        return v
    }
    public func asColor() throws -> ColorValue {
        if case .color(let c) = self { return c }
        // Allow a 4-vec to stand in for a color.
        throw CommandError.typeMismatch(expected: "color", got: kindName)
    }

    var kindName: String {
        switch self {
        case .scalar: "scalar"; case .vec2: "vec2"; case .color: "color"
        }
    }
}

/// Type-erased keyframe carried by `SetKeyframe`. Mirrors `Keyframe` with an `AnyValue`.
public struct AnyKeyframe: Codable, Sendable, Equatable {
    public var t: TimeInterval
    public var v: AnyValue
    public var interp: Interpolation
    public var easeOut: ControlPoint?
    public var easeIn: ControlPoint?
    public var spatialOut: Vec2?
    public var spatialIn: Vec2?

    public init(t: TimeInterval, v: AnyValue, interp: Interpolation = .bezier,
                easeOut: ControlPoint? = nil, easeIn: ControlPoint? = nil,
                spatialOut: Vec2? = nil, spatialIn: Vec2? = nil) {
        self.t = t; self.v = v; self.interp = interp
        self.easeOut = easeOut; self.easeIn = easeIn
        self.spatialOut = spatialOut; self.spatialIn = spatialIn
    }

    private enum CodingKeys: String, CodingKey {
        case t, v, easeOut, easeIn, spatialOut, spatialIn
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(TimeInterval.self, forKey: .t)
        v = try c.decode(AnyValue.self, forKey: .v)
        interp = try Interpolation(from: decoder)
        easeOut = try c.decodeIfPresent(ControlPoint.self, forKey: .easeOut)
        easeIn = try c.decodeIfPresent(ControlPoint.self, forKey: .easeIn)
        spatialOut = try c.decodeIfPresent(Vec2.self, forKey: .spatialOut)
        spatialIn = try c.decodeIfPresent(Vec2.self, forKey: .spatialIn)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(v, forKey: .v)
        try interp.encode(to: encoder)
        try c.encodeIfPresent(easeOut, forKey: .easeOut)
        try c.encodeIfPresent(easeIn, forKey: .easeIn)
        try c.encodeIfPresent(spatialOut, forKey: .spatialOut)
        try c.encodeIfPresent(spatialIn, forKey: .spatialIn)
    }

    /// Build a typed `Keyframe<V>` from this erased form, coercing the value and tangents.
    func typed<V: Componentwise>(as _: V.Type, coerce: (AnyValue) throws -> V) rethrows -> Keyframe<V> {
        Keyframe(t: t, v: try coerce(v), interp: interp,
                 easeOut: easeOut, easeIn: easeIn,
                 spatialOut: spatialOut as? V.Tangent,
                 spatialIn: spatialIn as? V.Tangent)
    }
}
