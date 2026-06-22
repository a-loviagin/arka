#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// Blend modes composite a layer's intermediate against the backdrop (render-engine.md §3). A gray
/// layer over a pure-red backdrop: normal shows gray; multiply zeroes the green/blue (× 0) and keeps
/// a red product — proof the mode reads the backdrop, not just paints over it.
final class BlendModeTests: XCTestCase {
    private func doc(_ blend: BlendMode) -> MotionDocument {
        let back = Layer(id: "bg", name: "bg", sortKey: "a0",
                         content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)),
                                                      fillColor: .static(ColorValue(hex: "#FF0000")!))),
                         transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        let top = Layer(id: "top", name: "top", sortKey: "a1",
                        content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(60, 60)),
                                                     fillColor: .static(ColorValue(hex: "#808080")!))),
                        transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))),
                        blendMode: blend)
        let comp = Composition(id: "c", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [back, top])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }

    func testMultiplyReadsTheBackdrop() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)
        func render(_ d: MotionDocument) -> PixelImage {
            let nodes = RenderTreeBuilder(document: d).build(compId: "c", at: 0)
            return renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                          pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        }
        let normal = render(doc(.normal)).pixel(50, 50)
        let mult = render(doc(.multiply)).pixel(50, 50)

        XCTAssertGreaterThan(normal.g, 100, "gray over red (normal) keeps green")
        XCTAssertLessThan(mult.g, 30, "multiply against a red backdrop zeroes green")
        XCTAssertGreaterThan(mult.r, 80, "multiply keeps a red product")
    }
}
#endif
