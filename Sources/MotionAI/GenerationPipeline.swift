import Foundation
import MotionKernel

/// The generation contract + repair loop (ai-pipeline.md §5): call the generator, decode (typed
/// already), statically validate + scratch-apply each command against the document, run sanity
/// lints; on failure feed the specific error back as a repair prompt (max 2 retries) before giving
/// up. Returns the validated result for the app to apply as one `.ai` transaction.
public struct GenerationPipeline: Sendable {
    public let generator: any MotionGenerator
    public var maxRepairs: Int

    public init(generator: any MotionGenerator, maxRepairs: Int = 2) {
        self.generator = generator
        self.maxRepairs = maxRepairs
    }

    public func generate(_ request: GenerationRequest,
                         against document: MotionDocument) async throws -> GenerationResult {
        var req = request
        var lastFeedback: String?

        for _ in 0...maxRepairs {
            if let lastFeedback { req.repairFeedback = lastFeedback }
            let result = try await generator.generate(req)
            if let feedback = validationFeedback(for: result, against: document) {
                lastFeedback = feedback
                continue
            }
            return result
        }
        throw GenerationError.unrecoverable(feedback: lastFeedback ?? "validation failed")
    }

    /// nil if the result is valid; otherwise a machine-readable error to feed back to the model.
    func validationFeedback(for result: GenerationResult, against document: MotionDocument) -> String? {
        guard !result.commands.isEmpty else { return "Produced no commands. Emit at least one command." }
        var scratch = document
        for (i, command) in result.commands.enumerated() {
            do {
                try command.validate(against: scratch)
                try command.apply(to: &scratch)
            } catch {
                return "Command \(i) failed: \(error). Fix it (check that layer/asset IDs exist, "
                     + "property paths are valid, and keyframe times are within the comp duration)."
            }
        }
        // Sanity lint: the generation should actually animate something.
        if !scratch.compositions.contains(where: { hasAnimation($0) }) {
            return "The result produced no animation. Add keyframes or an ApplyPattern macro."
        }
        return nil
    }

    private func hasAnimation(_ comp: Composition) -> Bool {
        comp.layers.contains { layer in
            !TimelineDigest.tracks(for: layer).isEmpty
        }
    }
}
