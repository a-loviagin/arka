#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

/// Deterministic motion-signature extraction from frames + the render-compare verifier.
final class MotionSignatureExtractorTests: XCTestCase {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 8, h: Int = 8) -> PixelImage {
        var bgra: [UInt8] = []
        for _ in 0..<(w * h) { bgra += [b, g, r, 255] }
        return PixelImage(width: w, height: h, bgra: bgra)
    }

    func testStaticFramesHaveNoActivityOrOnsets() {
        let black = solid(0, 0, 0)
        let sig = MotionSignatureExtractor.signature(frames: [black, black, black], fps: 10)
        XCTAssertEqual(sig.activity, [0, 0], "no change between identical frames")
        XCTAssertTrue(sig.onsets.isEmpty)
        XCTAssertFalse(sig.palette.isEmpty, "palette still extracted")
    }

    func testChangeProducesActivitySpikeAndOnset() {
        let black = solid(0, 0, 0), white = solid(255, 255, 255)
        // black, black, white, white → big change between frame 1→2.
        let sig = MotionSignatureExtractor.signature(frames: [black, black, white, white], fps: 10)
        XCTAssertEqual(sig.activity.count, 3)
        XCTAssertLessThan(sig.activity[0], 0.01, "still at the start")
        XCTAssertGreaterThan(sig.activity[1], 0.5, "black→white is a large change")
        XCTAssertEqual(sig.onsets.count, 1, "one rising crossing")
        XCTAssertEqual(sig.onsets[0], 0.2, accuracy: 1e-9, "onset at the 3rd frame (index 2) / 10fps")
    }

    func testRenderCompareDistinguishesAnimatedFromStatic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try MetalRenderer(device: device)
        func doc(animated: Bool) -> MotionDocument {
            let pos: AnimatableValue<Vec2> = animated
                ? .animated([Track(keyframes: [Keyframe(t: 0, v: Vec2(20, 50)), Keyframe(t: 1, v: Vec2(80, 50))])])
                : .static(Vec2(50, 50))
            let layer = Layer(id: "s", name: "s", sortKey: "a0",
                              content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(20, 20)),
                                                           fillColor: .static(.white))),
                              transform: Transform(anchor: .static(Vec2(0.5, 0.5)), position: pos))
            let comp = Composition(id: "c", size: Vec2(100, 100), fps: 30, duration: 1,
                                   backgroundColor: .black, layers: [layer])
            return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
        }
        let still = MotionSignatureExtractor.signature(of: doc(animated: false), compId: "c",
                                                       renderer: renderer, width: 100, height: 100)!
        let moving = MotionSignatureExtractor.signature(of: doc(animated: true), compId: "c",
                                                        renderer: renderer, width: 100, height: 100)!
        XCTAssertLessThan(still.meanActivity, 0.01, "a static layer barely moves")
        XCTAssertGreaterThan(moving.meanActivity, still.meanActivity, "the animated layer registers motion")
    }
}
#endif
