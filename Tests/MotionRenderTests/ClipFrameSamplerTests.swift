#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// The clip frame sampler feeds the vision taste analyzer (ai-pipeline.md §3). We export a short
/// clip, then sample it back to JPEG frames.
final class ClipFrameSamplerTests: XCTestCase {
    private var renderer: MetalRenderer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        renderer = try MetalRenderer(device: device)
    }

    private func makeClip(duration: Double = 0.4) throws -> URL {
        let layer = Layer(id: "r", name: "r", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(64, 64)),
                                                       fillColor: .static(ColorValue(hex: "#00C000")!))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(32, 32))))
        let comp = Composition(id: "comp_main", size: Vec2(64, 64), fps: 30, duration: duration,
                               backgroundColor: .black, layers: [layer])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_sampler_\(UInt32.random(in: 0 ..< .max)).mp4")
        try VideoExporter(renderer: renderer).export(document: doc, compId: "comp_main",
                                                     settings: .standard(for: comp), to: url)
        return url
    }

    func testSamplesRequestedFrameCountAsJPEG() async throws {
        let url = try makeClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let sampled = try await ClipFrameSampler.sample(url: url, count: 6, maxDimension: 128)
        XCTAssertEqual(sampled.frames.count, 6, "one frame per requested sample")
        XCTAssertGreaterThan(sampled.fps, 0)
        // Each frame is a real JPEG (SOI marker 0xFFD8).
        for f in sampled.frames {
            XCTAssertGreaterThan(f.count, 2)
            XCTAssertEqual(f.prefix(2), Data([0xFF, 0xD8]), "JPEG SOI marker")
        }
    }
}
#endif
