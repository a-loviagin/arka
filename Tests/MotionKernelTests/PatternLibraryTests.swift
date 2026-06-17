import XCTest
@testable import MotionKernel

final class PatternLibraryTests: XCTestCase {
    private func layerDoc(opacity: Double = 1, position: Vec2 = Vec2(100, 100)) -> (CommandStore, EntityID) {
        let layer = Layer(id: "l", name: "L", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(50, 50)))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)),
                                               position: .static(position), opacity: .static(opacity)))
        let comp = Composition(id: "comp", size: Vec2(400, 400), fps: 60, duration: 3, layers: [layer])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp")
        return (CommandStore(document: doc), "l")
    }

    func testFadeInAnimatesOpacityFromZeroToRest() throws {
        let (store, id) = layerDoc(opacity: 0.8)
        let layer = store.document.composition("comp")!.layer(id)!
        let comp = store.document.composition("comp")!
        let cmds = PatternLibrary.expand(.fadeIn, on: layer, in: comp,
                                         params: PatternParams(at: 0.5, duration: 0.5, character: .gentle))
        try store.perform(.batch(commands: cmds, label: "Fade In"), label: "Fade In")

        let op = store.document.composition("comp")!.layer(id)!.transform.opacity
        XCTAssertTrue(op.isAnimated)
        XCTAssertEqual(op.resolve(at: 0.5), 0, accuracy: 1e-6, "starts transparent")
        XCTAssertEqual(op.resolve(at: 1.0), 0.8, accuracy: 1e-6, "ends at the layer's rest opacity")
        // One ⌘Z removes the whole pattern.
        store.undo()
        XCTAssertFalse(store.document.composition("comp")!.layer(id)!.transform.opacity.isAnimated)
    }

    func testPopInUsesSpringScaleFromZero() {
        let (store, id) = layerDoc()
        let comp = store.document.composition("comp")!
        let cmds = PatternLibrary.expand(.popIn, on: comp.layer(id)!, in: comp,
                                         params: PatternParams(at: 0, duration: 0.6, character: .bouncy))
        var doc = store.document
        for c in cmds { try? c.apply(to: &doc) }
        let scale = doc.composition("comp")!.layer(id)!.transform.scale
        guard case .animated(let tracks) = scale, let first = tracks.first?.keyframes.first else {
            return XCTFail("scale should be animated")
        }
        XCTAssertEqual(first.v, Vec2(0, 0), "pop starts from zero scale")
        guard case .spring = first.interp else { return XCTFail("pop uses a spring") }
    }

    func testSlideInUpStartsBelowRest() {
        let (store, id) = layerDoc(position: Vec2(200, 150))
        let comp = store.document.composition("comp")!
        let cmds = PatternLibrary.expand(.slideInUp, on: comp.layer(id)!, in: comp,
                                         params: PatternParams(at: 0, duration: 0.5, distance: 100))
        var doc = store.document
        for c in cmds { try? c.apply(to: &doc) }
        let position = doc.composition("comp")!.layer(id)!.transform.position
        XCTAssertEqual(position.resolve(at: 0), Vec2(200, 250), "starts 100 below rest")
        XCTAssertEqual(position.resolve(at: 0.5), Vec2(200, 150), "ends at rest")
    }

    func testStaggerOffsetsStartTimes() throws {
        let layers = (0..<3).map {
            Layer(id: EntityID("l\($0)"), name: "L", sortKey: SortKey("a\($0)"),
                  content: .shape(ShapeContent(geometry: .rect)),
                  transform: Transform(position: .static(Vec2(0, 0)), opacity: .static(1)))
        }
        let comp = Composition(id: "c", size: Vec2(400, 400), fps: 60, duration: 5, layers: layers)
        let cmds = PatternLibrary.stagger(.fadeIn, on: layers, in: comp,
                                          params: PatternParams(at: 0.2, duration: 0.4), gap: 0.1)
        // Each layer's first opacity keyframe starts 0.1s after the previous.
        func firstT(_ id: String) -> Double? {
            for case .setKeyframe(let path, let kf) in cmds where path == "\(id)/transform/opacity" { return kf.t }
            return nil
        }
        XCTAssertEqual(try XCTUnwrap(firstT("l0")), 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(firstT("l1")), 0.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(firstT("l2")), 0.4, accuracy: 1e-9)
    }

    func testEveryPatternExpandsNonEmpty() {
        let (store, id) = layerDoc()
        let comp = store.document.composition("comp")!
        for pattern in MotionPattern.allCases {
            let cmds = PatternLibrary.expand(pattern, on: comp.layer(id)!, in: comp, params: PatternParams())
            XCTAssertFalse(cmds.isEmpty, "\(pattern) should expand to commands")
            // And the batch applies cleanly.
            var doc = store.document
            XCTAssertNoThrow(try AnyCommand.batch(commands: cmds, label: "x").apply(to: &doc))
        }
    }
}
