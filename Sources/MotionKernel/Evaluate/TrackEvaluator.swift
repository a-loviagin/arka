import Foundation

// The deterministic core (motion-document-schema.md §5, render-engine.md §1): a pure (track, t) → V
// function. No side effects, no caching in v1 — this is what the golden-frame and evaluate-stage
// tests pin down before any UI exists. The render engine's "cache last-hit segment for monotonic
// playback" is a later optimization that must not change results.

public extension Track where V: Componentwise {
    /// Resolve this single track's value at comp-time `t`.
    func value(at t: TimeInterval) -> V {
        let kfs = keyframes
        guard let first = kfs.first else { return V.fromComponents { _ in 0 } }
        if t <= first.t { return first.v }
        guard let last = kfs.last else { return first.v }
        if t >= last.t { return last.v }

        // Binary search for the segment [k1, k2] with k1.t <= t < k2.t.
        var lo = 0
        var hi = kfs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if kfs[mid].t <= t { lo = mid } else { hi = mid }
        }
        let k1 = kfs[lo]
        let k2 = kfs[hi]
        let span = k2.t - k1.t
        let u = span > 0 ? (t - k1.t) / span : 0

        switch k1.interp {
        case .hold:
            return k1.v
        case .linear:
            return V.lerp(k1.v, k2.v, u)
        case .bezier:
            let eo = k1.easeOut ?? Easing.defaultEaseOut
            let ei = k2.easeIn ?? Easing.defaultEaseIn
            let eased = Easing.solveCubicBezier(eo, ei, u)
            if k1.spatialOut != nil || k2.spatialIn != nil {
                return V.cubic(k1.v, k2.v, outT: k1.spatialOut, inT: k2.spatialIn, eased)
            }
            return V.lerp(k1.v, k2.v, eased)
        case .spring(let spring):
            // Closed-form spring per component: start at k1.v, target k2.v. Time belongs to the
            // segment even if the spring's settle extends past it (the overshoot is intentional).
            let elapsed = t - k1.t
            return V.fromComponents { c in
                let target = k2.v.component(c)
                let x0 = k1.v.component(c) - target
                return target + spring.displacement(x0: x0, v0: 0, at: elapsed)
            }
        }
    }
}

public extension AnimatableValue where V: Componentwise {
    /// Resolve to a concrete value at comp-time `t`. Handles static values, a single combined
    /// track, and separated-dimension tracks (a combined base overridden per named component).
    func resolve(at t: TimeInterval) -> V {
        switch self {
        case .static(let v):
            return v
        case .animated(let tracks):
            var base: V?
            var overrides: [Component: Double] = [:]
            for track in tracks where !track.keyframes.isEmpty {
                let tv = track.value(at: t)
                if let comp = track.component {
                    overrides[comp] = tv.component(comp)
                } else {
                    base = tv
                }
            }
            if overrides.isEmpty {
                return base ?? V.fromComponents { _ in 0 }
            }
            let b = base
            return V.fromComponents { c in overrides[c] ?? b?.component(c) ?? 0 }
        }
    }
}
