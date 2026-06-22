#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// Gradient shape fill (properties-and-commands.md §1, Tier 2): stops baked into a LUT, sampled in
/// the shape fragment by a coordinate from the gradient endpoints.
final class GradientRenderTests: XCTestCase {
    func testLinearGradientFillGoesDarkToLight() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)
        // 100×100 rect filling the comp, black→white left→right.
        let grad = GradientFill(kind: .linear, start: .static(Vec2(0, 0)), end: .static(Vec2(100, 0)),
                                stops: [GradientStop(position: .static(0), color: .static(.black)),
                                        GradientStop(position: .static(1), color: .static(.white))])
        let layer = Layer(id: "g", name: "g", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)),
                                                       gradient: grad)),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        let comp = Composition(id: "comp_main", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [layer])
        let d = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")
        let nodes = RenderTreeBuilder(document: d).build(compId: "comp_main", at: 0)
        let img = renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                         pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        let left = Int(img.pixel(6, 50).r), mid = Int(img.pixel(50, 50).r), right = Int(img.pixel(94, 50).r)
        XCTAssertLessThan(left, 40, "left end ≈ black")
        XCTAssertGreaterThan(right, 215, "right end ≈ white")
        XCTAssertTrue(left < mid && mid < right, "monotonic dark→light across the fill")
    }

    func testGradientFillRoundTrips() throws {
        let g = GradientFill(kind: .radial, start: .static(Vec2(50, 50)), end: .static(Vec2(50, 0)),
                             stops: [GradientStop(position: .static(0), color: .static(.white)),
                                     GradientStop(position: .static(1), color: .static(.black))])
        let s = ShapeContent(geometry: .ellipse, gradient: g)
        let back = try JSONDecoder().decode(ShapeContent.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.gradient, g)
    }
}
#endif
