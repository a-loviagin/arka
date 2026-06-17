#if os(macOS)
import XCTest
import Metal
@testable import MotionRender
import MotionKernel

final class ThumbnailTests: XCTestCase {
    private var renderer: MetalRenderer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        renderer = try MetalRenderer(device: device)
    }

    func testThumbnailIsRepresentativePNG() throws {
        // Comp whose content only appears after t=0, so a t=0 thumbnail would be blank but the
        // 25%-duration thumbnail captures the green square.
        let square = Layer(id: "s", name: "s", sortKey: "a0",
                           content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(200, 200)),
                                                        fillColor: .static(ColorValue(hex: "#00FF00")!))),
                           inPoint: 0.5,
                           transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(200, 150))))
        let comp = Composition(id: "comp_main", size: Vec2(400, 300), fps: 30, duration: 2,
                               backgroundColor: .black, layers: [square])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")

        let data = try XCTUnwrap(Thumbnail.png(document: doc, compId: "comp_main", renderer: renderer,
                                               maxDimension: 256))
        let image = try XCTUnwrap(PixelImage.load(pngData: data))
        // Fit 400×300 into 256 → 256×192.
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 192)
        // At 25% of 2s = 0.5s the square is active (inPoint 0.5); center should be green.
        XCTAssertGreaterThan(image.pixel(image.width / 2, image.height / 2).g, 150)
    }
}
#endif
