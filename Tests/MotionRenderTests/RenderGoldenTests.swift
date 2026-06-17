#if os(macOS)
import XCTest
import Metal
import simd
import CoreGraphics
@testable import MotionRender
import MotionKernel

/// The renderer-conformance suite (render-engine.md §7). Two layers:
///  - **Structural assertions** — self-validating: render small docs and assert specific pixels
///    equal the resolved colors (background, fill, opacity composite, animation over time, SDF
///    ellipse). These prove the renderer is *correct*, not merely unchanged.
///  - **Golden pin** — a checked-in PNG compared with perceptual tolerance; catches regressions.
///
/// Needs a Metal device; skips cleanly where none exists.
final class RenderGoldenTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: MetalRenderer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (headless runner)")
        }
        self.device = device
        self.renderer = try MetalRenderer(device: device)
    }

    // MARK: Helpers

    private func render(_ doc: MotionDocument, at t: TimeInterval,
                        size: Int, textEngine: TextEngine? = nil) -> PixelImage {
        let comp = doc.mainComposition!
        let nodes = RenderTreeBuilder(document: doc, textEngine: textEngine, textures: textureProvider)
            .build(compId: comp.id, at: t)
        let bg = comp.backgroundColor
        return renderer.renderToImage(
            nodes: nodes,
            compSize: SIMD2<Float>(Float(comp.size.x), Float(comp.size.y)),
            pixelSize: (size, size),
            clear: SIMD4<Double>(bg.r, bg.g, bg.b, bg.a))!
    }

    /// Optional texture provider for tests that render image layers (set per-test).
    var textureProvider: (any TextureProvider)?

    private func doc(size: Double, bg: ColorValue, layers: [Layer]) -> MotionDocument {
        let comp = Composition(id: "comp_main", size: Vec2(size, size), fps: 60,
                               duration: 2, backgroundColor: bg, layers: layers)
        return MotionDocument(id: "doc", compositions: [comp], mainCompositionId: "comp_main")
    }

    private func rect(_ id: String, at pos: Vec2, size: Vec2, fill: ColorValue,
                      opacity: AnimatableValue<Double> = .static(1),
                      position: AnimatableValue<Vec2>? = nil,
                      geometry: ShapeGeometry = .rect, sortKey: SortKey = "a0") -> Layer {
        Layer(id: EntityID(id), name: id, sortKey: sortKey,
              content: .shape(ShapeContent(geometry: geometry, size: .static(size),
                                           fillColor: .static(fill))),
              transform: Transform(anchor: .static(Vec2(0.5, 0.5)),
                                   position: position ?? .static(pos),
                                   opacity: opacity))
    }

    private func assertChannel(_ actual: UInt8, _ expected: Int, tol: Int = 3,
                               _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(Int(actual) - expected), tol,
                                 "\(msg): got \(actual), expected ~\(expected)", file: file, line: line)
    }

    // MARK: Structural tests

    func testBackgroundClears() {
        let d = doc(size: 64, bg: ColorValue(hex: "#0E0E14")!, layers: [])
        let img = render(d, at: 0, size: 64)
        let p = img.pixel(32, 32)
        assertChannel(p.r, 14, "bg.r"); assertChannel(p.g, 14, "bg.g"); assertChannel(p.b, 20, "bg.b")
    }

    func testFilledRectCenterAndCorner() {
        let d = doc(size: 100, bg: .black,
                    layers: [rect("r", at: Vec2(50, 50), size: Vec2(60, 60),
                                  fill: ColorValue(hex: "#FF0000")!)])
        let img = render(d, at: 0, size: 100)
        let center = img.pixel(50, 50)
        assertChannel(center.r, 255, "fill.r"); assertChannel(center.g, 0, "fill.g")
        assertChannel(center.b, 0, "fill.b")
        let corner = img.pixel(5, 5) // outside the 20…80 rect → background
        assertChannel(corner.r, 0, "corner.r")
    }

    func testOpacityCompositesOverBackground() {
        // White rect at 50% opacity over black → ~half gray (pre-multiplied "over").
        let d = doc(size: 64, bg: .black,
                    layers: [rect("r", at: Vec2(32, 32), size: Vec2(50, 50),
                                  fill: .white, opacity: .static(0.5))])
        let img = render(d, at: 0, size: 64)
        let p = img.pixel(32, 32)
        assertChannel(p.r, 128, tol: 4, "half.r")
        assertChannel(p.g, 128, tol: 4, "half.g")
        assertChannel(p.b, 128, tol: 4, "half.b")
    }

    func testAnimationMovesShapeOverTime() {
        // Rect slides left→right; sample the left third at t0 (covered) vs t1 (uncovered).
        let pos: AnimatableValue<Vec2> = .animated([Track(keyframes: [
            Keyframe(t: 0, v: Vec2(25, 50), interp: .linear),
            Keyframe(t: 1, v: Vec2(75, 50)),
        ])])
        let d = doc(size: 100, bg: .black,
                    layers: [rect("r", at: .zero, size: Vec2(30, 30),
                                  fill: ColorValue(hex: "#00FF00")!, position: pos)])
        let early = render(d, at: 0, size: 100)
        let late = render(d, at: 1, size: 100)
        // At t0 the rect is centered near x=25; at t1 near x=75. Pixel (25,50) flips covered→bg.
        XCTAssertGreaterThan(early.pixel(25, 50).g, 200, "rect should cover left at t0")
        XCTAssertLessThan(late.pixel(25, 50).g, 50, "rect should have left x=25 by t1")
        XCTAssertGreaterThan(late.pixel(75, 50).g, 200, "rect should cover right at t1")
    }

    func testEllipseSDFExcludesCorners() {
        // An ellipse filling the comp: center is inside (fill), bounding-box corner is outside (bg).
        let d = doc(size: 100, bg: .black,
                    layers: [rect("e", at: Vec2(50, 50), size: Vec2(96, 96),
                                  fill: ColorValue(hex: "#FFFFFF")!, geometry: .ellipse)])
        let img = render(d, at: 0, size: 100)
        XCTAssertGreaterThan(img.pixel(50, 50).r, 200, "ellipse center filled")
        XCTAssertLessThan(img.pixel(5, 5).r, 50, "ellipse excludes the bounding-box corner")
    }

    func testTextProducesCoverage() throws {
        guard let textEngine = TextEngine(device: device) else {
            throw XCTSkip("No text engine")
        }
        let text = Layer(id: "t", name: "t", sortKey: "a0",
                         content: .text(TextContent(string: "I", fontFamily: "Helvetica",
                                                    fontSize: .static(80), fillColor: .static(.white),
                                                    alignment: .center)),
                         transform: Transform(anchor: .static(Vec2(0.5, 0.5)),
                                              position: .static(Vec2(50, 20))))
        let d = doc(size: 100, bg: .black, layers: [text])
        let img = render(d, at: 0, size: 100, textEngine: textEngine)
        var lit = 0
        for y in 0..<100 { for x in 0..<100 where img.pixel(x, y).r > 60 { lit += 1 } }
        XCTAssertGreaterThan(lit, 20, "glyph 'I' should light up a column of pixels")
    }

    func testImageLayerRendersTextureColor() throws {
        // Register a solid-magenta image, place it as a centered image layer, assert the texture
        // samples through to the framebuffer.
        let cache = TextureCache(device: device)
        let cg = makeSolidCGImage(32, 32, r: 1, g: 0, b: 1)
        XCTAssertNotNil(cache.register(id: "asset_m", cgImage: cg))

        let layer = Layer(id: "img", name: "img", sortKey: "a0",
                          content: .image(ImageContent(assetId: "asset_m")),
                          transform: Transform(anchor: .static(Vec2(0.5, 0.5)),
                                               position: .static(Vec2(50, 50))))
        let comp = Composition(id: "comp_main", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [layer])
        let d = MotionDocument(id: "doc",
                               assets: [Asset(id: "asset_m", type: .image, path: "x.png",
                                              pixelSize: Vec2(40, 40))],
                               compositions: [comp], mainCompositionId: "comp_main")

        let nodes = RenderTreeBuilder(document: d, textures: cache).build(compId: "comp_main", at: 0)
        XCTAssertEqual(nodes.count, 1, "image layer should produce one render node")
        let img = renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                         pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        let p = img.pixel(50, 50)
        assertChannel(p.r, 255, "image.r"); assertChannel(p.g, 0, "image.g"); assertChannel(p.b, 255, "image.b")
        // Corner is outside the 40×40 centered image (comp 30…70) → background.
        assertChannel(img.pixel(5, 5).r, 0, "outside image is bg")
    }

    private func makeSolidCGImage(_ w: Int, _ h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs, bitmapInfo: info)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    // MARK: Effects

    private func shapeLayer(_ id: String, at pos: Vec2, size: Vec2, fill: ColorValue,
                            effects: [Effect]) -> Layer {
        Layer(id: EntityID(id), name: id, sortKey: "a0",
              content: .shape(ShapeContent(geometry: .rect, size: .static(size), fillColor: .static(fill))),
              transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(pos)),
              effects: effects)
    }

    func testBlurSpreadsCoverageBeyondSharpBounds() {
        // A white rect spans comp 30…70. A pixel 4px outside the right edge is bg when sharp,
        // but picks up coverage once blurred.
        let sharp = doc(size: 100, bg: .black,
                        layers: [shapeLayer("r", at: Vec2(50, 50), size: Vec2(40, 40), fill: .white, effects: [])])
        let blur = Effect(id: "fx", type: "blur", params: ["radius": .scalar(.static(8))])
        let blurred = doc(size: 100, bg: .black,
                          layers: [shapeLayer("r", at: Vec2(50, 50), size: Vec2(40, 40), fill: .white, effects: [blur])])

        let sharpImg = render(sharp, at: 0, size: 100)
        let blurImg = render(blurred, at: 0, size: 100)
        XCTAssertLessThan(sharpImg.pixel(74, 50).r, 10, "sharp rect should not reach x=74")
        XCTAssertGreaterThan(blurImg.pixel(74, 50).r, 20, "blur should spread coverage past the edge")
        // Center stays essentially full.
        XCTAssertGreaterThan(blurImg.pixel(50, 50).r, 180, "blurred center still bright")
    }

    func testShadowCastsOffsetTintedPixels() {
        // White rect (25…55) with a red shadow offset (15,15). A point at (65,65) is outside the
        // rect but inside the shadow → reddish; without the shadow it's background.
        let shadow = Effect(id: "fx", type: "shadow", params: [
            "offset": .vec2(.static(Vec2(15, 15))),
            "radius": .scalar(.static(6)),
            "color": .color(.static(ColorValue(hex: "#FF0000")!)),
            "opacity": .scalar(.static(0.9)),
        ])
        let withShadow = doc(size: 100, bg: .black,
                             layers: [shapeLayer("r", at: Vec2(40, 40), size: Vec2(30, 30), fill: .white, effects: [shadow])])
        let without = doc(size: 100, bg: .black,
                          layers: [shapeLayer("r", at: Vec2(40, 40), size: Vec2(30, 30), fill: .white, effects: [])])

        let s = render(withShadow, at: 0, size: 100)
        let n = render(without, at: 0, size: 100)
        XCTAssertLessThan(n.pixel(65, 65).r, 10, "no content at (65,65) without a shadow")
        let p = s.pixel(65, 65)
        XCTAssertGreaterThan(p.r, 30, "shadow should tint (65,65) red")
        XCTAssertLessThan(p.b, p.r, "shadow tint is red, not white")
        // The sharp rect itself is still white on top.
        XCTAssertGreaterThan(s.pixel(40, 40).r, 180, "rect content survives over its shadow")
        XCTAssertGreaterThan(s.pixel(40, 40).b, 180, "rect is white, shadow only behind it")
    }

    // MARK: Precomp

    func testPrecompRendersThroughParentTransform() {
        // Sub-comp: a white square filling its 50×50 frame.
        let sub = Composition(id: "comp_sub", size: Vec2(50, 50), fps: 60, duration: 1,
                              backgroundColor: .clear, layers: [
            Layer(id: "r", name: "r", sortKey: "a0",
                  content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(50, 50)), fillColor: .static(.white))),
                  transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(25, 25))))
        ])
        // Main comp: nests the sub-comp centered (50×50 quad → spans comp 25…75).
        let main = Composition(id: "comp_main", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [
            Layer(id: "pc", name: "pc", sortKey: "a0",
                  content: .precomp(PrecompContent(compositionId: "comp_sub")),
                  transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50))))
        ])
        let d = MotionDocument(id: "d", compositions: [main, sub], mainCompositionId: "comp_main")
        let img = render(d, at: 0, size: 100)
        XCTAssertGreaterThan(img.pixel(50, 50).r, 200, "precomp content visible at center")
        XCTAssertGreaterThan(img.pixel(30, 50).r, 200, "precomp covers comp 25…75")
        XCTAssertLessThan(img.pixel(18, 50).r, 20, "left of the precomp is background")
        XCTAssertLessThan(img.pixel(5, 5).r, 20, "corner is background")
    }

    func testPrecompAppliesItsOwnOpacity() {
        let sub = Composition(id: "comp_sub", size: Vec2(50, 50), fps: 60, duration: 1,
                              backgroundColor: .clear, layers: [
            Layer(id: "r", name: "r", sortKey: "a0",
                  content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(50, 50)), fillColor: .static(.white))),
                  transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(25, 25))))
        ])
        let main = Composition(id: "comp_main", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [
            Layer(id: "pc", name: "pc", sortKey: "a0",
                  content: .precomp(PrecompContent(compositionId: "comp_sub")),
                  transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: .static(Vec2(50, 50)),
                                       opacity: .static(0.5)))
        ])
        let d = MotionDocument(id: "d", compositions: [main, sub], mainCompositionId: "comp_main")
        let img = render(d, at: 0, size: 100)
        // White sub-content at 50% over black → ~half gray; opacity applies to the whole precomp.
        assertChannel(img.pixel(50, 50).r, 128, tol: 6, "precomp opacity halves white")
    }

    // MARK: IO + golden pin

    func testPNGRoundTrip() throws {
        let d = doc(size: 32, bg: ColorValue(hex: "#204060")!,
                    layers: [rect("r", at: Vec2(16, 16), size: Vec2(16, 16), fill: .white)])
        let img = render(d, at: 0, size: 32)
        let png = try XCTUnwrap(img.pngData())
        let back = try XCTUnwrap(PixelImage.load(pngData: png))
        XCTAssertEqual(img.width, back.width)
        XCTAssertLessThan(img.meanAbsoluteDifference(to: back), 1.0, "PNG round-trip should be lossless")
    }

    /// Golden pin for a pure-shape frame (font-independent). First run writes the golden and fails
    /// so it gets committed; later runs compare with perceptual tolerance.
    func testShapeGolden() throws {
        let d = doc(size: 96, bg: ColorValue(hex: "#101820")!, layers: [
            rect("a", at: Vec2(36, 48), size: Vec2(44, 44), fill: ColorValue(hex: "#5B8CFF")!,
                 geometry: .ellipse, sortKey: "a0"),
            rect("b", at: Vec2(60, 48), size: Vec2(44, 44), fill: ColorValue(hex: "#FF6B6B")!,
                 opacity: .static(0.7), sortKey: "a1"),
        ])
        let img = render(d, at: 0, size: 96)
        try compareToGolden(img, named: "shape_two_overlap")
    }

    private func compareToGolden(_ img: PixelImage, named name: String,
                                 tolerance: Double = 2.0) throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Goldens")
        let url = dir.appending(path: "\(name).png")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try XCTUnwrap(img.pngData()).write(to: url)
            XCTFail("Golden '\(name)' created at \(url.path) — inspect & commit it, then re-run.")
            return
        }
        let golden = try XCTUnwrap(PixelImage.load(pngData: Data(contentsOf: url)))
        let mad = img.meanAbsoluteDifference(to: golden)
        XCTAssertLessThan(mad, tolerance, "golden '\(name)' drifted (mean abs diff \(mad))")
    }
}
#endif
