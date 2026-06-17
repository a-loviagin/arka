import Foundation

public extension EvaluatedLayer {
    /// Axis-aligned bounding box in comp space (the world-transformed corners of [0, size]).
    /// Used for canvas snapping and marquee selection.
    var boundingBox: (min: Vec2, max: Vec2) {
        let corners = [Vec2(0, 0), Vec2(size.x, 0), Vec2(size.x, size.y), Vec2(0, size.y)]
            .map { world.apply(to: $0) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return (Vec2(xs.min() ?? 0, ys.min() ?? 0), Vec2(xs.max() ?? 0, ys.max() ?? 0))
    }
}

/// A snap guide line that fired during a drag (editor-ui.md §2).
public struct SnapGuide: Equatable, Sendable {
    public enum Axis: Sendable { case vertical, horizontal }
    public let axis: Axis
    public let position: Double // comp coordinate (x for vertical, y for horizontal)
    public init(axis: Axis, position: Double) { self.axis = axis; self.position = position }
}

public struct SnapOutcome: Sendable {
    public let position: Vec2
    public let guides: [SnapGuide]
}

/// Pure snapping for canvas drags (editor-ui.md §2: snap the *proposed* value before issuing the
/// command, so the document only ever sees snapped positions). The moving box's snap features
/// (min/center/max per axis) translate rigidly with the position, so they're given as signed
/// offsets from `proposed`. Each axis snaps to the nearest (feature, candidate) pair within
/// `threshold` (comp units; the caller converts the screen-space snap radius via the viewport scale).
public enum CanvasSnapper {
    public static func snap(position proposed: Vec2,
                            boxOffsetsX: [Double], boxOffsetsY: [Double],
                            candidatesX: [Double], candidatesY: [Double],
                            threshold: Double) -> SnapOutcome {
        var result = proposed
        var guides: [SnapGuide] = []

        if let (correction, guide) = bestSnap(base: proposed.x, offsets: boxOffsetsX,
                                              candidates: candidatesX, threshold: threshold) {
            result.x += correction
            guides.append(SnapGuide(axis: .vertical, position: guide))
        }
        if let (correction, guide) = bestSnap(base: proposed.y, offsets: boxOffsetsY,
                                              candidates: candidatesY, threshold: threshold) {
            result.y += correction
            guides.append(SnapGuide(axis: .horizontal, position: guide))
        }
        return SnapOutcome(position: result, guides: guides)
    }

    /// Nearest (feature, candidate) within threshold → (correction to apply to base, guide coord).
    private static func bestSnap(base: Double, offsets: [Double], candidates: [Double],
                                 threshold: Double) -> (correction: Double, guide: Double)? {
        var best: (correction: Double, guide: Double)?
        var bestDist = threshold
        for offset in offsets {
            let feature = base + offset
            for candidate in candidates {
                let dist = abs(feature - candidate)
                if dist <= bestDist {
                    bestDist = dist
                    best = (candidate - feature, candidate)
                }
            }
        }
        return best
    }
}
