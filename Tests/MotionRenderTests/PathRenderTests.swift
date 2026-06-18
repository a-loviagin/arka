#if os(macOS)
import XCTest
import Metal
import simd
@testable import MotionRender
import MotionKernel

final class PathRenderTests: XCTestCase {
    // MARK: Tessellation (no Metal device needed)

    func testQuadTessellatesToTwoTriangles() throws {
        let quad = PathData(subpaths: [.init(vertices: [
            .init(point: Vec2(0, 0)), .init(point: Vec2(100, 0)),
            .init(point: Vec2(100, 100)), .init(point: Vec2(0, 100)),
        ], closed: true)])
        let mesh = try XCTUnwrap(PathTessellator.mesh(quad, fill: SIMD4<Float>(1, 0, 0, 1)))
        XCTAssertEqual(mesh.vertices.count, 6, "a quad fills as 2 triangles")
        XCTAssertEqual(mesh.fill, SIMD4<Float>(1, 0, 0, 1))
    }

    func testDegeneratePathYieldsNoMesh() {
        let line = PathData(subpaths: [.init(vertices: [
            .init(point: Vec2(0, 0)), .init(point: Vec2(10, 0)),
        ], closed: false)])
        XCTAssertNil(PathTessellator.mesh(line, fill: SIMD4<Float>(1, 1, 1, 1)),
                     "two collinear points have no fillable area")
    }

    func testCurvedSegmentAddsInteriorPoints() throws {
        // A closed subpath with one curved edge should flatten to many triangles, not just 2.
        let curvy = PathData(subpaths: [.init(vertices: [
            .init(point: Vec2(0, 100)),
            .init(point: Vec2(100, 100), outTangent: Vec2(0, -80)),
            .init(point: Vec2(50, 0), inTangent: Vec2(40, 0)),
        ], closed: true)])
        let mesh = try XCTUnwrap(PathTessellator.mesh(curvy, fill: SIMD4<Float>(0, 1, 0, 1)))
        XCTAssertGreaterThan(mesh.vertices.count, 6, "a curved edge flattens to many triangles")
    }

    // MARK: Render (needs Metal)

    func testFilledTriangleCoversInteriorNotExterior() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (headless runner)")
        }
        let renderer = try MetalRenderer(device: device)

        let tri = PathData(subpaths: [.init(vertices: [
            .init(point: Vec2(10, 90)), .init(point: Vec2(90, 90)), .init(point: Vec2(50, 10)),
        ], closed: true)])
        let layer = Layer(id: "p", name: "p", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .path,
                                                       fillColor: .static(.white), path: tri)),
                          // anchor (0,0) + position (0,0) → layer-local == comp space.
                          transform: Transform(anchor: .static(Vec2(0, 0)), position: .static(Vec2(0, 0))))
        let comp = Composition(id: "comp_main", size: Vec2(100, 100), fps: 60, duration: 1,
                               backgroundColor: .black, layers: [layer])
        let d = MotionDocument(id: "d", compositions: [comp], mainCompositionId: "comp_main")

        let nodes = RenderTreeBuilder(document: d).build(compId: "comp_main", at: 0)
        XCTAssertEqual(nodes.count, 1, "path layer produces one node")
        let img = renderer.renderToImage(nodes: nodes, compSize: SIMD2<Float>(100, 100),
                                         pixelSize: (100, 100), clear: SIMD4<Double>(0, 0, 0, 1))!
        XCTAssertGreaterThan(img.pixel(50, 70).r, 200, "deep inside the triangle is filled")
        XCTAssertLessThan(img.pixel(15, 20).r, 20, "outside the triangle stays background")
        XCTAssertLessThan(img.pixel(5, 5).r, 20, "corner is background")
    }
}
#endif
