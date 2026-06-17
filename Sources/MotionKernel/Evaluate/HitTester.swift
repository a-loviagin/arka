import Foundation

/// CPU hit-testing against the evaluated scene (editor-ui.md §2). Pure and deterministic: evaluate
/// the comp at the playhead, walk top-down in z-order, transform the comp-space point into each
/// layer's local space via the inverse world matrix, and test against local bounds. Exact enough
/// for v1 (axis-aligned bounds in local space — correct under rotation/scale via the inverse).
public enum HitTester {
    /// Topmost active layer whose bounds contain `compPoint`, or nil. Text/group/null layers have
    /// no intrinsic size yet and are skipped.
    public static func topLayer(in document: MotionDocument, compId: EntityID,
                                at t: TimeInterval, compPoint: Vec2) -> EntityID? {
        let scene = SceneEvaluator(document: document)
        let evaluated = scene.evaluate(compId: compId, at: t)
        // evaluated is bottom→top; reverse for topmost-first.
        for ev in evaluated.reversed() where ev.active && ev.opacity > 0.01 {
            guard ev.size.x > 0, ev.size.y > 0, let inverse = ev.world.inverted() else { continue }
            let local = inverse.apply(to: compPoint)
            if local.x >= 0, local.x <= ev.size.x, local.y >= 0, local.y <= ev.size.y {
                return ev.layerId
            }
        }
        return nil
    }
}
