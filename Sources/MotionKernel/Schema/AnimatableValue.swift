import Foundation

/// The core abstraction (motion-document-schema.md §4): every animatable property is either a
/// static value or a set of keyframed tracks. Same shape everywhere — transform, fill color,
/// corner radius, effect params.
///
/// Wire form:
///   static   → `{ "static": <value> }`
///   animated → `{ "tracks": [ { keyframes... } ] }`
///
/// RESERVED (schema open-decision #1): a future `{ "binding": ... }` variant (property A follows
/// property B) is additive — decoding it is a new key, not a breaking change. Not implemented in
/// v0.1; left as a forward-compatible extension point.
public enum AnimatableValue<V: Interpolatable>: Sendable, Equatable {
    case `static`(V)
    case animated([Track<V>])

    /// True if any track carries keyframes.
    public var isAnimated: Bool {
        if case .animated(let tracks) = self {
            return tracks.contains { !$0.keyframes.isEmpty }
        }
        return false
    }

    /// The static value, if this isn't animated.
    public var staticValue: V? {
        if case .static(let v) = self { return v }
        return nil
    }
}

extension AnimatableValue: Codable where V: Codable {
    private enum CodingKeys: String, CodingKey {
        case `static`, tracks
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let tracks = try c.decodeIfPresent([Track<V>].self, forKey: .tracks) {
            self = .animated(tracks)
        } else {
            self = .static(try c.decode(V.self, forKey: .static))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .static(let v): try c.encode(v, forKey: .static)
        case .animated(let tracks): try c.encode(tracks, forKey: .tracks)
        }
    }
}
