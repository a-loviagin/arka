#if os(macOS)
import XCTest
import Metal
@testable import MotionRender
import MotionKernel

/// Text gains an intrinsic size via the CoreText-backed measurer, so it hit-tests and gizmos like
/// any other layer (closing the "text has no size" gap).
final class TextMeasureTests: XCTestCase {
    private func textDoc() -> MotionDocument {
        let layer = Layer(id: "t", name: "Title", sortKey: "a0",
                          content: .text(TextContent(string: "Hello", fontFamily: "Helvetica",
                                                     fontSize: .static(64), fillColor: .static(.white),
                                                     alignment: .center)),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(200, 200))))
        let comp = Composition(id: "c", size: Vec2(400, 400), fps: 60, duration: 1, layers: [layer])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }

    func testMeasurerGivesTextSizeAndHitTest() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let engine = TextEngine(device: device) else {
            throw XCTSkip("No Metal device / text engine")
        }
        let doc = textDoc()

        // Without a measurer: text has no size (and isn't hit-testable).
        let bare = SceneEvaluator(document: doc).evaluate(compId: "c", at: 0).first { $0.layerId == "t" }!
        XCTAssertEqual(bare.size, .zero)
        XCTAssertNil(HitTester.topLayer(in: doc, compId: "c", at: 0, compPoint: Vec2(200, 200)))

        // With the measurer: real size, centered on its position, and clickable there.
        let ev = SceneEvaluator(document: doc, textMeasurer: engine)
            .evaluate(compId: "c", at: 0).first { $0.layerId == "t" }!
        XCTAssertGreaterThan(ev.size.x, 0)
        XCTAssertGreaterThan(ev.size.y, 0)
        let box = ev.boundingBox
        XCTAssertLessThan(box.min.x, 200); XCTAssertGreaterThan(box.max.x, 200) // straddles center x
        XCTAssertLessThan(box.min.y, 200); XCTAssertGreaterThan(box.max.y, 200) // straddles center y

        XCTAssertEqual(HitTester.topLayer(in: doc, compId: "c", at: 0, compPoint: Vec2(200, 200),
                                          textMeasurer: engine), "t")
        XCTAssertNil(HitTester.topLayer(in: doc, compId: "c", at: 0, compPoint: Vec2(5, 5),
                                        textMeasurer: engine))
    }
}
#endif
