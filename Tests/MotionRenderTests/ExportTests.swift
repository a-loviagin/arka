#if os(macOS)
import XCTest
import AVFoundation
import CoreGraphics
import Metal
@testable import MotionRender
import MotionKernel

/// End-to-end export verification: render a tiny comp to an H.264 file, then read it back with
/// AVFoundation and assert it's a valid video of the right size/duration with the expected pixels.
/// This exercises the whole offscreen → CVPixelBuffer → AVAssetWriter pipeline headlessly.
final class ExportTests: XCTestCase {
    private var renderer: MetalRenderer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        renderer = try MetalRenderer(device: device)
    }

    func testExportsValidVideoWithExpectedPixels() async throws {
        // Comp: red square filling the frame on black, 0.2s @ 60fps.
        let layer = Layer(id: "r", name: "r", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(64, 48)),
                                                       fillColor: .static(ColorValue(hex: "#FF0000")!))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(32, 24))))
        let comp = Composition(id: "comp_main", size: Vec2(64, 48), fps: 60, duration: 0.2,
                               backgroundColor: .black, layers: [layer])
        let doc = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_export_test_\(UInt32.random(in: 0..<UInt32.max)).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        var lastProgress = 0.0
        let exporter = VideoExporter(renderer: renderer)
        try exporter.export(document: doc, compId: "comp_main",
                            settings: .standard(for: comp), to: url,
                            progress: { lastProgress = $0 })

        XCTAssertEqual(lastProgress, 1.0, accuracy: 1e-6, "progress should reach 100%")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "export should produce a non-empty file")

        // Read it back.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.2, accuracy: 0.05, "duration ~= 0.2s")

        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first, "video track present")
        let natural = try await track.load(.naturalSize)
        XCTAssertEqual(natural.width, 64, accuracy: 1)
        XCTAssertEqual(natural.height, 48, accuracy: 1)

        // Decode a frame and check the center pixel is red.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let (cg, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let (r, g, b) = centerPixel(cg)
        XCTAssertGreaterThan(r, 150, "exported frame center should be red (R)")
        XCTAssertLessThan(g, 110, "low green")
        XCTAssertLessThan(b, 110, "low blue")
    }

    private func redSquareDoc() -> MotionDocument {
        let layer = Layer(id: "r", name: "r", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(64, 48)),
                                                       fillColor: .static(ColorValue(hex: "#FF0000")!))),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(32, 24))))
        let comp = Composition(id: "comp_main", size: Vec2(64, 48), fps: 30, duration: 0.3,
                               backgroundColor: .black, layers: [layer])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")
    }

    func testExportsProResMOV() async throws {
        let doc = redSquareDoc()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_prores_\(UInt32.random(in: 0 ..< .max)).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = VideoExporter.Settings.proResAlpha(for: doc.mainComposition!)
        try VideoExporter(renderer: renderer).export(document: doc, compId: "comp_main",
                                                     settings: settings, to: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 64, accuracy: 1)
        XCTAssertEqual(size.height, 48, accuracy: 1)
    }

    func testExportsGIFWithFrames() throws {
        let doc = redSquareDoc()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_gif_\(UInt32.random(in: 0 ..< .max)).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try GIFExporter.export(document: doc, compId: "comp_main", renderer: renderer,
                               width: 64, height: 48, fps: 20, startTime: 0, endTime: 0.3, to: url)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 6, "0.3s @ 20fps = 6 frames")
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let (r, g, b) = centerPixel(frame)
        XCTAssertGreaterThan(r, 150); XCTAssertLessThan(g, 110); XCTAssertLessThan(b, 110)
    }

    func testExportsPNGSequence() throws {
        let doc = redSquareDoc()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_seq_\(UInt32.random(in: 0 ..< .max))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ImageSequenceExporter.export(document: doc, compId: "comp_main", renderer: renderer,
                                         width: 64, height: 48, fps: 30, startTime: 0, endTime: 0.3,
                                         transparent: false, to: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files.count, 9, "0.3s @ 30fps = 9 frames")
        XCTAssertEqual(files.first, "frame_0000.png")
        let data = try Data(contentsOf: dir.appendingPathComponent(files[0]))
        let img = try XCTUnwrap(PixelImage.load(pngData: data))
        XCTAssertGreaterThan(img.pixel(32, 24).r, 150, "center is red")
    }

    private func centerPixel(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: cs, bitmapInfo: info)!
        // Draw the image so its center lands on our 1×1 sample.
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5,
                                   y: -CGFloat(image.height) / 2 + 0.5,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
}
#endif
