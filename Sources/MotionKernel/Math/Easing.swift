import Foundation

/// A temporal easing handle `[x, y]` of a cubic-bezier — the CSS easing model the whole
/// schema speaks (motion-document-schema.md §4). `x` is normalized time, `y` is normalized
/// progress; both conventionally in [0, 1] (x is clamped, y may overshoot for anticipation).
public struct ControlPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

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

public enum Easing {
    /// Schema defaults when handles are omitted (motion-document-schema.md §4):
    /// a pleasant ease-in-out.
    public static let defaultEaseOut = ControlPoint(0.33, 0.0)
    public static let defaultEaseIn = ControlPoint(0.67, 1.0)

    /// Solve `cubic-bezier(p1, p2)` for output progress `y` at normalized input time `t`.
    ///
    /// A segment between K₁ and K₂ with `interp: .bezier` evaluates as
    /// `cubic-bezier(K₁.easeOut.x, K₁.easeOut.y, K₂.easeIn.x, K₂.easeIn.y)`.
    /// The curve is parameterized by an internal parameter `s`; we invert x(s) = t via a
    /// few Newton iterations (with bisection fallback), then read y(s).
    public static func solveCubicBezier(_ p1: ControlPoint, _ p2: ControlPoint,
                                        _ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }

        let x1 = min(max(p1.x, 0), 1)
        let x2 = min(max(p2.x, 0), 1)

        // x(s), y(s) for a cubic with endpoints (0,0) and (1,1).
        func bezier(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let mu = 1 - s
            // 3*(1-s)^2*s*a + 3*(1-s)*s^2*b + s^3   (P0=0, P3=1)
            return 3 * mu * mu * s * a + 3 * mu * s * s * b + s * s * s
        }
        func bezierDeriv(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let mu = 1 - s
            return 3 * mu * mu * a + 6 * mu * s * (b - a) + 3 * s * s * (1 - b)
        }

        // Find s such that x(s) == t.
        var s = t // good initial guess: curve is near-diagonal
        for _ in 0..<8 {
            let x = bezier(x1, x2, s) - t
            if abs(x) < 1e-7 { break }
            let d = bezierDeriv(x1, x2, s)
            if abs(d) < 1e-9 { break }
            s -= x / d
        }
        // Bisection fallback if Newton wandered out of range.
        if s < 0 || s > 1 || s.isNaN {
            var lo = 0.0, hi = 1.0
            s = t
            for _ in 0..<20 {
                s = (lo + hi) / 2
                let x = bezier(x1, x2, s)
                if x < t { lo = s } else { hi = s }
            }
        }
        return bezier(p1.y, p2.y, s)
    }
}
