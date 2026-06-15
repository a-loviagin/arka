import XCTest
@testable import MotionKernel

final class EasingTests: XCTestCase {
    func testEndpoints() {
        let p1 = ControlPoint(0.33, 0), p2 = ControlPoint(0.67, 1)
        XCTAssertEqual(Easing.solveCubicBezier(p1, p2, 0), 0, accuracy: 1e-9)
        XCTAssertEqual(Easing.solveCubicBezier(p1, p2, 1), 1, accuracy: 1e-9)
    }

    func testLinearControlPointsApproxIdentity() {
        let p1 = ControlPoint(1.0 / 3, 1.0 / 3), p2 = ControlPoint(2.0 / 3, 2.0 / 3)
        for i in 0...10 {
            let t = Double(i) / 10
            XCTAssertEqual(Easing.solveCubicBezier(p1, p2, t), t, accuracy: 1e-6)
        }
    }

    func testEaseOutStartsFast() {
        // ease-out: progress at t=0.25 should exceed linear 0.25.
        let p1 = ControlPoint(0.0, 0.0), p2 = ControlPoint(0.58, 1.0)
        XCTAssertGreaterThan(Easing.solveCubicBezier(p1, p2, 0.25), 0.25)
    }
}

final class SpringTests: XCTestCase {
    func testInitialDisplacementEqualsX0() {
        let s = Spring.bouncy
        XCTAssertEqual(s.displacement(x0: -100, v0: 0, at: 0), -100, accuracy: 1e-9)
    }

    func testSettlesTowardZero() {
        let s = Spring.gentle
        let late = s.displacement(x0: -100, v0: 0, at: 5)
        XCTAssertLessThan(abs(late), 1.0)
    }

    func testSettleTimeIsFiniteAndPositive() {
        let s = Spring.bouncy
        let settle = s.settleTime(x0: 100, v0: 0)
        XCTAssertGreaterThan(settle, 0)
        XCTAssertLessThan(settle, 30)
    }

    func testBouncyOvershoots() {
        // Underdamped spring should cross past the target (displacement changes sign).
        let s = Spring.bouncy
        var sawPositive = false, sawNegative = false
        var t = 0.0
        while t < 3 {
            let d = s.displacement(x0: -100, v0: 0, at: t)
            if d > 0.5 { sawPositive = true }
            if d < -0.5 { sawNegative = true }
            t += 1.0 / 120
        }
        XCTAssertTrue(sawNegative && sawPositive, "bouncy spring should overshoot")
    }
}

final class ColorTests: XCTestCase {
    func testHexRoundTripsComponents() {
        let c = ColorValue(hex: "#3366FF")!
        XCTAssertEqual(c.r, 0x33 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(c.g, 0x66 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(c.b, 0xFF / 255.0, accuracy: 1e-9)
        XCTAssertEqual(c.a, 1, accuracy: 1e-9)
    }

    func testOKLabLerpEndpointsExact() {
        let a = ColorValue(hex: "#000000")!
        let b = ColorValue(hex: "#FFFFFF")!
        let at0 = ColorValue.lerp(a, b, 0)
        let at1 = ColorValue.lerp(a, b, 1)
        XCTAssertEqual(at0.r, 0, accuracy: 1e-6)
        XCTAssertEqual(at1.r, 1, accuracy: 1e-6)
    }

    func testOKLabMidpointStaysInGamut() {
        let a = ColorValue(hex: "#FF0000")!
        let b = ColorValue(hex: "#00FF00")!
        let mid = ColorValue.lerp(a, b, 0.5)
        for c in [mid.r, mid.g, mid.b] {
            XCTAssertGreaterThanOrEqual(c, 0)
            XCTAssertLessThanOrEqual(c, 1)
        }
    }
}

final class SortKeyTests: XCTestCase {
    func testBetweenOrders() {
        let a = SortKey.between(nil, nil)
        let before = SortKey.between(nil, a)
        let after = SortKey.between(a, nil)
        XCTAssertLessThan(before, a)
        XCTAssertLessThan(a, after)
    }

    func testRepeatedInsertBetweenStaysOrdered() {
        var lo = SortKey("a0")
        let hi = SortKey("a1")
        var prev = lo
        for _ in 0..<50 {
            let mid = SortKey.between(lo, hi)
            XCTAssertLessThan(lo, mid, "mid must exceed lower")
            XCTAssertLessThan(mid, hi, "mid must be below upper")
            XCTAssertNotEqual(mid, prev)
            lo = mid
            prev = mid
        }
    }

    func testStableUnderManyMidpoints() {
        // Inserting repeatedly between first two keeps a strict total order.
        var keys = [SortKey("a0"), SortKey("a5"), SortKey("aA")]
        for _ in 0..<100 {
            let mid = SortKey.between(keys[0], keys[1])
            keys.insert(mid, at: 1)
            let sorted = keys.sorted()
            XCTAssertEqual(keys, sorted, "keys should already be in sorted order")
            // keep list small
            if keys.count > 6 { keys.removeSubrange(2..<(keys.count - 1)) }
        }
    }
}
