#if os(macOS)
import XCTest
import AVFoundation
import CoreGraphics
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// End-to-end video playback: export a solid-color clip with VideoExporter, then render a video
/// layer that references it through VideoFrameProvider and assert the decoded frame reaches the
/// framebuffer. Exercises decode → texture → image-quad render headlessly.
final class VideoRenderTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: MetalRenderer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        self.device = device
        self.renderer = try MetalRenderer(device: device)
    }

    /// Render a small green clip to a temp .mp4 and return its URL (caller deletes it).
    private func makeClip() throws -> URL {
        let layer = Layer(id: "r", name: "r", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(64, 64)),
                                                       fillColor: .static(ColorValue(hex: "#00C000")!))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(32, 32))))
        let comp = Composition(id: "comp_main", size: Vec2(64, 64), fps: 30, duration: 0.3,
                               backgroundColor: .black, layers: [layer])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_video_\(UInt32.random(in: 0..<UInt32.max)).mp4")
        try VideoExporter(renderer: renderer).export(document: doc, compId: "comp_main",
                                                     settings: .standard(for: comp), to: url)
        return url
    }

    func testVideoLayerRendersDecodedFrame() throws {
        let url = try makeClip()
        defer { try? FileManager.default.removeItem(at: url) }

        // A doc whose video layer points at the exported clip (absolute path → no baseURL).
        let asset = Asset(id: "vid", type: .video, path: url.path, pixelSize: Vec2(64, 64))
        let layer = Layer(id: "v", name: "v", sortKey: "a0",
                          content: .video(VideoContent(assetId: "vid")),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        let comp = Composition(id: "comp_main", size: Vec2(100, 100), fps: 30, duration: 1,
                               backgroundColor: .black, layers: [layer])
        let doc = MotionDocument(id: "d", assets: [asset], compositions: [comp],
                                 mainCompositionId: "comp_main")

        let provider = VideoFrameProvider(device: device)
        let nodes = RenderTreeBuilder(document: doc, video: provider).build(compId: "comp_main", at: 0.1)
        XCTAssertEqual(nodes.count, 1, "video layer produces one node at t=0.1")

        let img = renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                         pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        // Center is inside the 64×64 video quad (comp 18…82) → green; corner is background.
        let c = img.pixel(50, 50)
        XCTAssertGreaterThan(c.g, 120, "decoded video frame is green at center")
        XCTAssertLessThan(c.r, 120, "green, not red/white")
        XCTAssertLessThan(img.pixel(5, 5).r + img.pixel(5, 5).g + img.pixel(5, 5).b, 30,
                          "outside the video quad is background")
    }

    func testVideoCompositesIntoExportedMovie() throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let asset = Asset(id: "vid", type: .video, path: clip.path, pixelSize: Vec2(64, 64))
        let layer = Layer(id: "v", name: "v", sortKey: "a0",
                          content: .video(VideoContent(assetId: "vid")),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        let comp = Composition(id: "comp_main", size: Vec2(100, 100), fps: 30, duration: 0.3,
                               backgroundColor: .black, layers: [layer])
        let doc = MotionDocument(id: "d", assets: [asset], compositions: [comp], mainCompositionId: "comp_main")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_video_export_\(UInt32.random(in: 0..<UInt32.max)).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        // Export with a video provider — the video layer must composite into the file.
        try VideoExporter(renderer: renderer, video: VideoFrameProvider(device: device))
            .export(document: doc, compId: "comp_main", settings: .standard(for: comp), to: out)

        // Read a frame of the exported movie back; its centre should be the (green) video, not black.
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        g.appliesPreferredTrackTransform = true
        let cg = try g.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        let c = centerPixel(cg)
        XCTAssertGreaterThan(c.g, 100, "exported frame's centre is the green video")
        XCTAssertGreaterThan(c.g, c.r, "green channel dominates")
    }

    /// Center pixel (sRGB) of a decoded frame.
    private func centerPixel(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    func testMissingProviderSkipsVideoLayer() {
        let asset = Asset(id: "vid", type: .video, path: "/nonexistent.mp4")
        let layer = Layer(id: "v", name: "v", sortKey: "a0", content: .video(VideoContent(assetId: "vid")),
                          transform: Transform(position: .static(Vec2(50, 50))))
        let comp = Composition(id: "comp_main", size: Vec2(100, 100), fps: 30, duration: 1,
                               backgroundColor: .black, layers: [layer])
        let doc = MotionDocument(id: "d", assets: [asset], compositions: [comp], mainCompositionId: "comp_main")
        // No provider → the layer is skipped, not a crash.
        XCTAssertTrue(RenderTreeBuilder(document: doc).build(compId: "comp_main", at: 0).isEmpty)
    }
}
#endif
