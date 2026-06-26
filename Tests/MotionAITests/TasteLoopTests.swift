import XCTest
@testable import MotionAI
import MotionKernel

/// Closed-loop taste-grounded generation (ROADMAP S1): render-compare candidates against the brand's
/// reference signature, keep the closest, refine with feedback. Uses fakes so the loop is testable
/// without a model or a GPU.
final class TasteLoopTests: XCTestCase {
    private func doc() -> MotionDocument {
        let layer = Layer(id: "l", name: "L", sortKey: "a0", content: .shape(ShapeContent(geometry: .rect)))
        let comp = Composition(id: "c", size: Vec2(100, 100), fps: 60, duration: 2, layers: [layer])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }
    private func request() -> GenerationRequest {
        GenerationRequest(prompt: "animate it on-brand", mode: .edit,
                          digest: DocumentDigest.summarize(doc(), compId: "c")!)
    }

    /// A generator that always emits a valid fade so the pipeline accepts it.
    private struct OKGenerator: MotionGenerator {
        func generate(_ r: GenerationRequest) async throws -> GenerationResult {
            GenerationResult(plan: "p", label: "Fade",
                             commands: [.applyPattern(layerId: "l", pattern: .fadeIn,
                                                      params: PatternParams(at: 0, duration: 0.5))])
        }
    }

    /// A scorer that returns a fixed signature per generation-plan tag (so we control distances).
    private struct ScriptedScorer: CandidateScorer {
        let byPlan: [String: MotionSignature]
        let fallback: MotionSignature
        func signature(for commands: [AnyCommand]) async -> MotionSignature? { fallback }
    }

    func testPicksClosestCandidateToTarget() async {
        let target = MotionSignature(fps: 60, activity: [0.5, 0.5, 0.5], onsets: [0.1])
        // Scorer always returns a signature 0.5-ish — close to target.
        let scorer = ScriptedScorer(byPlan: [:], fallback: MotionSignature(fps: 60, activity: [0.5, 0.5, 0.5], onsets: [0.1]))
        let loop = TasteLoop(pipeline: GenerationPipeline(generator: OKGenerator()),
                             scorer: scorer, candidatesPerRound: 2, maxRounds: 2, acceptDistance: 0.05)
        let out = await loop.run(request(), against: doc(), target: target)
        XCTAssertNotNil(out.best)
        XCTAssertTrue(out.accepted, "an on-target candidate is accepted")
        XCTAssertEqual(out.rounds, 1, "stops once accepted — no needless refine round")
        XCTAssertEqual(out.best?.distance ?? 1, 0, accuracy: 1e-9)
    }

    func testRefinesWhenOffTargetThenStops() async {
        let target = MotionSignature(fps: 60, activity: [0.1, 0.1, 0.1])           // calm
        let off = MotionSignature(fps: 60, activity: [0.9, 0.9, 0.9], onsets: [0.1, 0.3, 0.5]) // busy, far
        let loop = TasteLoop(pipeline: GenerationPipeline(generator: OKGenerator()),
                             scorer: ScriptedScorer(byPlan: [:], fallback: off),
                             candidatesPerRound: 1, maxRounds: 3, acceptDistance: 0.05)
        let out = await loop.run(request(), against: doc(), target: target)
        XCTAssertEqual(out.rounds, 3, "never accepted → uses all refine rounds")
        XCTAssertFalse(out.accepted)
        XCTAssertEqual(out.candidates.count, 3, "one candidate per round")
        XCTAssertGreaterThan(out.best?.distance ?? 0, 0.05)
    }

    func testFeedbackDescribesTheGap() {
        let target = MotionSignature(fps: 60, activity: [0.1, 0.1], onsets: [0.1])
        let busy = MotionSignature(fps: 60, activity: [0.9, 0.9], onsets: [0.1, 0.2, 0.3, 0.4])
        let fb = TasteLoop.feedback(target: target, got: busy)
        XCTAssertTrue(fb.lowercased().contains("busier") || fb.lowercased().contains("calm"))
        XCTAssertTrue(fb.contains("beats"), "calls out the onset-count gap")
    }
}
