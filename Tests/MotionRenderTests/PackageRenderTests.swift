#if os(macOS)
import XCTest
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MotionRender
import MotionKernel

/// Full persistence → reload → render round-trip: write a `.motion` package with a real image
/// asset, read it back, load the asset texture from the package, and render — the asset must
/// survive the trip and appear on the canvas.
final class PackageRenderTests: XCTestCase {
    private var renderer: MetalRenderer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        renderer = try MetalRenderer(device: device)
    }

    func testSaveReloadRendersEmbeddedImage() throws {
        let png = solidPNG(16, 16, r: 0, g: 1, b: 1) // cyan
        let asset = Asset.contentAddressed(id: "img", type: .image, data: png, ext: "png",
                                           pixelSize: Vec2(40, 40))
        let layer = Layer(id: "l", name: "l", sortKey: "a0",
                          content: .image(ImageContent(assetId: "img")),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        let comp = Composition(id: "comp_main", size: Vec2(100, 100), fps: 30, duration: 1,
                               backgroundColor: .black, layers: [layer])
        let doc = MotionDocument(id: "d", assets: [asset],
                                 compositions: [comp], mainCompositionId: "comp_main")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_pkgrender_\(UInt32.random(in: 0 ..< .max)).motion")
        defer { try? FileManager.default.removeItem(at: url) }

        // Save → reload (migrate) → load assets from the package.
        try MotionPackage.write(doc, to: url, assetData: [asset.path: png])
        let loaded = try MotionPackage.read(at: url)
        XCTAssertTrue(MotionPackage.missingAssets(in: url, for: loaded).isEmpty)

        let cache = TextureCache(device: renderer.device)
        for asset in loaded.assets where asset.type == .image {
            XCTAssertNotNil(cache.load(asset: asset, baseURL: url), "asset decodes from package")
        }

        let nodes = RenderTreeBuilder(document: loaded, textures: cache).build(compId: "comp_main", at: 0)
        let img = renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                         pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        let p = img.pixel(50, 50)
        XCTAssertLessThan(p.r, 60, "cyan has low red")
        XCTAssertGreaterThan(p.g, 180, "cyan has high green")
        XCTAssertGreaterThan(p.b, 180, "cyan has high blue")
    }

    private func solidPNG(_ w: Int, _ h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
#endif
