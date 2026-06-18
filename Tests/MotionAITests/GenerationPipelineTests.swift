import XCTest
@testable import MotionAI
import MotionKernel

/// A generator that returns scripted results in order — to drive the repair loop in tests.
private final class ScriptedGenerator: MotionGenerator, @unchecked Sendable {
    private var results: [GenerationResult]
    private(set) var calls: [GenerationRequest] = []
    init(_ results: [GenerationResult]) { self.results = results }
    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        calls.append(request)
        return results.count > 1 ? results.removeFirst() : results[0] // keep returning the last script
    }
}

final class GenerationPipelineTests: XCTestCase {
    private func doc() -> MotionDocument {
        let layer = Layer(id: "logo", name: "Logo", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)))),
                          transform: Transform(position: .static(Vec2(50, 50)), opacity: .static(1)))
        let comp = Composition(id: "c", size: Vec2(200, 200), fps: 60, duration: 2, layers: [layer])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }
    private func request(_ d: MotionDocument) -> GenerationRequest {
        GenerationRequest(prompt: "pop in", mode: .edit,
                          digest: DocumentDigest.summarize(d, compId: "c", selection: ["logo"])!,
                          playhead: 0)
    }

    func testValidResultPassesThrough() async throws {
        let d = doc()
        let good = GenerationResult(plan: "p", label: "Pop In",
                                    commands: [.applyPattern(layerId: "logo", pattern: .popIn, params: PatternParams())])
        let pipeline = GenerationPipeline(generator: ScriptedGenerator([good]))
        let result = try await pipeline.generate(request(d), against: d)
        XCTAssertEqual(result.label, "Pop In")
    }

    func testRepairsAfterInvalidThenValid() async throws {
        let d = doc()
        // First result references a non-existent layer (validation fails) → repair → valid.
        let bad = GenerationResult(plan: "p", label: "x",
                                   commands: [.setKeyframe(path: "ghost/transform/opacity",
                                                           keyframe: AnyKeyframe(t: 0, v: .scalar(1)))])
        let good = GenerationResult(plan: "p", label: "Fade In",
                                    commands: [.applyPattern(layerId: "logo", pattern: .fadeIn, params: PatternParams())])
        let gen = ScriptedGenerator([bad, good])
        let pipeline = GenerationPipeline(generator: gen)
        let result = try await pipeline.generate(request(d), against: d)
        XCTAssertEqual(result.label, "Fade In")
        XCTAssertEqual(gen.calls.count, 2, "one repair retry")
        XCTAssertNotNil(gen.calls[1].repairFeedback, "repair feedback fed back to the model")
    }

    func testGivesUpAfterMaxRepairs() async throws {
        let d = doc()
        let bad = GenerationResult(plan: "p", label: "x", commands: []) // always invalid (no commands)
        let pipeline = GenerationPipeline(generator: ScriptedGenerator([bad]), maxRepairs: 2)
        do {
            _ = try await pipeline.generate(request(d), against: d)
            XCTFail("should have thrown")
        } catch let error as GenerationError {
            guard case .unrecoverable = error else { return XCTFail("expected .unrecoverable") }
        }
    }

    func testHeuristicMapsPromptToPattern() async throws {
        let d = doc()
        let gen = HeuristicGenerator()
        let req = GenerationRequest(prompt: "make it bounce in, bouncy", mode: .edit,
                                    digest: DocumentDigest.summarize(d, compId: "c", selection: ["logo"])!)
        let result = try await gen.generate(req)
        guard case .applyPattern(_, let pattern, let params) = result.commands.first else {
            return XCTFail("expected applyPattern")
        }
        XCTAssertEqual(pattern, .bounce)
        XCTAssertEqual(params.character, .bouncy)
    }

    func testHeuristicEndToEndThroughPipeline() async throws {
        let d = doc()
        let pipeline = GenerationPipeline(generator: HeuristicGenerator())
        let req = GenerationRequest(prompt: "pop in snappy", mode: .edit,
                                    digest: DocumentDigest.summarize(d, compId: "c", selection: ["logo"])!)
        let result = try await pipeline.generate(req, against: d)
        // The macro validates + applies cleanly against the real document.
        XCTAssertFalse(result.commands.isEmpty)
    }
}
