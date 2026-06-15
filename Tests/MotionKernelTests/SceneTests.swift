import XCTest
@testable import MotionKernel

final class SceneTests: XCTestCase {
    func testParentChainComposesPositionAndOpacity() {
        let doc = Fixtures.sampleDocument()
        let scene = SceneEvaluator(document: doc)
        // At t=0.4 the logo is at center with opacity ~1; the label is parented to it at +160 y.
        let layers = scene.evaluate(compId: "comp_main", at: 0.4)
        let label = layers.first { $0.layerId == "layer_label" }!
        let logo = layers.first { $0.layerId == "layer_logo" }!

        // Label origin should be offset from the logo's world position by its local (0,160).
        let labelOrigin = label.world.apply(to: .zero)
        let logoOrigin = logo.world.apply(to: .zero)
        XCTAssertEqual(labelOrigin.y - logoOrigin.y, 160, accuracy: 1e-6)
        // Logo opacity animates 0→1 over [0,0.4]; at 0.4 it's 1, label inherits it.
        XCTAssertEqual(logo.opacity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(label.opacity, 1.0, accuracy: 1e-6)
    }

    func testOpacityMultipliesDownChain() {
        var doc = Fixtures.sampleDocument()
        // Force logo opacity to a static 0.5.
        let ci = doc.compositionIndex("comp_main")!
        let li = doc.compositions[ci].layers.firstIndex { $0.id == "layer_logo" }!
        doc.compositions[ci].layers[li].transform.opacity = .static(0.5)

        let scene = SceneEvaluator(document: doc)
        let layers = scene.evaluate(compId: "comp_main", at: 0.0)
        let label = layers.first { $0.layerId == "layer_label" }!
        // Label's own opacity is 1, parent (logo) is 0.5 → 0.5.
        XCTAssertEqual(label.opacity, 0.5, accuracy: 1e-6)
    }

    func testRenderOrderBySortKey() {
        let doc = Fixtures.sampleDocument()
        let scene = SceneEvaluator(document: doc)
        let ids = scene.evaluate(compId: "comp_main", at: 0).map(\.layerId)
        XCTAssertEqual(ids, ["layer_bg", "layer_logo", "layer_label"])
    }

    func testInOutPointActivity() {
        var doc = Fixtures.sampleDocument()
        let ci = doc.compositionIndex("comp_main")!
        let li = doc.compositions[ci].layers.firstIndex { $0.id == "layer_logo" }!
        doc.compositions[ci].layers[li].inPoint = 1.0
        doc.compositions[ci].layers[li].outPoint = 2.0

        let scene = SceneEvaluator(document: doc)
        XCTAssertFalse(scene.evaluate(compId: "comp_main", at: 0.5).first { $0.layerId == "layer_logo" }!.active)
        XCTAssertTrue(scene.evaluate(compId: "comp_main", at: 1.5).first { $0.layerId == "layer_logo" }!.active)
        XCTAssertFalse(scene.evaluate(compId: "comp_main", at: 2.5).first { $0.layerId == "layer_logo" }!.active)
    }
}
