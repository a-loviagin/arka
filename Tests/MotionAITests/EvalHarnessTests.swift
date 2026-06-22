import XCTest
@testable import MotionAI
import MotionKernel

/// The eval harness (ai-pipeline.md §8): layered validity + structural checks, run offline against
/// the deterministic `HeuristicGenerator` baseline. These are the CI gate for prompt / pattern /
/// (later) exemplar changes.
final class EvalHarnessTests: XCTestCase {
    private func doc(layers: [Layer]) -> MotionDocument {
        let comp = Composition(id: "c", size: Vec2(400, 400), fps: 60, duration: 3, layers: layers)
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }
    private func shape(_ id: String, _ key: String) -> Layer {
        Layer(id: EntityID(id), name: id, sortKey: SortKey(key),
              content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(80, 80)))))
    }

    private var scenarios: [EvalScenario] {
        let single = doc(layers: [shape("a", "a0")])
        let multi = doc(layers: [shape("a", "a0"), shape("b", "a1"), shape("c", "a2")])
        return [
            EvalScenario(name: "fade in (single)", document: single, compId: "c", prompt: "fade it in",
                         checks: [.producesAnimation, .layerAnimated("a"), .keyframesInRange]),
            EvalScenario(name: "bouncy pop (single)", document: single, compId: "c", prompt: "make it pop, bouncy",
                         checks: [.producesAnimation, .keyframesInRange]),
            EvalScenario(name: "stagger slide up (multi)", document: multi, compId: "c",
                         prompt: "slide them up one after another",
                         checks: [.producesAnimation, .layerAnimated("a"), .layerAnimated("c"), .keyframesInRange]),
        ]
    }

    func testHeuristicBaselinePassesAllScenarios() async {
        let report = await EvalHarness().run(scenarios)
        XCTAssertTrue(report.allPassed, "baseline regressed:\n\(report.summary)")
        XCTAssertEqual(report.total, 3)
        XCTAssertTrue(report.cases.allSatisfy { $0.commandCount >= 1 })
    }

    func testHarnessFlagsAGeneratorThatDoesNotAnimate() async {
        // A generator that emits a no-op (rename) command: valid commands, but no animation → the
        // pipeline's lint rejects it, so the case is invalid (caught, not a silent pass).
        struct NoAnimGenerator: MotionGenerator {
            func generate(_ r: GenerationRequest) async throws -> GenerationResult {
                GenerationResult(plan: "p", label: "l",
                                 commands: [.setLayerName(layerId: "a", name: "Renamed")])
            }
        }
        let s = EvalScenario(name: "noop", document: doc(layers: [shape("a", "a0")]), compId: "c",
                             prompt: "do nothing useful", checks: [.producesAnimation])
        let report = await EvalHarness(generator: NoAnimGenerator()).run([s])
        XCTAssertFalse(report.allPassed)
        XCTAssertFalse(report.cases[0].valid, "no-animation result is rejected by the pipeline lint")
    }

    func testStructuralCheckCatchesWrongLayer() async {
        // Selecting only "a" animates "a"; a check that "b" animated must fail.
        let two = doc(layers: [shape("a", "a0"), shape("b", "a1")])
        let s = EvalScenario(name: "wrong target", document: two, compId: "c", prompt: "fade in",
                             selection: ["a"], checks: [.layerAnimated("b")])
        let report = await EvalHarness().run([s])
        XCTAssertTrue(report.cases[0].valid, "commands are valid")
        XCTAssertFalse(report.cases[0].passed, "but the structural check (wrong layer) fails")
    }
}
