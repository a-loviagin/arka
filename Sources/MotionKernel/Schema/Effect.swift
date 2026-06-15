import Foundation

/// A uniform effect container (properties-and-commands.md §1). Every effect is `(type, params)`
/// where each param is just another `AnimatableValue`. New effects = new `type` + param schema +
/// (app-side) Metal kernel; the timeline UI and AI schema pick them up for free.
public struct Effect: Codable, Sendable, Equatable {
    public var id: EntityID
    public var type: String          // "blur", "shadow", …
    public var enabled: Bool
    public var params: [String: EffectParam]

    public init(id: EntityID, type: String, enabled: Bool = true,
                params: [String: EffectParam] = [:]) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case id, type, enabled, params }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        params = try c.decodeIfPresent([String: EffectParam].self, forKey: .params) ?? [:]
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        if !enabled { try c.encode(enabled, forKey: .enabled) }
        if !params.isEmpty { try c.encode(params, forKey: .params) }
    }
}

/// A typed animatable effect parameter. The kind is carried on the wire so a heterogeneous
/// param map round-trips and evaluates.
public enum EffectParam: Codable, Sendable, Equatable {
    case scalar(AnimatableValue<Double>)
    case vec2(AnimatableValue<Vec2>)
    case color(AnimatableValue<ColorValue>)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case scalar, vec2, color }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .scalar: self = .scalar(try c.decode(AnimatableValue<Double>.self, forKey: .value))
        case .vec2: self = .vec2(try c.decode(AnimatableValue<Vec2>.self, forKey: .value))
        case .color: self = .color(try c.decode(AnimatableValue<ColorValue>.self, forKey: .value))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scalar(let v): try c.encode(Kind.scalar, forKey: .kind); try c.encode(v, forKey: .value)
        case .vec2(let v): try c.encode(Kind.vec2, forKey: .kind); try c.encode(v, forKey: .value)
        case .color(let v): try c.encode(Kind.color, forKey: .kind); try c.encode(v, forKey: .value)
        }
    }
}
