#if os(macOS)
import XCTest
import Metal
import CoreVideo
import simd
@testable import MotionRender
import MotionKernel

/// The product promise (render-engine.md §7): the offscreen reference render and the actual export
/// render target (a CVPixelBuffer-backed Metal texture — the mechanism MP4/MOV/GIF use) produce the
/// same pixels for the same (document, time). Both go through one `renderScene`; this pins that they
/// never diverge.
final class EquivalenceTests: XCTestCase {
    func testPreviewAndExportTargetsAgree() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)

        // A small, fully-deterministic comp (shapes + opacity composite).
        let layers = [
            Layer(id: "a", name: "a", sortKey: "a0",
                  content: .shape(ShapeContent(geometry: .ellipse, size: .static(Vec2(48, 48)),
                                               fillColor: .static(ColorValue(hex: "#5B8CFF")!))),
                  transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(30, 32)))),
            Layer(id: "b", name: "b", sortKey: "a1",
                  content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(40, 40)),
                                               fillColor: .static(ColorValue(hex: "#FF6B6B")!))),
                  transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 40)),
                                       opacity: .static(0.7))),
        ]
        let comp = Composition(id: "c", size: Vec2(64, 64), fps: 60, duration: 1,
                               backgroundColor: ColorValue(hex: "#101820")!, layers: layers)
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
        let nodes = RenderTreeBuilder(document: doc).build(compId: "c", at: 0)
        let compSize = SIMD2<Float>(64, 64)
        let clear = SIMD4<Double>(comp.backgroundColor.r, comp.backgroundColor.g, comp.backgroundColor.b, 1)

        // Reference: offscreen readback.
        let reference = renderer.renderToImage(nodes: nodes, compSize: compSize,
                                               pixelSize: (64, 64), clear: clear)!

        // Export target: render into a CVPixelBuffer-backed texture, read its bytes back.
        let exported = try renderIntoPixelBuffer(renderer: renderer, device: device, nodes: nodes,
                                                 compSize: compSize, clear: clear, width: 64, height: 64)

        XCTAssertEqual(reference.width, exported.width)
        XCTAssertLessThan(reference.meanAbsoluteDifference(to: exported), 1.0,
                          "offscreen and export-target renders must match")
    }

    /// Mirror of VideoExporter's CVPixelBuffer→Metal path, then read the buffer back as a PixelImage.
    private func renderIntoPixelBuffer(renderer: MetalRenderer, device: MTLDevice, nodes: [RenderNode],
                                       compSize: SIMD2<Float>, clear: SIMD4<Double>,
                                       width: Int, height: Int) throws -> PixelImage {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pbRef: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbRef),
                       kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pbRef)

        var cacheRef: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cacheRef)
        let cache = try XCTUnwrap(cacheRef)
        var cvTex: CVMetalTexture?
        XCTAssertEqual(CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTex),
            kCVReturnSuccess)
        let texture = try XCTUnwrap(CVMetalTextureGetTexture(try XCTUnwrap(cvTex)))

        renderer.render(nodes: nodes, compSize: compSize, clear: clear, into: texture)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            memcpy(&bgra[y * width * 4], row, width * 4)
        }
        return PixelImage(width: width, height: height, bgra: bgra)
    }
}
#endif
