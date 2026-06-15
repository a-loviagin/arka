import Foundation

/// Which scalar component of a multi-dimensional value a track drives (motion-document-schema.md §4).
/// `nil` component = the whole value (combined track); separated dimensions use `.x` / `.y`.
public enum Component: String, Codable, Sendable, Equatable {
    case x, y, z, w
}

/// A sequence of keyframes for one (optionally separated) component of a property.
/// Invariant: `keyframes` is sorted ascending by `t`. Enforced on construction and after edits.
public struct Track<V: Interpolatable>: Sendable, Equatable {
    public var component: Component?
    public var keyframes: [Keyframe<V>]

    public init(component: Component? = nil, keyframes: [Keyframe<V>]) {
        self.component = component
        self.keyframes = keyframes.sorted { $0.t < $1.t }
    }

    /// Re-establish the sorted-by-t invariant after mutation.
    public mutating func normalize() {
        keyframes.sort { $0.t < $1.t }
    }
}

extension Track: Codable where V: Codable {
    private enum CodingKeys: String, CodingKey {
        case component, keyframes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let component = try c.decodeIfPresent(Component.self, forKey: .component)
        let kfs = try c.decode([Keyframe<V>].self, forKey: .keyframes)
        self.init(component: component, keyframes: kfs)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(component, forKey: .component)
        try c.encode(keyframes, forKey: .keyframes)
    }
}
