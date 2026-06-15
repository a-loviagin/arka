import XCTest
@testable import MotionKernel

final class CodableTests: XCTestCase {
    func testDocumentRoundTrips() throws {
        let doc = Fixtures.sampleDocument()
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(MotionDocument.self, from: data)
        XCTAssertEqual(doc, back)
    }

    func testOmittedDefaultsKeepFilesSmall() throws {
        // A default transform should not emit position/scale/etc.
        let layer = Layer(id: "l", name: "L", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect)))
        let data = try JSONEncoder().encode(layer)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"rotation\""), "default rotation should be omitted")
        XCTAssertFalse(json.contains("\"locked\""), "default locked should be omitted")
    }

    func testKeyframeWireShapeMatchesSpec() throws {
        // From motion-document-schema.md §4.
        let json = """
        { "t": 0.0, "v": [200, 540], "interp": "bezier",
          "easeOut": [0.33, 0.0], "spatialOut": [60, 0] }
        """.data(using: .utf8)!
        let kf = try JSONDecoder().decode(Keyframe<Vec2>.self, from: json)
        XCTAssertEqual(kf.t, 0.0)
        XCTAssertEqual(kf.v, Vec2(200, 540))
        XCTAssertEqual(kf.easeOut, ControlPoint(0.33, 0))
        XCTAssertEqual(kf.spatialOut, Vec2(60, 0))
        if case .bezier = kf.interp {} else { XCTFail("expected bezier") }
    }

    func testSpringKeyframeDecodes() throws {
        let json = """
        { "t": 1.2, "v": [960, 200], "interp": "spring",
          "spring": { "stiffness": 180, "damping": 18, "mass": 1 } }
        """.data(using: .utf8)!
        let kf = try JSONDecoder().decode(Keyframe<Vec2>.self, from: json)
        guard case .spring(let s) = kf.interp else { return XCTFail("expected spring") }
        XCTAssertEqual(s.stiffness, 180)
        XCTAssertEqual(s.damping, 18)
    }

    func testCommandListDecodesFromSpecExample() throws {
        // From properties-and-commands.md §2 (with compId added per our schema).
        let json = """
        { "commands": [
          { "type": "SetKeyframe",
            "path": "layer_logo/transform/position",
            "keyframe": { "t": 0.0, "v": [960, 1200], "easeOut": [0.2, 0.0] } }
        ], "label": "Slide-up entrance for logo" }
        """.data(using: .utf8)!
        struct Envelope: Decodable { let commands: [AnyCommand]; let label: String }
        let env = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertEqual(env.commands.count, 1)
        if case .setKeyframe(let path, let kf) = env.commands[0] {
            XCTAssertEqual(path, "layer_logo/transform/position")
            XCTAssertEqual(try kf.v.asVec2(), Vec2(960, 1200))
        } else {
            XCTFail("expected setKeyframe")
        }
    }

    func testCommandRoundTrips() throws {
        let cmd = AnyCommand.batch(commands: [
            .setProperty(path: "layer_logo/transform/opacity", value: .scalar(0.5)),
            .setKeyframe(path: "layer_logo/transform/position",
                         keyframe: AnyKeyframe(t: 0.5, v: .vec2(Vec2(10, 20)),
                                               interp: .spring(.bouncy))),
            .reorderLayer(layerId: "layer_logo", sortKey: SortKey.between("a0", "a1")),
        ], label: "Test batch")
        let data = try JSONEncoder().encode(cmd)
        let back = try JSONDecoder().decode(AnyCommand.self, from: data)
        XCTAssertEqual(cmd, back)
    }
}
