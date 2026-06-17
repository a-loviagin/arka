import XCTest
@testable import MotionKernel

final class CanvasSnapperTests: XCTestCase {
    func testSnapsCenterToCandidate() {
        // Box centered on `proposed` (center offset 0); candidate at x=500 within threshold.
        let out = CanvasSnapper.snap(position: Vec2(496, 300),
                                     boxOffsetsX: [-50, 0, 50], boxOffsetsY: [-50, 0, 50],
                                     candidatesX: [500], candidatesY: [],
                                     threshold: 8)
        XCTAssertEqual(out.position.x, 500, accuracy: 1e-9)
        XCTAssertEqual(out.position.y, 300, accuracy: 1e-9, "no y candidate → unchanged")
        XCTAssertEqual(out.guides.count, 1)
        XCTAssertEqual(out.guides.first?.axis, .vertical)
        XCTAssertEqual(out.guides.first?.position, 500)
    }

    func testSnapsEdgeNotJustCenter() {
        // Right edge offset +50 lands on candidate 200 when center is at 152 → correction -2.
        let out = CanvasSnapper.snap(position: Vec2(152, 0),
                                     boxOffsetsX: [-50, 0, 50], boxOffsetsY: [],
                                     candidatesX: [200], candidatesY: [],
                                     threshold: 8)
        XCTAssertEqual(out.position.x, 150, accuracy: 1e-9, "right edge (200) snaps, center → 150")
    }

    func testNoSnapBeyondThreshold() {
        let out = CanvasSnapper.snap(position: Vec2(480, 300),
                                     boxOffsetsX: [0], boxOffsetsY: [0],
                                     candidatesX: [500], candidatesY: [300],
                                     threshold: 8)
        XCTAssertEqual(out.position.x, 480, "20 away > threshold 8 → no x snap")
        XCTAssertEqual(out.position.y, 300, accuracy: 1e-9, "exact y snap")
        XCTAssertEqual(out.guides.count, 1)
    }

    func testBoundingBoxUnderTransform() {
        let doc = MotionDocument(
            id: "d",
            compositions: [Composition(id: "c", size: Vec2(200, 200), layers: [
                Layer(id: "r", name: "r", sortKey: "a0",
                      content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(40, 20)))),
                      transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(100, 100))))
            ])],
            mainCompositionId: "c")
        let ev = SceneEvaluator(document: doc).evaluate(compId: "c", at: 0).first!
        let box = ev.boundingBox
        XCTAssertEqual(box.min.x, 80, accuracy: 1e-6)
        XCTAssertEqual(box.max.x, 120, accuracy: 1e-6)
        XCTAssertEqual(box.min.y, 90, accuracy: 1e-6)
        XCTAssertEqual(box.max.y, 110, accuracy: 1e-6)
    }
}
