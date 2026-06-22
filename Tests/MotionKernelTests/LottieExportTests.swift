import XCTest
@testable import MotionKernel

/// Lottie export is a document→document translator (export-and-format.md §4). These pin the shape of
/// the emitted bodymovin JSON and the compatibility lint.
final class LottieExportTests: XCTestCase {
    private func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func animatedRectDoc() -> MotionDocument {
        let rect = Layer(
            id: "r", name: "Box", sortKey: "a0",
            content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 80)),
                                         fillColor: .static(ColorValue(r: 1, g: 0, b: 0, a: 1)))),
            transform: Transform(
                anchor: .static(Vec2(0.5, 0.5)),
                position: .animated([Track(keyframes: [
                    Keyframe(t: 0.0, v: Vec2(100, 100), interp: .bezier, easeOut: ControlPoint(0.3, 0)),
                    Keyframe(t: 1.0, v: Vec2(300, 100), interp: .bezier, easeIn: ControlPoint(0.7, 1)),
                ])]),
                opacity: .static(1)))
        let comp = Composition(id: "c", name: "Main", size: Vec2(640, 480), fps: 30, duration: 2,
                               backgroundColor: .white, layers: [rect])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }

    func testCompositionMetadataAndShapeLayer() throws {
        let result = try LottieExporter.export(animatedRectDoc(), compId: "c")
        let root = try parse(result.json)
        XCTAssertEqual(root["fr"] as? Double, 30)
        XCTAssertEqual(root["w"] as? Double, 640)
        XCTAssertEqual(root["h"] as? Double, 480)
        XCTAssertEqual(root["op"] as? Double, 60, "2s × 30fps")

        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0]["ty"] as? Int, 4, "shape layer")

        // Animated position with two keyframes + bezier handles.
        let ks = try XCTUnwrap(layers[0]["ks"] as? [String: Any])
        let p = try XCTUnwrap(ks["p"] as? [String: Any])
        XCTAssertEqual(p["a"] as? Int, 1, "position is animated")
        let pk = try XCTUnwrap(p["k"] as? [[String: Any]])
        XCTAssertEqual(pk.count, 2)
        XCTAssertEqual(pk[0]["t"] as? Double, 0)
        XCTAssertEqual(pk[1]["t"] as? Double, 30, "1s × 30fps")
        XCTAssertNotNil(pk[0]["o"], "first keyframe carries out handle")
        XCTAssertEqual((pk[0]["s"] as? [Double])?.first, 100)

        // Anchor in points = normalized 0.5 × size (100×80).
        let a = try XCTUnwrap((ks["a"] as? [String: Any])?["k"] as? [Double])
        XCTAssertEqual(a, [50, 40])

        // Shape group has a rect + a fill.
        let shapes = try XCTUnwrap(layers[0]["shapes"] as? [[String: Any]])
        let it = try XCTUnwrap(shapes[0]["it"] as? [[String: Any]])
        XCTAssertTrue(it.contains { $0["ty"] as? String == "rc" }, "has a rect")
        XCTAssertTrue(it.contains { $0["ty"] as? String == "fl" }, "has a fill")
    }

    func testVideoLayerWarnsAndBecomesNull() throws {
        let video = Layer(id: "v", name: "Clip", sortKey: "a0", content: .video(VideoContent(assetId: "asset1")))
        let comp = Composition(id: "c", size: Vec2(100, 100), fps: 30, duration: 1, layers: [video])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
        let result = try LottieExporter.export(doc, compId: "c")
        let layers = try XCTUnwrap(try parse(result.json)["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[0]["ty"] as? Int, 3, "video → null layer")
        XCTAssertTrue(result.warnings.contains { $0.contains("video") }, "video unsupported is surfaced")
    }

    func testPathLayerExportsShapeAndTrim() throws {
        let path = PathData(subpaths: [.init(vertices: [
            .init(point: Vec2(0, 0)), .init(point: Vec2(100, 0)), .init(point: Vec2(100, 100)),
        ], closed: false)])
        let layer = Layer(id: "p", name: "Squiggle", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .path,
                                                       strokeColor: .static(.black), strokeWidth: .static(4),
                                                       path: path, trimEnd: .static(0.5))))
        let comp = Composition(id: "c", size: Vec2(200, 200), fps: 30, duration: 1, layers: [layer])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
        let root = try parse(try LottieExporter.export(doc, compId: "c").json)
        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        let it = try XCTUnwrap((layers[0]["shapes"] as? [[String: Any]])?.first?["it"] as? [[String: Any]])
        XCTAssertTrue(it.contains { $0["ty"] as? String == "sh" }, "vector path → sh")
        XCTAssertTrue(it.contains { $0["ty"] as? String == "tm" }, "trim → tm")
        // sh vertices carry the path points.
        let sh = try XCTUnwrap(it.first { $0["ty"] as? String == "sh" })
        let verts = ((sh["ks"] as? [String: Any])?["k"] as? [String: Any])?["v"] as? [[Double]]
        XCTAssertEqual(verts?.count, 3)
    }

    func testSpringSamplesToDenseKeyframes() throws {
        let layer = Layer(id: "s", name: "Pop", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(50, 50)))),
                          transform: Transform(position: .animated([Track(keyframes: [
                              Keyframe(t: 0.0, v: Vec2(0, 0), interp: .spring(.bouncy)),
                              Keyframe(t: 1.0, v: Vec2(200, 0)),
                          ])])))
        let comp = Composition(id: "c", size: Vec2(300, 300), fps: 30, duration: 1, layers: [layer])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
        let result = try LottieExporter.export(doc, compId: "c")
        let layers = try XCTUnwrap(try parse(result.json)["layers"] as? [[String: Any]])
        let pk = try XCTUnwrap(((layers[0]["ks"] as? [String: Any])?["p"] as? [String: Any])?["k"] as? [[String: Any]])
        XCTAssertGreaterThan(pk.count, 10, "spring is densely sampled, not 2 keyframes")
        XCTAssertTrue(result.warnings.contains { $0.lowercased().contains("spring") })
    }

    func testJSONValueRoundTrips() throws {
        let v: JSONValue = .object(["n": .number(1.5), "a": .nums([1, 2]), "s": .string("x"), "b": .bool(true)])
        let back = try JSONSerialization.jsonObject(with: v.data()) as? [String: Any]
        XCTAssertEqual(back?["n"] as? Double, 1.5)
        XCTAssertEqual(back?["s"] as? String, "x")
    }
}
