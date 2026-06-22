#if os(macOS)
import XCTest
import simd
@testable import MotionRender
import MotionKernel

/// The multi-frame board (editor-ui.md §1): `buildBoard` turns every composition into a placed
/// `Precomp`, and `boardProjection` maps board space → NDC under pan/zoom. Together they let the
/// existing precomp-composite path draw all frames at once.
final class BoardRenderTests: XCTestCase {
    private func twoFrameDoc() -> MotionDocument {
        let a = Composition(id: "a", name: "A", size: Vec2(200, 200), fps: 60, duration: 1,
                            backgroundColor: .black, layers: [])
        let b = Composition(id: "b", name: "B", size: Vec2(300, 200), fps: 60, duration: 1,
                            backgroundColor: .white, layers: [], boardPosition: Vec2(280, 0))
        return MotionDocument(id: "d", compositions: [a, b], mainCompositionId: "a")
    }

    func testBuildBoardPlacesEveryCompositionAsAPrecomp() {
        let nodes = RenderTreeBuilder(document: twoFrameDoc()).buildBoard(at: 0)
        XCTAssertEqual(nodes.count, 2, "one node per frame")
        for node in nodes {
            guard case .precomp = node else { return XCTFail("frames must be precomp nodes") }
        }
    }

    func testBoardProjectionMapsCornersToNDC() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try MetalRenderer(device: device)
        let proj = r.boardProjection(pan: SIMD2<Float>(0, 0), zoom: 1, viewport: SIMD2<Float>(100, 100))
        let topLeft = proj * SIMD3<Float>(0, 0, 1)      // board origin → NDC top-left
        let bottomRight = proj * SIMD3<Float>(100, 100, 1)
        XCTAssertEqual(topLeft.x, -1, accuracy: 1e-5)
        XCTAssertEqual(topLeft.y, 1, accuracy: 1e-5)
        XCTAssertEqual(bottomRight.x, 1, accuracy: 1e-5)
        XCTAssertEqual(bottomRight.y, -1, accuracy: 1e-5)
    }

    func testBoardProjectionPanAndZoomShiftAndScale() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try MetalRenderer(device: device)
        // Pan by +50px, zoom 2×: board point (0,0) lands at pixel (50,50) = NDC (0,0) for a 100px view.
        let proj = r.boardProjection(pan: SIMD2<Float>(50, 50), zoom: 2, viewport: SIMD2<Float>(100, 100))
        let origin = proj * SIMD3<Float>(0, 0, 1)
        XCTAssertEqual(origin.x, 0, accuracy: 1e-5)
        XCTAssertEqual(origin.y, 0, accuracy: 1e-5)
    }
}
#endif
