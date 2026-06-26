import Foundation
import MotionKernel

/// Closed-loop, taste-grounded generation (ROADMAP S1 — the moat). Few-shot exemplars steer the
/// model toward a brand's style *in the prompt*; this loop adds the feedback half: render each
/// candidate, score its `MotionSignature` against the brand's reference motion, keep the closest, and
/// refine with a signature-delta hint until it's on-brand or rounds run out — "find the command list
/// whose render best matches the brand." Figma's token-grounded keyframes have no equivalent.
///
/// Foundation-only: the rendering is injected via `CandidateScorer`, so the real (Metal) scorer lives
/// in the app while the loop stays unit-testable.
public protocol CandidateScorer: Sendable {
    /// Apply `commands` to the base document, render, and return the resulting motion signature
    /// (nil if it couldn't be rendered).
    func signature(for commands: [AnyCommand]) async -> MotionSignature?
}

public struct ScoredCandidate: Sendable {
    public let result: GenerationResult
    public let signature: MotionSignature
    public let distance: Double   // 0 = matches the target motion; higher = further off
}

public struct TasteLoopResult: Sendable {
    public let best: ScoredCandidate?
    public let candidates: [ScoredCandidate]
    public let rounds: Int
    public var accepted: Bool      // best came in under the accept threshold
}

public struct TasteLoop: Sendable {
    public let pipeline: GenerationPipeline
    public let scorer: any CandidateScorer
    public var candidatesPerRound: Int
    public var maxRounds: Int
    public var acceptDistance: Double

    public init(pipeline: GenerationPipeline, scorer: any CandidateScorer,
                candidatesPerRound: Int = 2, maxRounds: Int = 3, acceptDistance: Double = 0.08) {
        self.pipeline = pipeline
        self.scorer = scorer
        self.candidatesPerRound = max(candidatesPerRound, 1)
        self.maxRounds = max(maxRounds, 1)
        self.acceptDistance = acceptDistance
    }

    /// Generate against `target` (the brand's reference signature), scoring each candidate's render by
    /// signature distance; keep the closest and refine with feedback until under `acceptDistance` or
    /// `maxRounds` is reached.
    public func run(_ request: GenerationRequest, against document: MotionDocument,
                    target: MotionSignature) async -> TasteLoopResult {
        var req = request
        var all: [ScoredCandidate] = []
        var rounds = 0

        for _ in 0..<maxRounds {
            rounds += 1
            for _ in 0..<candidatesPerRound {
                guard let result = try? await pipeline.generate(req, against: document),
                      let sig = await scorer.signature(for: result.commands) else { continue }
                all.append(ScoredCandidate(result: result, signature: sig, distance: target.distance(to: sig)))
            }
            guard let best = all.min(by: { $0.distance < $1.distance }) else { break }
            if best.distance <= acceptDistance { break }
            req.repairFeedback = Self.feedback(target: target, got: best.signature) // refine next round
        }

        let best = all.min(by: { $0.distance < $1.distance })
        return TasteLoopResult(best: best, candidates: all, rounds: rounds,
                               accepted: (best?.distance ?? .infinity) <= acceptDistance)
    }

    /// A short, model-facing hint nudging the next attempt toward the brand's motion feel.
    static func feedback(target: MotionSignature, got: MotionSignature) -> String {
        var notes: [String] = []
        let dActivity = got.meanActivity - target.meanActivity
        if abs(dActivity) > 0.04 {
            notes.append(dActivity > 0
                ? "The motion is busier than the brand's reference — calm it down (slower, fewer simultaneous moves)."
                : "The motion is calmer than the brand's reference — add more energy/movement.")
        }
        let dOnsets = got.onsets.count - target.onsets.count
        if dOnsets > 1 { notes.append("Too many separate motion beats — consolidate; the reference has ~\(target.onsets.count).") }
        if dOnsets < -1 { notes.append("Too few motion beats — stagger more; the reference has ~\(target.onsets.count).") }
        if abs(got.duration - target.duration) > 0.25 {
            notes.append("Aim the overall timing closer to \(String(format: "%.1f", target.duration))s.")
        }
        return notes.isEmpty
            ? "Closer to the brand's motion feel, but keep refining the timing and easing."
            : notes.joined(separator: " ")
    }
}
