import Foundation

/// How a keyframe reaches the **next** keyframe (motion-document-schema.md §4).
public enum Interpolation: Sendable, Equatable {
    case linear
    case bezier
    case hold
    case spring(Spring)

    /// The default segment interpolation when `interp` is omitted.
    public static let `default` = Interpolation.bezier
}

extension Interpolation: Codable {
    private enum Kind: String, Codable {
        case linear, bezier, hold, spring
    }
    private enum CodingKeys: String, CodingKey {
        case interp, spring
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Omitted `interp` defaults to bezier (the pleasant ease-in-out, schema §4).
        let kind = try c.decodeIfPresent(Kind.self, forKey: .interp) ?? .bezier
        switch kind {
        case .linear: self = .linear
        case .bezier: self = .bezier
        case .hold: self = .hold
        case .spring: self = .spring(try c.decode(Spring.self, forKey: .spring))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear: try c.encode(Kind.linear, forKey: .interp)
        case .bezier: try c.encode(Kind.bezier, forKey: .interp)
        case .hold: try c.encode(Kind.hold, forKey: .interp)
        case .spring(let s):
            try c.encode(Kind.spring, forKey: .interp)
            try c.encode(s, forKey: .spring)
        }
    }
}
