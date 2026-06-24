#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// Track mattes (Tier 3): the layer above mattes the one below by its alpha/luma.
final class TrackMatteTests: XCTestCase {
    func testAlphaMatteShowsContentOnlyUnderTheMatte() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)

        // Content: red square filling the comp. Matte (above): a small white square at center.
        let content = Layer(id: "c", name: "content", sortKey: "a0",
                            content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)),
                                                        fillColor: .static(ColorValue(r: 1, g: 0, b: 0, a: 1)))),
                            transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))),
                            trackMatte: .alpha)
        let matte = Layer(id: "m", name: "matte", sortKey: "a1",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(40, 40)),
                                                      fillColor: .static(.white))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        let comp = Composition(id: "c0", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [content, matte])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c0")

        let nodes = RenderTreeBuilder(document: doc).build(compId: "c0", at: 0)
        XCTAssertEqual(nodes.count, 1, "matted layer + its matte fold into one node")
        let img = renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                         pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        let inside = img.pixel(50, 50)   // under the matte → content (red) shows, not the white matte
        XCTAssertGreaterThan(Int(inside.r), 150)
        XCTAssertLessThan(Int(inside.g), 90); XCTAssertLessThan(Int(inside.b), 90)
        let outside = img.pixel(10, 50)  // inside content, outside the matte → masked away
        XCTAssertLessThan(Int(outside.r) + Int(outside.g) + Int(outside.b), 40)
    }

    func testAlphaInvertedMatteFlipsTheMask() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)
        let content = Layer(id: "c", name: "content", sortKey: "a0",
                            content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)),
                                                        fillColor: .static(ColorValue(r: 1, g: 0, b: 0, a: 1)))),
                            transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))),
                            trackMatte: .alphaInverted)
        let matte = Layer(id: "m", name: "matte", sortKey: "a1",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(40, 40)),
                                                      fillColor: .static(.white))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        let comp = Composition(id: "c0", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [content, matte])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c0")
        let img = renderer.renderToImage(nodes: RenderTreeBuilder(document: doc).build(compId: "c0", at: 0),
                                         compSize: SIMD2<Float>(100, 100), pixelSize: (100, 100),
                                         clear: SIMD4<Double>(0, 0, 0, 1))!
        XCTAssertLessThan(Int(img.pixel(50, 50).r), 60, "under the matte is now hidden (inverted)")
        XCTAssertGreaterThan(Int(img.pixel(10, 50).r), 150, "outside the matte shows the content")
    }
}
#endif
