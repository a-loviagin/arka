import Foundation

/// Closed-form damped-harmonic spring parameters (properties-and-commands.md appendix).
///
/// Evaluated analytically (no simulation stepping) so export is deterministic and a frame
/// at time `t` never depends on how we got there.
public struct Spring: Codable, Sendable, Equatable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double, damping: Double, mass: Double = 1) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    // Designer-tuned presets (appendix). mass 1 throughout.
    public static let gentle = Spring(stiffness: 120, damping: 20)
    public static let snappy = Spring(stiffness: 300, damping: 24)
    public static let bouncy = Spring(stiffness: 260, damping: 12)

    /// Undamped natural frequency ω₀ = √(stiffness/mass).
    public var omega0: Double { (stiffness / mass).squareRoot() }

    /// Damping ratio ζ = damping / (2·√(stiffness·mass)).
    public var dampingRatio: Double { damping / (2 * (stiffness * mass).squareRoot()) }

    /// Displacement from target at elapsed time `t`, given initial offset-from-target `x0`
    /// and initial velocity `v0`. `value = target + displacement(...)`.
    ///
    /// Pass the previous segment's outgoing velocity as `v0` so chained springs don't stall.
    public func displacement(x0: Double, v0: Double, at t: Double) -> Double {
        if t <= 0 { return x0 }
        let w0 = omega0
        let zeta = dampingRatio

        if zeta < 1 { // underdamped (the motion-design case)
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let envelope = (-zeta * w0 * t).exp
            let a = x0
            let b = (v0 + zeta * w0 * x0) / wd
            return envelope * (a * (wd * t).cos + b * (wd * t).sin)
        } else if abs(zeta - 1) < 1e-9 { // critically damped
            let envelope = (-w0 * t).exp
            return envelope * (x0 + (v0 + w0 * x0) * t)
        } else { // overdamped — two real exponentials (UI clamps ζ ≤ 1, but be correct)
            let r = w0 * (zeta * zeta - 1).squareRoot()
            let r1 = -zeta * w0 + r
            let r2 = -zeta * w0 - r
            let c1 = (v0 - r2 * x0) / (r1 - r2)
            let c2 = x0 - c1
            return c1 * (r1 * t).exp + c2 * (r2 * t).exp
        }
    }

    /// Outgoing velocity at time `t` — fed as `v0` into a subsequent chained spring.
    public func velocity(x0: Double, v0: Double, at t: Double) -> Double {
        // Numerical derivative is plenty for chaining continuity.
        let h = 1e-4
        let d1 = displacement(x0: x0, v0: v0, at: t + h)
        let d0 = displacement(x0: x0, v0: v0, at: t - h)
        return (d1 - d0) / (2 * h)
    }

    /// Smallest `t` where |displacement| < ε·|x0| — the settle-time badge for the timeline UI.
    /// Solved numerically once per parameter change and cached by the caller.
    public func settleTime(x0: Double, v0: Double, epsilon: Double = 0.001) -> Double {
        guard x0 != 0 || v0 != 0 else { return 0 }
        let threshold = epsilon * max(abs(x0), 1e-9)
        let step = 1.0 / 240.0
        var t = 0.0
        let limit = 30.0 // hard cap; pathological params shouldn't hang the UI
        while t < limit {
            if abs(displacement(x0: x0, v0: v0, at: t)) < threshold { return t }
            t += step
        }
        return limit
    }
}

// Small Double conveniences so the formulas above read like the appendix.
private extension Double {
    var exp: Double { Foundation.exp(self) }
    var sin: Double { Foundation.sin(self) }
    var cos: Double { Foundation.cos(self) }
}
