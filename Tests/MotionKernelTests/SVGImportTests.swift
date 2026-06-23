import XCTest
@testable import MotionKernel

/// SVG `d` path-data parsing → editable PathData, and `<path>` extraction with fills.
final class SVGImportTests: XCTestCase {
    func testTriangleMoveLineClose() {
        let subs = SVGPathParser.parse("M0 0 L10 0 L5 10 Z")
        XCTAssertEqual(subs.count, 1)
        XCTAssertTrue(subs[0].closed)
        XCTAssertEqual(subs[0].vertices.map(\.point), [Vec2(0, 0), Vec2(10, 0), Vec2(5, 10)])
        XCTAssertTrue(subs[0].vertices.allSatisfy { $0.inTangent == .zero && $0.outTangent == .zero })
    }

    func testCubicHandlesAreRelative() {
        let subs = SVGPathParser.parse("M0 0 C0 10 10 10 10 0")
        let v = subs[0].vertices
        XCTAssertEqual(v.count, 2)
        XCTAssertEqual(v[0].outTangent, Vec2(0, 10), "out handle = c1 − P0")
        XCTAssertEqual(v[1].inTangent, Vec2(0, 10), "in handle = c2 − P3")
    }

    func testRelativeCommandsAccumulate() {
        let subs = SVGPathParser.parse("m10 10 l5 0 z")
        XCTAssertEqual(subs[0].vertices.map(\.point), [Vec2(10, 10), Vec2(15, 10)])
        XCTAssertTrue(subs[0].closed)
    }

    func testQuadraticRaisedToCubic() {
        let subs = SVGPathParser.parse("M0 0 Q6 12 12 0")
        let v = subs[0].vertices
        // c1 = P0 + 2/3 (C − P0) = (4, 8)
        XCTAssertEqual(v[0].outTangent.x, 4, accuracy: 1e-6)
        XCTAssertEqual(v[0].outTangent.y, 8, accuracy: 1e-6)
    }

    func testHorizontalVerticalLines() {
        let subs = SVGPathParser.parse("M0 0 H10 V10")
        XCTAssertEqual(subs[0].vertices.map(\.point), [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)])
    }

    func testTightlyPackedNumbers() {
        // No separators between negatives / decimals — the classic SVG minifier output.
        let subs = SVGPathParser.parse("M0 0L-1.5-2.5.5.5")
        XCTAssertEqual(subs[0].vertices.map(\.point), [Vec2(0, 0), Vec2(-1.5, -2.5), Vec2(0.5, 0.5)])
    }

    func testMultipleSubpaths() {
        let subs = SVGPathParser.parse("M0 0 L1 0 Z M5 5 L6 5 Z")
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[1].vertices.first?.point, Vec2(5, 5))
    }

    func testArcFlattensToCurveAtEndpoint() {
        let subs = SVGPathParser.parse("M0 0 A5 5 0 0 1 10 0")
        let v = subs[0].vertices
        XCTAssertEqual(v.last!.point.x, 10, accuracy: 1e-3)
        XCTAssertEqual(v.last!.point.y, 0, accuracy: 1e-3)
        XCTAssertGreaterThan(v.count, 2, "arc flattens to multiple cubic vertices")
        XCTAssertTrue(v.dropFirst().contains { $0.inTangent != .zero }, "curve handles present")
    }

    func testArcFlagsPackedWithoutSeparators() {
        // rx=5 ry=5 rot=0 large=0 sweep=1 → "0110 0" packs the two flags + x.
        let subs = SVGPathParser.parse("M0 0A5 5 0 0110 0")
        XCTAssertEqual(subs[0].vertices.last?.point.x ?? -1, 10, accuracy: 1e-3)
    }

    func testRectCircleEllipsePolygon() {
        let svg = """
        <svg><rect x="0" y="0" width="10" height="20"/><circle cx="5" cy="5" r="3"/>
        <ellipse cx="0" cy="0" rx="4" ry="2"/><polygon points="0,0 10,0 5,10"/>
        <line x1="0" y1="0" x2="3" y2="4"/></svg>
        """
        let shapes = SVGImport.shapes(fromSVG: svg)
        XCTAssertEqual(shapes.count, 5)
        XCTAssertEqual(shapes[0].path.subpaths[0].vertices.count, 4, "rect = 4 corners")
        XCTAssertTrue(shapes[0].path.subpaths[0].closed)
        XCTAssertEqual(shapes[1].path.subpaths[0].vertices.count, 4, "circle = 4 bezier verts")
        XCTAssertTrue(shapes[3].path.subpaths[0].closed, "polygon closes")
        XCTAssertFalse(shapes[4].path.subpaths[0].closed, "line is open")
    }

    func testTransformTranslateAndScale() {
        let svg = #"<svg><rect x="0" y="0" width="10" height="10" transform="translate(100,50) scale(2)"/></svg>"#
        let s = SVGImport.shapes(fromSVG: svg)
        // (0,0) → scale 2 → (0,0) → translate (100,50)
        XCTAssertEqual(s[0].path.subpaths[0].vertices[0].point, Vec2(100, 50))
        // (10,0) → scale 2 → (20,0) → translate → (120,50)
        XCTAssertEqual(s[0].path.subpaths[0].vertices[1].point, Vec2(120, 50))
    }

    func testExtractsPathElementsAndFill() {
        let svg = """
        <svg viewBox="0 0 20 20">
          <path d="M0 0 L10 0 L0 10 Z" fill="#FF0000"/>
          <path d="M2 2 L4 2 L4 4 Z" style="fill:none;stroke:#000"/>
        </svg>
        """
        let shapes = SVGImport.shapes(fromSVG: svg)
        XCTAssertEqual(shapes.count, 2)
        XCTAssertEqual(shapes[0].fill?.r ?? 0, 1, accuracy: 0.01, "first fill is red")
        XCTAssertNil(shapes[1].fill, "fill:none → no fill")
        XCTAssertEqual(shapes[0].path.subpaths.first?.vertices.count, 3)
    }
}
