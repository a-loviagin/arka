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

    func testSetLayerVisibleAndLocked() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.setLayerVisible(layerId: "layer_bg", visible: false), label: "Hide")
        XCTAssertEqual(store.document.composition("comp_main")!.layer("layer_bg")!.visible, false)
        try store.perform(.setLayerLocked(layerId: "layer_bg", locked: true), label: "Lock")
        XCTAssertEqual(store.document.composition("comp_main")!.layer("layer_bg")!.locked, true)
        store.undo()
        XCTAssertEqual(store.document.composition("comp_main")!.layer("layer_bg")!.locked, false)
    }

    func testLayerFlagCommandsRoundTripJSON() throws {
        let cmds: [AnyCommand] = [.setLayerVisible(layerId: "l", visible: false),
                                  .setLayerLocked(layerId: "l", locked: true)]
        let data = try JSONEncoder().encode(cmds)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), cmds)
    }

    func testSetKeyframeInterp() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        // layer_logo opacity is animated with a linear first segment; change it to a spring.
        try store.perform(.setKeyframeInterp(path: "layer_logo/transform/opacity", t: 0.0,
                                             interp: .spring(.bouncy)), label: "Easing")
        let av = store.document.composition("comp_main")!.layer("layer_logo")!.transform.opacity
        guard case .animated(let tracks) = av,
              let kf = tracks.first?.keyframes.first(where: { abs($0.t) < 1e-6 }) else {
            return XCTFail("expected animated opacity")
        }
        guard case .spring = kf.interp else { return XCTFail("interp should be spring") }
        store.undo()
        let back = store.document.composition("comp_main")!.layer("layer_logo")!.transform.opacity
        if case .animated(let tr) = back, case .spring = tr.first!.keyframes.first!.interp {
            XCTFail("undo should restore the original interp")
        }
    }

    func testSetKeyframeInterpRoundTripsJSON() throws {
        let cmds: [AnyCommand] = [
            .setKeyframeInterp(path: "l/transform/position", t: 0.5, interp: .linear),
            .setKeyframeInterp(path: "l/transform/position", t: 1.0, interp: .spring(.snappy)),
        ]
        let data = try JSONEncoder().encode(cmds)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), cmds)
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
