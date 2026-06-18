import Foundation
import MotionKernel

/// An offline, no-LLM generator (ai-pipeline.md §9 step 1 spirit): maps a natural-language prompt to
/// a pattern + character via keyword matching and emits the corresponding `ApplyPattern` / `Stagger`
/// macro on the selected layers (or all layers when nothing is selected). Lets the AI panel work
/// without a backend/key, and is the deterministic baseline the eval harness compares against.
public struct HeuristicGenerator: MotionGenerator {
    public init() {}

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let prompt = request.prompt.lowercased()
        let pattern = Self.matchPattern(prompt) ?? .fadeIn
        let character = Self.matchCharacter(prompt) ?? .snappy

        let targetIds = request.digest.selectionIds.isEmpty
            ? request.digest.layers.map(\.id)
            : request.digest.selectionIds
        guard !targetIds.isEmpty else {
            throw GenerationError.unrecoverable(feedback: "no layers to animate")
        }
        let ids = targetIds.map { EntityID($0) }
        let params = PatternParams(at: request.playhead, duration: 0.6, character: character)
        let commands: [AnyCommand] = ids.count > 1
            ? [.stagger(layerIds: ids, pattern: pattern, params: params, gap: 0.08)]
            : [.applyPattern(layerId: ids[0], pattern: pattern, params: params)]

        return GenerationResult(
            plan: "Apply \(pattern.displayName) (\(character.displayName)) to \(ids.count) layer\(ids.count == 1 ? "" : "s").",
            label: pattern.displayName,
            commands: commands)
    }

    static func matchPattern(_ p: String) -> MotionPattern? {
        // Order matters: check more-specific phrases first.
        let table: [(String, MotionPattern)] = [
            ("fade out", .fadeOut), ("pop out", .popOut),
            ("slide up", .slideInUp), ("slide down", .slideInDown),
            ("slide left", .slideInLeft), ("slide right", .slideInRight),
            ("scale", .scaleReveal), ("reveal", .scaleReveal),
            ("pop", .popIn), ("fade", .fadeIn),
            ("bounce", .bounce), ("pulse", .pulse), ("shake", .shake),
            ("exit", .fadeOut), ("out", .fadeOut), ("in", .fadeIn),
        ]
        return table.first { p.contains($0.0) }?.1
    }

    static func matchCharacter(_ p: String) -> MotionCharacter? {
        if p.contains("gentle") || p.contains("soft") || p.contains("smooth") { return .gentle }
        if p.contains("bouncy") || p.contains("bounce") { return .bouncy }
        if p.contains("dramatic") || p.contains("strong") || p.contains("big") { return .dramatic }
        if p.contains("snappy") || p.contains("snap") || p.contains("quick") { return .snappy }
        return nil
    }
}
