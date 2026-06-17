import XCTest
@testable import MotionKernel

final class AffineInverseTests: XCTestCase {
    func testInverseRoundTrips() {
        let m = Affine2D.translation(Vec2(-30, -20))
            .concatenating(.scale(Vec2(1.5, 0.8)))
            .concatenating(.rotation(degrees: 25))
            .concatenating(.translation(Vec2(400, 300)))
        let inv = m.inverted()!
        let p = Vec2(123, -45)
        let back = inv.apply(to: m.apply(to: p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
    }

    func testSingularReturnsNil() {
        XCTAssertNil(Affine2D.scale(Vec2(0, 1)).inverted())
    }
}

final class ViewportTests: XCTestCase {
    func testFitCentersAndRoundTrips() {
        // 16:9 comp in a square view → letterboxed top/bottom.
        let vp = Viewport(compSize: Vec2(1920, 1080), viewSize: Vec2(1000, 1000))
        XCTAssertEqual(vp.scale, 1000.0 / 1920.0, accuracy: 1e-9)
        XCTAssertEqual(vp.offset.x, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(vp.offset.y, 0, "letterboxed vertically")

        let comp = Vec2(960, 540)
        let view = vp.toView(comp)
        let back = vp.toComp(view)
        XCTAssertEqual(back.x, comp.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, comp.y, accuracy: 1e-6)
    }
}

final class HitTesterTests: XCTestCase {
    private func doc(_ layers: [Layer]) -> MotionDocument {
        let comp = Composition(id: "comp_main", size: Vec2(200, 200), fps: 60, duration: 1,
                               backgroundColor: .black, layers: layers)
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")
    }
    private func rect(_ id: String, at pos: Vec2, size: Vec2, sortKey: SortKey) -> Layer {
        Layer(id: EntityID(id), name: id, sortKey: sortKey,
              content: .shape(ShapeContent(geometry: .rect, size: .static(size))),
              transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(pos)))
    }

    func testHitsTopmostOnOverlap() {
        // a (bottom) spans 20…80; b (top) spans 50…110. Overlap 50…80.
        let d = doc([rect("a", at: Vec2(50, 50), size: Vec2(60, 60), sortKey: "a0"),
                     rect("b", at: Vec2(80, 50), size: Vec2(60, 60), sortKey: "a1")])
        XCTAssertEqual(HitTester.topLayer(in: d, compId: "comp_main", at: 0, compPoint: Vec2(65, 50)), "b")
        XCTAssertEqual(HitTester.topLayer(in: d, compId: "comp_main", at: 0, compPoint: Vec2(30, 50)), "a")
        XCTAssertNil(HitTester.topLayer(in: d, compId: "comp_main", at: 0, compPoint: Vec2(5, 5)))
    }

    func testHitRespectsRotation() {
        // A 100×20 bar rotated 90° about its center at (100,100) occupies x∈[90,110], y∈[50,150].
        let bar = Layer(id: "bar", name: "bar", sortKey: "a0",
                        content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 20)))),
                        transform: Transform(anchor: .static(Vec2(0.5, 0.5)),
                                             position: .static(Vec2(100, 100)),
                                             rotation: .static(90)))
        let d = doc([bar])
        XCTAssertEqual(HitTester.topLayer(in: d, compId: "comp_main", at: 0, compPoint: Vec2(100, 140)), "bar")
        XCTAssertNil(HitTester.topLayer(in: d, compId: "comp_main", at: 0, compPoint: Vec2(140, 100)),
                     "outside the rotated bar")
    }
}

final class ReplaceDocumentTests: XCTestCase {
    func testReplaceClearsHistoryAndSelection() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.setProperty(path: "layer_bg/transform/opacity", value: .scalar(0.2)), label: "Dim")
        store.selection = Selection(layerIds: ["layer_bg"])
        XCTAssertTrue(store.canUndo)

        var fresh = Fixtures.sampleDocument()
        fresh.meta.title = "Fresh"
        store.replaceDocument(fresh)
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)
        XCTAssertEqual(store.selection, .empty)
        XCTAssertEqual(store.document.meta.title, "Fresh")
    }
}
