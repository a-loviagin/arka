import Foundation

/// A deterministic, quantitative fingerprint of a clip's motion (ai-pipeline.md §3) — derived purely
/// from frames, no model. Two uses:
///   • grounds the vision analyzer's semantic labels in real timing (when did motion happen, how
///     much, what colors);
///   • is the **render-compare verifier**: render a synthesized candidate, take its signature, and
///     `distance(to:)` the source clip's — "find the command list whose render best matches the clip."
///
/// Foundation-only so it's shared by the render layer (which extracts it from pixels) and MotionAI
/// (which consumes it). The extractor lives in `MotionRender`.
public struct MotionSignature: Codable, Sendable, Equatable {
    /// Sampling rate the activity curve was measured at.
    public var fps: Double
    /// Per-adjacent-frame change, normalized 0…1 (count = frames − 1). The clip's "motion over time".
    public var activity: [Double]
    /// Dominant colors as #RRGGBB.
    public var palette: [String]
    /// Times (seconds) where motion rises through the onset threshold — entrance/beat moments.
    public var onsets: [TimeInterval]

    public init(fps: Double, activity: [Double], palette: [String] = [], onsets: [TimeInterval] = []) {
        self.fps = fps; self.activity = activity; self.palette = palette; self.onsets = onsets
    }

    /// Clip length implied by the activity curve.
    public var duration: TimeInterval { fps > 0 ? Double(activity.count) / fps : 0 }
    /// Mean motion magnitude (overall "busy-ness").
    public var meanActivity: Double { activity.isEmpty ? 0 : activity.reduce(0, +) / Double(activity.count) }

    /// 0 = matching motion (timing curve + onset count); higher = more different. Activity curves are
    /// resampled to a common length so clips of different fps/length compare fairly.
    public func distance(to other: MotionSignature) -> Double {
        let n = 32
        let a = Self.resample(activity, to: n), b = Self.resample(other.activity, to: n)
        let curve = zip(a, b).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(n)
        let onsetPenalty = abs(Double(onsets.count) - Double(other.onsets.count)) * 0.05
        return curve + onsetPenalty
    }

    static func resample(_ xs: [Double], to n: Int) -> [Double] {
        guard xs.count > 1 else { return Array(repeating: xs.first ?? 0, count: n) }
        return (0..<n).map { i in
            let p = Double(i) / Double(n - 1) * Double(xs.count - 1)
            let lo = Int(p), hi = Swift.min(lo + 1, xs.count - 1)
            let f = p - Double(lo)
            return xs[lo] * (1 - f) + xs[hi] * f
        }
    }
}
