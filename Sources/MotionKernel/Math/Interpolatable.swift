import Foundation

/// A value that can live on a keyframe and be interpolated between keyframes.
///
/// `lerp` is the straight-line blend; `cubic` is the spatial cubic used for curved
/// motion paths (vec2 position with spatial tangents). Scalars conform with a trivial
/// `cubic` that just defers to `lerp` on the already-eased parameter.
///
/// See motion-document-schema.md §5.
public protocol Interpolatable: Equatable, Sendable {
    /// Tangent type for spatial cubic interpolation (path shaping). `Vec2` for position,
    /// `Never`-like empty for scalars/colors that don't carry spatial tangents.
    associatedtype Tangent: Codable & Sendable & Equatable

    static func lerp(_ a: Self, _ b: Self, _ u: Double) -> Self

    /// Spatial cubic: blend `a`→`b` shaped by outgoing/incoming tangents.
    /// `u` is the already temporally-eased parameter in [0, 1].
    static func cubic(_ a: Self, _ b: Self,
                      outT: Tangent?, inT: Tangent?, _ u: Double) -> Self
}

public extension Interpolatable {
    /// Default: ignore tangents, fall back to a straight lerp.
    static func cubic(_ a: Self, _ b: Self,
                      outT: Tangent?, inT: Tangent?, _ u: Double) -> Self {
        lerp(a, b, u)
    }
}

// MARK: - Double

extension Double: Interpolatable {
    public typealias Tangent = NoTangent
    public static func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double {
        a + (b - a) * u
    }
}

/// Placeholder tangent for value types that have no spatial component (scalars, colors).
public struct NoTangent: Codable, Sendable, Equatable {
    public init() {}
}
