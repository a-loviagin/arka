#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// Background blur blurs the composited backdrop within the layer (render-engine.md §3). A
/// translucent panel over a sharp white square: with background blur, white bleeds past the square's
/// edge under the panel; without it, that region only carries the panel's flat tint.
final class BackgroundBlurTests: XCTestCase {
    private func doc(bgBlur: Bool) -> MotionDocument {
        // Sharp white square in the centre (covers comp 30…70).
        let back = Layer(id: "sq", name: "sq", sortKey: "a0",
                         content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(40, 40)),
                                                      fillColor: .static(.white))),
                         transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        var panelFx: [Effect] = []
        if bgBlur { panelFx = [Effect(id: "bg", type: "backgroundBlur", params: ["radius": .scalar(.static(24))])] }
        // Translucent full-comp panel (its alpha is the blur mask).
        let panel = Layer(id: "panel", name: "panel", sortKey: "a1",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)),
                                                       fillColor: .static(ColorValue(r: 1, g: 1, b: 1, a: 0.5)))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))),
                          effects: panelFx)
        let comp = Composition(id: "c", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [back, panel])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }

    func testBackgroundBlurBleedsBackdropPastTheEdge() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)
        func render(_ d: MotionDocument) -> PixelImage {
            let nodes = RenderTreeBuilder(document: d).build(compId: "c", at: 0)
            return renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                          pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        }
        let plain = render(doc(bgBlur: false)).pixel(80, 50) // 10px right of the square's edge
        let blurred = render(doc(bgBlur: true)).pixel(80, 50)
        XCTAssertGreaterThan(Int(blurred.r), Int(plain.r) + 4,
                             "background blur bleeds the white square past its edge under the panel")
    }
}
#endif
