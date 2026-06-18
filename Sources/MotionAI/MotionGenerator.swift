import Foundation

/// Produces a command list for a generation request — implemented by the Anthropic client (live) or
/// the heuristic generator (offline). The validate/repair loop lives in `GenerationPipeline`, which
/// re-calls the generator with `repairFeedback` set.
public protocol MotionGenerator: Sendable {
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
}

public enum GenerationError: Error, CustomStringConvertible, Sendable {
    case provider(String)
    case decoding(String)
    case unrecoverable(feedback: String)
    case notConfigured(String)

    public var description: String {
        switch self {
        case .provider(let m): "generation provider error: \(m)"
        case .decoding(let m): "could not decode the model's output: \(m)"
        case .unrecoverable(let f): "generation failed after repair attempts: \(f)"
        case .notConfigured(let m): "generation not configured: \(m)"
        }
    }
}
