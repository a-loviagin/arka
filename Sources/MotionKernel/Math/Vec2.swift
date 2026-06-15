import Foundation

/// 2D vector. Used for position, scale, anchor, size, and as its own spatial tangent.
///
/// Codable representation is a two-element JSON array `[x, y]` — matching the schema
/// (`"v": [200, 540]`). We hand-roll a struct rather than `SIMD2<Double>` to pin the
/// wire format and stay free of the Apple `simd` module (Linux-clean per platform-strategy §2).
public struct Vec2: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)
    public static let one = Vec2(1, 1)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    // Encoded as [x, y].
    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let x = try c.decode(Double.self)
        let y = try c.decode(Double.self)
        self.init(x, y)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

extension Vec2: Interpolatable {
    /// Position's spatial tangent is itself a Vec2 (value-space tangent).
    public typealias Tangent = Vec2

    public static func lerp(_ a: Vec2, _ b: Vec2, _ u: Double) -> Vec2 {
        Vec2(Double.lerp(a.x, b.x, u), Double.lerp(a.y, b.y, u))
    }

    /// Cubic Bézier in value space: P0 = a, P3 = b, with control points derived from
    /// the tangents. `outT`/`inT` are offsets (value-space) from the respective anchors —
    /// exactly the `spatialOut`/`spatialIn` of the schema, which give curved motion paths.
    public static func cubic(_ a: Vec2, _ b: Vec2,
                             outT: Vec2?, inT: Vec2?, _ u: Double) -> Vec2 {
        let p0 = a
        let p3 = b
        let p1 = a + (outT ?? .zero)
        let p2 = b + (inT ?? .zero)
        let mu = 1 - u
        let c0 = mu * mu * mu
        let c1 = 3 * mu * mu * u
        let c2 = 3 * mu * u * u
        let c3 = u * u * u
        return Vec2(
            c0 * p0.x + c1 * p1.x + c2 * p2.x + c3 * p3.x,
            c0 * p0.y + c1 * p1.y + c2 * p2.y + c3 * p3.y
        )
    }
}
