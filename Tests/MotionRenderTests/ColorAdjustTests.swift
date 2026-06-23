#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// Tier-3 color-adjustment effect: brightness/contrast/saturation/hue on a layer's rasterized result.
final class ColorAdjustTests: XCTestCase {
    private func doc(effects: [Effect]) -> MotionDocument {
        let sq = Layer(id: "sq", name: "sq", sortKey: "a0",
                       content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)),
                                                    fillColor: .static(ColorValue(r: 1, g: 0, b: 0, a: 1)))),
                       transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))),
                       effects: effects)
        let comp = Composition(id: "c", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [sq])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }

    private func center(_ d: MotionDocument, _ renderer: MetalRenderer) -> (r: Int, g: Int, b: Int) {
        let nodes = RenderTreeBuilder(document: d).build(compId: "c", at: 0)
        let img = renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                         pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        let p = img.pixel(50, 50)
        return (Int(p.r), Int(p.g), Int(p.b))
    }

    func testSaturationZeroDesaturatesRed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)

        let plain = center(doc(effects: []), renderer)
        XCTAssertGreaterThan(plain.r, 200); XCTAssertLessThan(plain.g, 60) // red

        let gray = center(doc(effects: [Effect(id: "ca", type: "colorAdjust",
                                               params: ["saturation": .scalar(.static(0))])]), renderer)
        XCTAssertEqual(gray.r, gray.g, accuracy: 12, "desaturated → r≈g")
        XCTAssertEqual(gray.g, gray.b, accuracy: 12, "desaturated → g≈b")
        XCTAssertLessThan(gray.r, plain.r, "no longer fully red")
    }

    func testNeutralColorAdjustIsANoOp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)
        // brightness 0 / contrast 1 / saturation 1 / hue 0 ⇒ resolveEffects drops it; pixels unchanged.
        let plain = center(doc(effects: []), renderer)
        let neutral = center(doc(effects: [Effect(id: "ca", type: "colorAdjust", params: [
            "brightness": .scalar(.static(0)), "contrast": .scalar(.static(1)),
            "saturation": .scalar(.static(1)), "hue": .scalar(.static(0)),
        ])]), renderer)
        XCTAssertEqual(plain.r, neutral.r, accuracy: 2)
        XCTAssertEqual(plain.g, neutral.g, accuracy: 2)
    }
}
#endif
