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
