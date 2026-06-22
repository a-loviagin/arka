import XCTest
@testable import MotionAI
import MotionKernel

/// Few-shot exemplar library + retrieval (ai-pipeline.md §6.4): the mechanism by which the tool
/// learns from examples without fine-tuning.
final class ExemplarLibraryTests: XCTestCase {
    func testRetrievesMostRelevantExemplarFirst() {
        let lib = ExemplarLibrary.builtin
        XCTAssertEqual(lib.retrieve(for: "fade the logo in", k: 3).first?.id, "ex_fade_logo")
        XCTAssertEqual(lib.retrieve(for: "slide the cards up one by one", k: 3).first?.id, "ex_stagger_cards")
        XCTAssertEqual(lib.retrieve(for: "give the title a bouncy pop", k: 3).first?.id, "ex_pop_title")
    }

    func testIrrelevantPromptRetrievesNothing() {
        XCTAssertTrue(ExemplarLibrary.builtin.retrieve(for: "xyzzy qwerty", k: 4).isEmpty)
    }

    func testRetrievalRespectsK() {
        XCTAssertLessThanOrEqual(ExemplarLibrary.builtin.retrieve(for: "fade in pop slide reveal pulse exit", k: 2).count, 2)
    }

    func testSystemPromptInjectsExemplars() {
        let chosen = ExemplarLibrary.builtin.retrieve(for: "fade the logo in", k: 2)
        XCTAssertFalse(chosen.isEmpty)
        let prompt = SystemPrompt.text(exemplars: chosen)
        XCTAssertTrue(prompt.contains("FEW-SHOT EXEMPLARS"))
        XCTAssertTrue(prompt.contains(chosen[0].intent), "the exemplar intent is in the prompt")
        XCTAssertTrue(prompt.contains("ApplyPattern"), "the exemplar's command JSON is included")
        // Empty exemplars ⇒ unchanged base prompt.
        XCTAssertEqual(SystemPrompt.text(exemplars: []), SystemPrompt.text())
    }

    func testClientRequestBodyCarriesRetrievedExemplars() {
        let client = AnthropicClient(config: .init(apiKey: "test"))
        let digest = DocumentDigest.summarize(
            MotionDocument(id: "d",
                           compositions: [Composition(id: "c", size: Vec2(100, 100), fps: 60, duration: 2,
                                                       layers: [Layer(id: "logo", name: "Logo", sortKey: "a0",
                                                                      content: .shape(ShapeContent(geometry: .rect)))])],
                           mainCompositionId: "c"),
            compId: "c")!
        let req = GenerationRequest(prompt: "fade the logo in", mode: .edit, digest: digest)
        let body = client.requestBody(for: req)
        let system = try? XCTUnwrap(body["system"] as? String)
        XCTAssertTrue((system ?? "").contains("FEW-SHOT EXEMPLARS"))
    }

    func testBuiltinExemplarsRoundTripJSON() throws {
        for ex in ExemplarLibrary.builtin.exemplars {
            let data = try JSONEncoder().encode(ex.commands)
            let back = try JSONDecoder().decode([AnyCommand].self, from: data)
            XCTAssertEqual(back, ex.commands, "exemplar \(ex.id) must stay wire-valid as the schema evolves")
        }
    }
}
