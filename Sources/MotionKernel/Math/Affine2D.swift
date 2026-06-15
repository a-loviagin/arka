import Foundation

/// A 2D affine transform, row-vector convention: `p' = p * M`.
///
/// Kernel-local (no Apple `simd`); the app maps this to `simd_float3x3` at the RenderTree
/// boundary (render-engine.md §1). Stored as the six meaningful entries of
/// `[ a  b  0 ]
///  [ c  d  0 ]
///  [ tx ty 1 ]`.
public struct Affine2D: Sendable, Equatable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Affine2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ t: Vec2) -> Affine2D {
        Affine2D(a: 1, b: 0, c: 0, d: 1, tx: t.x, ty: t.y)
    }
    public static func scale(_ s: Vec2) -> Affine2D {
        Affine2D(a: s.x, b: 0, c: 0, d: s.y, tx: 0, ty: 0)
    }
    /// Rotation by `degrees` (clockwise-positive in a y-down screen space).
    public static func rotation(degrees: Double) -> Affine2D {
        let r = degrees * .pi / 180
        let cs = cos(r), sn = sin(r)
        return Affine2D(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }

    /// Matrix product `self * other` (apply `self` first, then `other`).
    public func concatenating(_ m: Affine2D) -> Affine2D {
        Affine2D(
            a: a * m.a + b * m.c,
            b: a * m.b + b * m.d,
            c: c * m.a + d * m.c,
            d: c * m.b + d * m.d,
            tx: tx * m.a + ty * m.c + m.tx,
            ty: tx * m.b + ty * m.d + m.ty
        )
    }

    public func apply(to p: Vec2) -> Vec2 {
        Vec2(p.x * a + p.y * c + tx, p.x * b + p.y * d + ty)
    }
}
