import XCTest
@testable import MotionKernel

final class TimelineDigestTests: XCTestCase {
    func testKeyframeTimesUnionAndSort() {
        let value: AnimatableValue<Vec2> = .animated([
            Track(component: .x, keyframes: [Keyframe(t: 1.0, v: Vec2(0, 0)), Keyframe(t: 0.0, v: Vec2(0, 0))]),
            Track(component: .y, keyframes: [Keyframe(t: 0.0, v: Vec2(0, 0)), Keyframe(t: 2.0, v: Vec2(0, 0))]),
        ])
        XCTAssertEqual(TimelineDigest.keyframeTimes(of: value), [0.0, 1.0, 2.0])
        XCTAssertEqual(TimelineDigest.keyframeTimes(of: AnimatableValue<Double>.static(1)), [])
    }

    func testTracksOnlyIncludeAnimatedProperties() {
        let layer = Layer(
            id: "l", name: "L", sortKey: "a0",
            content: .shape(ShapeContent(geometry: .rect,
                                         cornerRadius: .animated([Track(keyframes: [
                                            Keyframe(t: 0, v: 8), Keyframe(t: 1, v: 40)])]))),
            transform: Transform(
                position: .animated([Track(keyframes: [Keyframe(t: 0, v: Vec2(0, 0)),
                                                       Keyframe(t: 0.5, v: Vec2(100, 0))])]),
                opacity: .static(1))
        )
        let tracks = TimelineDigest.tracks(for: layer)
        let paths = tracks.map(\.path)
        XCTAssertTrue(paths.contains("l/transform/position"))
        XCTAssertTrue(paths.contains("l/content/cornerRadius"))
        XCTAssertFalse(paths.contains("l/transform/opacity"), "static opacity is not a track")
        XCTAssertEqual(tracks.first(where: { $0.path == "l/content/cornerRadius" })?.times, [0, 1])
    }
}
