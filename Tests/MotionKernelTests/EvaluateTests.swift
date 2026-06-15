import XCTest
@testable import MotionKernel

/// Evaluate-stage unit tests (render-engine.md §7.2): resolved values at boundary times.
final class EvaluateTests: XCTestCase {
    func testBeforeFirstReturnsFirst() {
        let track = Track(keyframes: [
            Keyframe(t: 1.0, v: 10.0, interp: .linear),
            Keyframe(t: 2.0, v: 20.0),
        ])
        XCTAssertEqual(track.value(at: 0.0), 10.0)
        XCTAssertEqual(track.value(at: 1.0), 10.0)
    }

    func testAfterLastReturnsLast() {
        let track = Track(keyframes: [
            Keyframe(t: 1.0, v: 10.0, interp: .linear),
            Keyframe(t: 2.0, v: 20.0),
        ])
        XCTAssertEqual(track.value(at: 2.0), 20.0)
        XCTAssertEqual(track.value(at: 99.0), 20.0)
    }

    func testLinearMidpoint() {
        let track = Track(keyframes: [
            Keyframe(t: 0.0, v: 0.0, interp: .linear),
            Keyframe(t: 1.0, v: 100.0),
        ])
        XCTAssertEqual(track.value(at: 0.5), 50.0, accuracy: 1e-9)
        XCTAssertEqual(track.value(at: 0.25), 25.0, accuracy: 1e-9)
    }

    func testHoldStaysUntilNext() {
        let track = Track(keyframes: [
            Keyframe(t: 0.0, v: 5.0, interp: .hold),
            Keyframe(t: 1.0, v: 50.0),
        ])
        XCTAssertEqual(track.value(at: 0.99), 5.0)
        XCTAssertEqual(track.value(at: 1.0), 50.0)
    }

    func testBezierMonotonicAndBounded() {
        let track = Track(keyframes: [
            Keyframe(t: 0.0, v: 0.0, interp: .bezier, easeOut: ControlPoint(0.33, 0)),
            Keyframe(t: 1.0, v: 100.0, easeIn: ControlPoint(0.67, 1)),
        ])
        var prev = -1.0
        for i in 0...100 {
            let v = track.value(at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, -0.001)
            XCTAssertLessThanOrEqual(v, 100.001)
            XCTAssertGreaterThanOrEqual(v, prev - 1e-6, "ease-in-out should be monotonic")
            prev = v
        }
    }

    func testSeparatedDimensionTracks() {
        // X animates 0→100, Y stays at 50 via a separate component track.
        let value: AnimatableValue<Vec2> = .animated([
            Track(component: .x, keyframes: [
                Keyframe(t: 0, v: Vec2(0, 0), interp: .linear),
                Keyframe(t: 1, v: Vec2(100, 0)),
            ]),
            Track(component: .y, keyframes: [
                Keyframe(t: 0, v: Vec2(0, 50)),
            ]),
        ])
        let mid = value.resolve(at: 0.5)
        XCTAssertEqual(mid.x, 50, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 50, accuracy: 1e-9)
    }

    func testSpringStartsAtSourceAndApproachesTarget() {
        let track = Track(keyframes: [
            Keyframe(t: 0.0, v: 0.0, interp: .spring(.snappy)),
            Keyframe(t: 4.0, v: 100.0),
        ])
        XCTAssertEqual(track.value(at: 0.0), 0.0, accuracy: 1e-6)
        // Well after settle, value is essentially the target.
        XCTAssertEqual(track.value(at: 3.99), 100.0, accuracy: 0.5)
    }

    func testStaticResolves() {
        let v: AnimatableValue<Double> = .static(0.7)
        XCTAssertEqual(v.resolve(at: 123.0), 0.7)
        XCTAssertFalse(v.isAnimated)
    }
}
