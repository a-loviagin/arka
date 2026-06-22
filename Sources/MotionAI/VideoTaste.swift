import Foundation
import MotionKernel

/// A structured description of a reference clip's motion, in *our* vocabulary (ai-pipeline.md §3).
/// This is the bridge that lets raw mov/mp4/gif feed the taste engine: a clip is never used as
/// pixels for generation — it's analyzed once into this form (by a `VideoMotionAnalyzer`), which
/// then synthesizes editable commands and aggregates into a `TasteProfile`. No pixel-level motion
/// extraction; described motion + the pattern library gets close, and the result is fully editable.
public struct VideoMotionAnalysis: Codable, Sendable, Equatable {
    /// One moving thing in the clip, mapped to a pattern + character + timing. `count > 1` means a
    /// group that enters as a stagger.
    public struct Element: Codable, Sendable, Equatable {
        public var role: String                 // "title", "logo", "card", "icon", …
        public var pattern: MotionPattern
        public var character: MotionCharacter
        public var start: TimeInterval
        public var duration: TimeInterval
        public var count: Int

        public init(role: String, pattern: MotionPattern, character: MotionCharacter,
                    start: TimeInterval = 0, duration: TimeInterval = 0.5, count: Int = 1) {
            self.role = role; self.pattern = pattern; self.character = character
            self.start = start; self.duration = duration; self.count = max(count, 1)
        }

        // Lenient decode: the model may omit timing/count for simple elements.
        private enum CodingKeys: String, CodingKey { case role, pattern, character, start, duration, count }
        public init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            pattern = try c.decode(MotionPattern.self, forKey: .pattern)
            character = try c.decodeIfPresent(MotionCharacter.self, forKey: .character) ?? .snappy
            start = try c.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
            duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0.5
            count = max(try c.decodeIfPresent(Int.self, forKey: .count) ?? 1, 1)
        }
    }

    public var summary: String          // natural-language intent ("title pops in, cards slide up")
    public var palette: [String]        // dominant colors, hex
    public var elements: [Element]
    public var staggerGap: TimeInterval?

    public init(summary: String, palette: [String] = [], elements: [Element], staggerGap: TimeInterval? = nil) {
        self.summary = summary; self.palette = palette; self.elements = elements; self.staggerGap = staggerGap
    }

    private enum CodingKeys: String, CodingKey { case summary, palette, elements, staggerGap }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        palette = try c.decodeIfPresent([String].self, forKey: .palette) ?? []
        elements = try c.decodeIfPresent([Element].self, forKey: .elements) ?? []
        staggerGap = try c.decodeIfPresent(TimeInterval.self, forKey: .staggerGap)
    }
}

/// Produces a `VideoMotionAnalysis` from sampled clip frames. The live implementation is a Claude
/// vision call (frames in, structured analysis out); an offline implementation can be driven by the
/// CV motion signature. Frames are passed as encoded image bytes so this module stays Foundation-only.
public protocol VideoMotionAnalyzer: Sendable {
    func analyze(frames: [Data], fps: Double, hint: String?) async throws -> VideoMotionAnalysis
}

/// Turns a `VideoMotionAnalysis` into editable kernel commands — the step that makes a reference
/// clip *reproducible* and *reusable*. Pure and deterministic, so it's testable and improvable
/// without the model.
public enum TasteSynthesizer {
    /// Reproduce the analyzed motion on existing layers (elements assigned to layers in order;
    /// grouped elements consume `count` layers as a stagger).
    public static func commands(from a: VideoMotionAnalysis, layerIds: [EntityID]) -> [AnyCommand] {
        var cmds: [AnyCommand] = []
        var i = 0
        for el in a.elements {
            let params = PatternParams(at: el.start, duration: el.duration, character: el.character)
            if el.count > 1 {
                let group = Array(layerIds[i..<min(i + el.count, layerIds.count)])
                if group.count > 1 {
                    cmds.append(.stagger(layerIds: group, pattern: el.pattern, params: params, gap: a.staggerGap ?? 0.08))
                    i += group.count
                } else if let id = group.first {
                    cmds.append(.applyPattern(layerId: id, pattern: el.pattern, params: params)); i += 1
                }
            } else if i < layerIds.count {
                cmds.append(.applyPattern(layerId: layerIds[i], pattern: el.pattern, params: params)); i += 1
            }
        }
        return cmds
    }

    /// Turn an analysis into a reusable few-shot `Exemplar` (illustrative layer ids derived from the
    /// element roles), so an ingested clip becomes taste the model retrieves like any other exemplar.
    public static func exemplar(from a: VideoMotionAnalysis, id: String) -> Exemplar {
        var ids: [EntityID] = []
        for el in a.elements {
            for n in 0..<el.count { ids.append(EntityID(el.count > 1 ? "\(el.role)\(n + 1)" : el.role)) }
        }
        let cmds = commands(from: a, layerIds: ids)
        let tags = a.elements.flatMap { [$0.role, $0.pattern.rawValue, $0.character.rawValue] }
        return Exemplar(id: id, intent: a.summary, tags: Array(Set(tags)), commands: cmds)
    }
}

/// The distilled "house style" across a corpus of analyzed clips — timing norms, dominant easing
/// character, typical stagger gap, palette. Injected as system-prompt doctrine so the library's
/// taste biases every generation, not just retrieved few-shots.
public struct TasteProfile: Sendable, Equatable {
    public var medianElementDuration: TimeInterval
    public var dominantCharacter: MotionCharacter
    public var typicalStaggerGap: TimeInterval?
    public var palette: [String]

    public static func from(_ analyses: [VideoMotionAnalysis]) -> TasteProfile? {
        let elements = analyses.flatMap(\.elements)
        guard !elements.isEmpty else { return nil }
        // Weight by `count` — a 3-element staggered group is three moving things, not one.
        let durations = elements.flatMap { Array(repeating: $0.duration, count: $0.count) }.sorted()
        let gaps = analyses.compactMap(\.staggerGap).sorted()
        var counts: [MotionCharacter: Int] = [:]
        for e in elements { counts[e.character, default: 0] += e.count }
        let dominant = counts.max { $0.value < $1.value }?.key ?? .snappy
        let palette = Array(analyses.flatMap(\.palette).reduce(into: [String]()) { acc, c in
            if !acc.contains(c) { acc.append(c) }
        }.prefix(6))
        return TasteProfile(medianElementDuration: median(durations),
                            dominantCharacter: dominant,
                            typicalStaggerGap: gaps.isEmpty ? nil : median(gaps),
                            palette: palette)
    }

    /// A compact doctrine line for the system prompt.
    public func doctrine() -> String {
        var s = "LIBRARY TASTE (match this house style): entrances ≈ \(Int(medianElementDuration * 1000))ms, "
            + "prefer \(dominantCharacter.rawValue) easing"
        if let g = typicalStaggerGap { s += "; stagger groups by ≈ \(Int(g * 1000))ms" }
        if !palette.isEmpty { s += "; palette \(palette.joined(separator: ", "))" }
        return s + "."
    }

    private static func median(_ xs: [TimeInterval]) -> TimeInterval {
        guard !xs.isEmpty else { return 0 }
        let m = xs.count / 2
        return xs.count % 2 == 0 ? (xs[m - 1] + xs[m]) / 2 : xs[m]
    }
}
