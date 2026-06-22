import XCTest
@testable import MotionAI
import MotionKernel

/// Reference-clip taste engine (ai-pipeline.md §3): a `VideoMotionAnalysis` (from a clip) synthesizes
/// editable commands / a reusable exemplar, and a corpus distills into a `TasteProfile`.
final class VideoTasteTests: XCTestCase {
    private func analysis() -> VideoMotionAnalysis {
        VideoMotionAnalysis(
            summary: "title pops in, then three cards slide up one after another",
            palette: ["#5B8CFF", "#C44CFF"],
            elements: [
                .init(role: "title", pattern: .popIn, character: .bouncy, start: 0, duration: 0.6),
                .init(role: "card", pattern: .slideInUp, character: .snappy, start: 0.4, duration: 0.5, count: 3),
            ],
            staggerGap: 0.09)
    }

    func testSynthesizesCommandsOntoExistingLayers() {
        let cmds = TasteSynthesizer.commands(from: analysis(),
                                             layerIds: ["t", "c1", "c2", "c3"])
        XCTAssertEqual(cmds.count, 2, "one ApplyPattern (title) + one Stagger (3 cards)")
        guard case .applyPattern(let lid, let pat, _) = cmds[0] else { return XCTFail("expected ApplyPattern") }
        XCTAssertEqual(lid, "t"); XCTAssertEqual(pat, .popIn)
        guard case .stagger(let ids, let p2, _, let gap) = cmds[1] else { return XCTFail("expected Stagger") }
        XCTAssertEqual(ids, ["c1", "c2", "c3"]); XCTAssertEqual(p2, .slideInUp)
        XCTAssertEqual(gap, 0.09, accuracy: 1e-9, "uses the analysis stagger gap")
    }

    func testExemplarFromClipIsRetrievableAndWireValid() throws {
        let ex = TasteSynthesizer.exemplar(from: analysis(), id: "clip_hero")
        XCTAssertEqual(ex.intent, analysis().summary)
        XCTAssertTrue(ex.tags.contains("card") && ex.tags.contains("popIn"))
        // Round-trips as wire-valid commands, so it can live in the library like any exemplar.
        let data = try JSONEncoder().encode(ex.commands)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), ex.commands)

        // And it's retrievable from a library by its summary terms.
        let lib = ExemplarLibrary([ex])
        XCTAssertEqual(lib.retrieve(for: "cards slide up", k: 1).first?.id, "clip_hero")
    }

    func testTasteProfileDistillsCorpus() throws {
        let profile = try XCTUnwrap(TasteProfile.from([analysis(), analysis()]))
        XCTAssertEqual(profile.dominantCharacter, .snappy, "cards (snappy) outnumber the title (bouncy)")
        XCTAssertEqual(profile.medianElementDuration, 0.5, accuracy: 1e-9, "cards (0.5, weighted ×3) dominate")
        XCTAssertEqual(profile.typicalStaggerGap ?? 0, 0.09, accuracy: 1e-9)
        XCTAssertEqual(profile.palette.first, "#5B8CFF")
        let doctrine = profile.doctrine()
        XCTAssertTrue(doctrine.contains("snappy") && doctrine.contains("LIBRARY TASTE"))
    }

    func testTasteProfileInjectedIntoSystemPrompt() throws {
        let profile = try XCTUnwrap(TasteProfile.from([analysis()]))
        let prompt = SystemPrompt.text(exemplars: [], taste: profile)
        XCTAssertTrue(prompt.contains("LIBRARY TASTE"))
        XCTAssertEqual(SystemPrompt.text(exemplars: [], taste: nil), SystemPrompt.text())
    }
}
