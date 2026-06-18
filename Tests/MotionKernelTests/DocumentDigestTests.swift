import XCTest
@testable import MotionKernel

final class DocumentDigestTests: XCTestCase {
    func testSummarizesLayersAndSelection() throws {
        let doc = Fixtures.sampleDocument() // bg(shape), logo(shape, animated pos+opacity), label(text, child of logo)
        let digest = try XCTUnwrap(DocumentDigest.summarize(doc, compId: "comp_main",
                                                            selection: ["layer_logo"]))
        XCTAssertEqual(digest.comp.size, [1920, 1080])
        XCTAssertEqual(digest.comp.fps, 60)
        XCTAssertEqual(digest.selectionIds, ["layer_logo"])
        XCTAssertEqual(digest.layers.count, 3)

        let logo = try XCTUnwrap(digest.layers.first { $0.id == "layer_logo" })
        XCTAssertEqual(logo.type, "shape")
        XCTAssertTrue(logo.selected)
        XCTAssertTrue(logo.animated.contains("transform/position"))
        XCTAssertTrue(logo.animated.contains("transform/opacity"))
        XCTAssertEqual(logo.keyframeCount, 4, "2 position + 2 opacity")
        XCTAssertNotNil(logo.frame)

        let label = try XCTUnwrap(digest.layers.first { $0.id == "layer_label" })
        XCTAssertEqual(label.type, "text")
        XCTAssertEqual(label.text, "Ship faster")
        XCTAssertEqual(label.parentId, "layer_logo")

        // Selected layer travels as full JSON for precise editing.
        XCTAssertEqual(digest.selectedLayers.map(\.id), ["layer_logo"])
    }

    func testDigestIsCodable() throws {
        let doc = Fixtures.sampleDocument()
        let digest = try XCTUnwrap(DocumentDigest.summarize(doc, compId: "comp_main"))
        let data = try JSONEncoder().encode(digest)
        let back = try JSONDecoder().decode(DocumentDigest.self, from: data)
        XCTAssertEqual(back, digest)
    }
}
