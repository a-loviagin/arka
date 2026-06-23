import XCTest
@testable import MotionAI
import MotionKernel

/// The persisted taste library behind "teach the style" — data, not training.
final class TasteStoreTests: XCTestCase {
    private func analysis(_ summary: String, _ char: MotionCharacter) -> VideoMotionAnalysis {
        VideoMotionAnalysis(summary: summary, palette: ["#5B8CFF"],
                            elements: [.init(role: "title", pattern: .popIn, character: char, duration: 0.5)])
    }

    func testAddStoresAnalysisAndRetrievableExemplar() {
        var store = TasteStore()
        store.add(analysis("cards slide up", .snappy), id: "c1")
        XCTAssertEqual(store.exemplars.count, 1)
        XCTAssertEqual(store.analyses.count, 1)
        XCTAssertEqual(store.exemplarLibrary.retrieve(for: "cards slide", k: 1).first?.id, "c1")
    }

    func testRemoveDropsAnalysisAndExemplarTogether() {
        var store = TasteStore()
        store.add(analysis("a", .snappy), id: "x")
        store.add(analysis("b", .bouncy), id: "y")
        store.removeExemplar(id: "x")
        XCTAssertEqual(store.exemplars.map(\.id), ["y"])
        XCTAssertEqual(store.analyses.count, 1, "analysis removed in lockstep")
    }

    func testMergeAndProfile() {
        var global = TasteStore(); global.add(analysis("g", .gentle), id: "g")
        var project = TasteStore(); project.add(analysis("p", .snappy), id: "p")
        let merged = global.merged(with: project)
        XCTAssertEqual(merged.exemplars.count, 2)
        XCTAssertNotNil(TasteProfile.from(merged.analyses))
    }

    func testPersistenceRoundTrips() throws {
        var store = TasteStore()
        store.add(analysis("looping pulse", .gentle), id: "z")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("taste_\(UInt32.random(in: 0 ..< .max)).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.save(to: url)
        let back = TasteStore.load(from: url)
        XCTAssertEqual(back, store)
        // Missing file loads as empty, never throws.
        XCTAssertTrue(TasteStore.load(from: url.appendingPathExtension("nope")).isEmpty)
    }
}
