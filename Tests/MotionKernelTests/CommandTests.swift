import XCTest
@testable import MotionKernel

final class CommandTests: XCTestCase {
    func testSetPropertyChangesStaticValue() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.setProperty(path: "layer_bg/transform/opacity", value: .scalar(0.3)),
                          label: "Set opacity")
        let bg = store.document.composition("comp_main")!.layer("layer_bg")!
        XCTAssertEqual(bg.transform.opacity.staticValue, 0.3)
    }

    func testSetKeyframeAutoKeyframes() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.setKeyframe(path: "layer_bg/transform/rotation",
                                       keyframe: AnyKeyframe(t: 1.0, v: .scalar(90))),
                          label: "Key rotation")
        let bg = store.document.composition("comp_main")!.layer("layer_bg")!
        XCTAssertTrue(bg.transform.rotation.isAnimated)
        XCTAssertEqual(bg.transform.rotation.resolve(at: 1.0), 90, accuracy: 1e-9)
    }

    func testParentCycleRejected() {
        let store = CommandStore(document: Fixtures.sampleDocument())
        // label is parented to logo; parenting logo to label would cycle.
        XCTAssertThrowsError(
            try store.perform(.setLayerParent(layerId: "layer_logo", parentId: "layer_label"),
                              label: "Bad parent")
        ) { error in
            XCTAssertEqual(error as? CommandError,
                           .parentCycle(layer: "layer_logo", parent: "layer_label"))
        }
        // Document untouched after failed validation.
        XCTAssertNil(store.document.composition("comp_main")!.layer("layer_logo")!.parentId)
    }

    func testRemoveLayerReparentsChildren() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        // label's parent is logo; removing logo should reparent label to logo's parent (nil).
        try store.perform(.removeLayer(layerId: "layer_logo"), label: "Delete logo")
        let comp = store.document.composition("comp_main")!
        XCTAssertNil(comp.layer("layer_logo"))
        XCTAssertNil(comp.layer("layer_label")!.parentId)
    }

    func testTimeOutOfRangeRejected() {
        let store = CommandStore(document: Fixtures.sampleDocument())
        XCTAssertThrowsError(
            try store.perform(.setKeyframe(path: "layer_bg/transform/opacity",
                                           keyframe: AnyKeyframe(t: 99, v: .scalar(1))),
                              label: "Bad time"))
    }

    func testUndoRedoSingleEdit() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        let original = store.document
        try store.perform(.setProperty(path: "layer_bg/transform/opacity", value: .scalar(0.1)),
                          label: "Dim")
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertEqual(store.document, original)
        store.redo()
        XCTAssertEqual(store.document.composition("comp_main")!.layer("layer_bg")!
            .transform.opacity.staticValue, 0.1)
    }

    func testNoOpTransactionPushesNothing() {
        let store = CommandStore(document: Fixtures.sampleDocument())
        let id = store.begin("Empty gesture")
        store.commit(id)
        XCTAssertFalse(store.canUndo)
    }

    func testCancelRevertsAndPushesNothing() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        let original = store.document
        let id = store.begin("Drag")
        try store.perform(.setProperty(path: "layer_bg/transform/rotation", value: .scalar(45)), in: id)
        XCTAssertNotEqual(store.document, original)
        store.cancel(id)
        XCTAssertEqual(store.document, original)
        XCTAssertFalse(store.canUndo)
    }

    func testAISourceTaggedAndUndoneAtomically() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        let original = store.document
        let generation = AnyCommand.batch(commands: [
            .setKeyframe(path: "layer_logo/transform/scale",
                         keyframe: AnyKeyframe(t: 0.0, v: .vec2(Vec2(0, 0)), interp: .spring(.bouncy))),
            .setKeyframe(path: "layer_logo/transform/scale",
                         keyframe: AnyKeyframe(t: 0.5, v: .vec2(Vec2(1, 1)))),
        ], label: "AI: pop in")
        try store.perform(generation, label: "AI: pop in", source: .ai(generationID: "gen_1"))
        XCTAssertTrue(store.document.composition("comp_main")!.layer("layer_logo")!
            .transform.scale.isAnimated)
        // One undo reverts the whole generation.
        store.undo()
        XCTAssertEqual(store.document, original)
    }
}
