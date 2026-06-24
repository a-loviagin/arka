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

    // MARK: Effects

    private func blur(_ id: EntityID = "fx_blur", radius: Double = 8) -> Effect {
        Effect(id: id, type: "blur", params: ["radius": .scalar(.static(radius))])
    }

    func testAddEffectAppendsToLayer() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.addEffect(layerId: "layer_logo", effect: blur()), label: "Add Blur")
        let fx = store.document.composition("comp_main")!.layer("layer_logo")!.effects
        XCTAssertEqual(fx.count, 1)
        XCTAssertEqual(fx.first?.type, "blur")
    }

    func testAddEffectRejectsDuplicateID() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.addEffect(layerId: "layer_logo", effect: blur()), label: "Add Blur")
        XCTAssertThrowsError(
            try store.perform(.addEffect(layerId: "layer_logo", effect: blur()), label: "Add Blur 2")
        ) { XCTAssertEqual($0 as? CommandError, .duplicateID("fx_blur")) }
    }

    func testRemoveEffect() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.addEffect(layerId: "layer_logo", effect: blur()), label: "Add Blur")
        try store.perform(.removeEffect(layerId: "layer_logo", effectId: "fx_blur"), label: "Remove Blur")
        XCTAssertTrue(store.document.composition("comp_main")!.layer("layer_logo")!.effects.isEmpty)
    }

    func testRemoveMissingEffectThrows() {
        let store = CommandStore(document: Fixtures.sampleDocument())
        XCTAssertThrowsError(
            try store.perform(.removeEffect(layerId: "layer_logo", effectId: "ghost"), label: "Remove")
        ) { XCTAssertEqual($0 as? CommandError, .effectNotFound("ghost")) }
    }

    func testSetTrackMatteAppliesUndoesAndRoundTrips() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.setLayerTrackMatte(layerId: "layer_logo", matte: .luma), label: "Matte")
        XCTAssertEqual(store.document.composition("comp_main")?.layer("layer_logo")?.trackMatte, .luma)
        store.undo()
        XCTAssertNil(store.document.composition("comp_main")?.layer("layer_logo")?.trackMatte)

        let cmds: [AnyCommand] = [.setLayerTrackMatte(layerId: "l", matte: .alphaInverted),
                                  .setLayerTrackMatte(layerId: "l", matte: nil)]
        let data = try JSONEncoder().encode(cmds)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), cmds)
    }

    // MARK: Compositions (frames)

    private func frame(_ id: EntityID = "comp_two") -> Composition {
        Composition(id: id, name: "Frame 2", size: Vec2(800, 600), fps: 60, duration: 3, layers: [])
    }

    func testAddCompositionAppendsFrame() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.addComposition(composition: frame()), label: "Add Frame")
        XCTAssertEqual(store.document.compositions.count, 2)
        XCTAssertEqual(store.document.composition("comp_two")?.size, Vec2(800, 600))
        store.undo()
        XCTAssertNil(store.document.composition("comp_two"))
    }

    func testAddCompositionRejectsDuplicateID() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        XCTAssertThrowsError(
            try store.perform(.addComposition(composition: frame("comp_main")), label: "Add")
        )
    }

    func testRemoveCompositionDeletesFrame() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.addComposition(composition: frame()), label: "Add Frame")
        try store.perform(.removeComposition(compId: "comp_two"), label: "Delete Frame")
        XCTAssertNil(store.document.composition("comp_two"))
        XCTAssertEqual(store.document.compositions.count, 1)
    }

    func testRemoveCompositionRejectsMainComposition() {
        let store = CommandStore(document: Fixtures.sampleDocument())
        XCTAssertThrowsError(
            try store.perform(.removeComposition(compId: "comp_main"), label: "Delete")
        )
    }

    func testCompositionCommandsRoundTripJSON() throws {
        let cmds: [AnyCommand] = [.addComposition(composition: frame()),
                                  .removeComposition(compId: "comp_two")]
        let data = try JSONEncoder().encode(cmds)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), cmds)
    }

    func testSetCompositionBoardPositionAppliesAndUndoes() throws {
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.setCompositionSetting(compId: "comp_main", setting: .boardPosition(Vec2(120, 40))),
                          label: "Move Frame")
        XCTAssertEqual(store.document.composition("comp_main")?.boardPosition, Vec2(120, 40))
        store.undo()
        XCTAssertEqual(store.document.composition("comp_main")?.boardPosition, .zero)
    }

    func testCompositionSettingRoundTripsBoardPosition() throws {
        let cmds: [AnyCommand] = [.setCompositionSetting(compId: "c", setting: .boardPosition(Vec2(900, 0))),
                                  .setCompositionSetting(compId: "c", setting: .size(Vec2(640, 480))),
                                  .setCompositionSetting(compId: "c", setting: .name("Hero"))]
        let data = try JSONEncoder().encode(cmds)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), cmds)
    }

    func testTrimPropertiesAreAddressableAndAnimatable() throws {
        let pathLayer = Layer(id: "pl", name: "Path", sortKey: "b0",
                              content: .shape(ShapeContent(geometry: .path, path: PathData(subpaths: []))))
        var doc = Fixtures.sampleDocument()
        doc.compositions[0].layers.append(pathLayer)
        let store = CommandStore(document: doc)
        // Static write.
        try store.perform(.setProperty(path: "pl/content/trimEnd", value: .scalar(0.5)), label: "Trim")
        // Animate via a keyframe at the playhead.
        try store.perform(.setKeyframe(path: "pl/content/trimEnd",
                                       keyframe: AnyKeyframe(t: 1.0, v: .scalar(1.0))), label: "Trim KF")
        guard case .shape(let s) = store.document.composition("comp_main")!.layer("pl")!.content else {
            return XCTFail("expected shape")
        }
        XCTAssertTrue(s.trimEnd?.isAnimated ?? false, "trimEnd became animated")
    }

    func testBoardPositionRoundTripsAndOmitsDefault() throws {
        var c = frame()
        c.boardPosition = Vec2(880, 0)
        let placed = try JSONDecoder().decode(Composition.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(placed.boardPosition, Vec2(880, 0))

        // Default (.zero) is omitted from the wire and decodes back to .zero.
        let plain = frame() // boardPosition defaults to .zero
        let json = String(data: try JSONEncoder().encode(plain), encoding: .utf8)!
        XCTAssertFalse(json.contains("boardPosition"), "omitted-default keeps single-frame files clean")
        let back = try JSONDecoder().decode(Composition.self, from: Data(json.utf8))
        XCTAssertEqual(back.boardPosition, .zero)
    }

    /// The shapes documented in MotionAI's SystemPrompt must decode + apply. If the schema drifts
    /// from the prompt, this fails — keeping the model's instructions truthful.
    func testDocumentedCommandShapesDecodeAndApply() throws {
        let json = """
        [
          {"type":"AddLayer","compId":"comp_main","layer":{
             "id":"ai_box","name":"Box","sortKey":"z0",
             "content":{"type":"shape","geometry":"rect","size":{"static":[80,80]},
                        "fillColor":{"static":"#3366FF"}},
             "transform":{"position":{"static":[100,100]},"opacity":{"static":1}}}},
          {"type":"AddEffect","layerId":"ai_box","effect":{"id":"fx1","type":"shadow",
             "params":{"offset":{"kind":"vec2","value":{"static":[0,6]}},
                       "radius":{"kind":"scalar","value":{"static":8}},
                       "color":{"kind":"color","value":{"static":"#000000"}},
                       "opacity":{"kind":"scalar","value":{"static":0.5}}}}},
          {"type":"SetProperty","path":"ai_box/transform/scale","value":[1.2,1.2]},
          {"type":"SetCompositionSetting","compId":"comp_main","setting":{"key":"duration","value":3}}
        ]
        """
        let cmds = try JSONDecoder().decode([AnyCommand].self, from: Data(json.utf8))
        let store = CommandStore(document: Fixtures.sampleDocument())
        try store.perform(.batch(commands: cmds, label: "AI edit"), label: "AI edit")
        let comp = store.document.composition("comp_main")!
        let box = comp.layer("ai_box")!
        XCTAssertEqual(box.effects.first?.type, "shadow")
        XCTAssertEqual(box.transform.scale.staticValue, Vec2(1.2, 1.2))
        XCTAssertEqual(comp.duration, 3, accuracy: 1e-9)
    }

    func testStructuralCommandsRoundTripJSON() throws {
        let cmds: [AnyCommand] = [
            .setLayerName(layerId: "layer_logo", name: "Hero"),
            .setLayerBlendMode(layerId: "layer_logo", blendMode: .multiply),
            .setContent(layerId: "layer_logo", content: .text(TextContent(
                string: "Hi", fontFamily: "Georgia", fontSize: .static(40),
                fillColor: .static(.white), alignment: .center))),
        ]
        let data = try JSONEncoder().encode(cmds)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), cmds)
    }

    func testEffectCommandsRoundTripJSON() throws {
        let cmds: [AnyCommand] = [
            .addEffect(layerId: "layer_logo", effect: blur()),
            .removeEffect(layerId: "layer_logo", effectId: "fx_blur"),
        ]
        let data = try JSONEncoder().encode(cmds)
        XCTAssertEqual(try JSONDecoder().decode([AnyCommand].self, from: data), cmds)
    }
}
