import XCTest
@testable import MotionKernel

/// The CV motion fingerprint + its render-compare distance (ai-pipeline.md §3).
final class MotionSignatureTests: XCTestCase {
    func testDistanceToSelfIsZero() {
        let s = MotionSignature(fps: 10, activity: [0, 0.5, 0.2, 0.0], onsets: [0.2])
        XCTAssertEqual(s.distance(to: s), 0, accuracy: 1e-9)
    }

    func testDistanceGrowsWithMotionDifference() {
        let still = MotionSignature(fps: 10, activity: [0, 0, 0, 0])
        let busy = MotionSignature(fps: 10, activity: [0.8, 0.9, 0.7, 0.85])
        let mild = MotionSignature(fps: 10, activity: [0.1, 0.1, 0.1, 0.1])
        XCTAssertGreaterThan(still.distance(to: busy), still.distance(to: mild),
                             "a very different motion curve is farther than a mildly different one")
    }

    func testOnsetCountPenalty() {
        let a = MotionSignature(fps: 10, activity: [0.5, 0.5], onsets: [0.1])
        let b = MotionSignature(fps: 10, activity: [0.5, 0.5], onsets: [0.1, 0.5, 0.9])
        XCTAssertGreaterThan(a.distance(to: b), 0, "differing onset counts add distance even with the same curve")
    }

    func testDurationAndMeanActivity() {
        let s = MotionSignature(fps: 20, activity: [0.2, 0.4, 0.6]) // 3 deltas ⇒ 3/20s
        XCTAssertEqual(s.duration, 0.15, accuracy: 1e-9)
        XCTAssertEqual(s.meanActivity, 0.4, accuracy: 1e-9)
    }

    func testResampleHandlesShortInput() {
        XCTAssertEqual(MotionSignature.resample([], to: 4), [0, 0, 0, 0])
        XCTAssertEqual(MotionSignature.resample([0.7], to: 3), [0.7, 0.7, 0.7])
    }
}
