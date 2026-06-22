import Foundation
import MotionKernel

/// The eval harness (ai-pipeline.md §8) — built *before* the feature so no prompt / model /
/// pattern-library / exemplar change ships on vibes. A scenario is a starting document + prompt with
/// layered checks:
///   • Layer 1 (validity): the pipeline produced commands that decode, validate, and apply clean.
///   • Layer 2 (structural): per-scenario assertions on the resulting document (something animates,
///     the right layers move, durations stay in range, …).
/// Layers 3–5 (VLM judge / human / accept-rate) live outside this Foundation-only harness; this is
/// the fully-automatable core that runs in CI.
public struct StructuralCheck: Sendable {
    public let label: String
    public let test: @Sendable (_ result: MotionDocument, _ compId: EntityID) -> Bool

    public init(_ label: String, _ test: @escaping @Sendable (MotionDocument, EntityID) -> Bool) {
        self.label = label
        self.test = test
    }

    /// At least one layer in the comp gained an animated track.
    public static var producesAnimation: StructuralCheck {
        StructuralCheck("produces animation") { doc, compId in
            guard let comp = doc.composition(compId) else { return false }
            return comp.layers.contains { !TimelineDigest.tracks(for: $0).isEmpty }
        }
    }

    /// The comp has at least `n` layers after applying (for `create` prompts that should add content).
    public static func minLayers(_ n: Int) -> StructuralCheck {
        StructuralCheck("≥ \(n) layers") { doc, compId in (doc.composition(compId)?.layers.count ?? 0) >= n }
    }

    /// A specific layer ended up animated (for `edit` prompts that target a selection).
    public static func layerAnimated(_ id: EntityID) -> StructuralCheck {
        StructuralCheck("layer \(id) animated") { doc, compId in
            guard let layer = doc.composition(compId)?.layer(id) else { return false }
            return !TimelineDigest.tracks(for: layer).isEmpty
        }
    }

    /// Every keyframe across the comp sits within [0, duration] (no off-timeline keys).
    public static var keyframesInRange: StructuralCheck {
        StructuralCheck("keyframes within duration") { doc, compId in
            guard let comp = doc.composition(compId) else { return false }
            return comp.layers.allSatisfy { layer in
                TimelineDigest.tracks(for: layer).allSatisfy { track in
                    track.times.allSatisfy { $0 >= -1e-6 && $0 <= comp.duration + 1e-6 }
                }
            }
        }
    }
}

public struct EvalScenario: Sendable {
    public var name: String
    public var document: MotionDocument
    public var compId: EntityID
    public var prompt: String
    public var mode: GenerationRequest.Mode
    public var selection: Set<EntityID>
    public var playhead: TimeInterval
    public var checks: [StructuralCheck]

    public init(name: String, document: MotionDocument, compId: EntityID, prompt: String,
                mode: GenerationRequest.Mode = .edit, selection: Set<EntityID> = [],
                playhead: TimeInterval = 0, checks: [StructuralCheck]) {
        self.name = name; self.document = document; self.compId = compId; self.prompt = prompt
        self.mode = mode; self.selection = selection; self.playhead = playhead; self.checks = checks
    }
}

public struct EvalCaseResult: Sendable {
    public var scenario: String
    public var valid: Bool                 // layer 1
    public var error: String?
    public var commandCount: Int
    public var checks: [(label: String, passed: Bool)]
    public var passed: Bool { valid && checks.allSatisfy(\.passed) }
}

public struct EvalReport: Sendable {
    public var cases: [EvalCaseResult]
    public var passCount: Int { cases.filter(\.passed).count }
    public var total: Int { cases.count }
    public var allPassed: Bool { passCount == total }

    /// A compact human-readable scorecard, e.g. for CI logs.
    public var summary: String {
        var lines = ["Eval: \(passCount)/\(total) passed"]
        for c in cases where !c.passed {
            if !c.valid { lines.append("  ✗ \(c.scenario): invalid — \(c.error ?? "?")") }
            else {
                let failed = c.checks.filter { !$0.passed }.map(\.label).joined(separator: ", ")
                lines.append("  ✗ \(c.scenario): failed [\(failed)]")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs eval scenarios through the real generation pipeline (validate + repair) so the harness
/// exercises the same path production uses. Offline by default (a `HeuristicGenerator`), or pass any
/// `MotionGenerator` (e.g. a live client) to eval a model.
public struct EvalHarness: Sendable {
    public let generator: any MotionGenerator
    public let maxRepairs: Int

    public init(generator: any MotionGenerator = HeuristicGenerator(), maxRepairs: Int = 2) {
        self.generator = generator
        self.maxRepairs = maxRepairs
    }

    public func run(_ scenarios: [EvalScenario]) async -> EvalReport {
        var cases: [EvalCaseResult] = []
        for s in scenarios { cases.append(await run(s)) }
        return EvalReport(cases: cases)
    }

    private func run(_ s: EvalScenario) async -> EvalCaseResult {
        guard let digest = DocumentDigest.summarize(s.document, compId: s.compId,
                                                    selection: s.selection, at: s.playhead) else {
            return EvalCaseResult(scenario: s.name, valid: false, error: "composition not found",
                                  commandCount: 0, checks: [])
        }
        let request = GenerationRequest(prompt: s.prompt, mode: s.mode, digest: digest, playhead: s.playhead)
        let pipeline = GenerationPipeline(generator: generator, maxRepairs: maxRepairs)
        do {
            let result = try await pipeline.generate(request, against: s.document)
            // Re-apply onto a scratch copy to evaluate structural checks against the outcome.
            var scratch = s.document
            for cmd in result.commands { try cmd.apply(to: &scratch) }
            let checks = s.checks.map { ($0.label, $0.test(scratch, s.compId)) }
            return EvalCaseResult(scenario: s.name, valid: true, error: nil,
                                  commandCount: result.commands.count, checks: checks)
        } catch {
            return EvalCaseResult(scenario: s.name, valid: false, error: "\(error)",
                                  commandCount: 0, checks: s.checks.map { ($0.label, false) })
        }
    }
}
