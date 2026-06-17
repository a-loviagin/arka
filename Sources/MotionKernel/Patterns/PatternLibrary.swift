import Foundation

/// The motion pattern library (ai-pipeline.md §4, platform-strategy.md §4 "taste is data"):
/// hand-tuned parametric templates that expand **deterministically** into ordinary keyframe
/// commands. Expansion is pure Swift, so it's testable with golden frames and improvable without
/// touching any model — and the same library powers a non-AI presets panel and (later) the AI
/// macro vocabulary (`ApplyPattern` / `Stagger`).
public enum MotionPattern: String, CaseIterable, Sendable {
    // Entrances (off-state → the layer's current rest transform).
    case fadeIn, popIn, scaleReveal
    case slideInUp, slideInDown, slideInLeft, slideInRight
    // Exits (rest → off-state).
    case fadeOut, popOut
    case slideOutUp, slideOutDown, slideOutLeft, slideOutRight
    // Emphasis (around rest).
    case pulse, bounce, shake

    public var displayName: String {
        switch self {
        case .fadeIn: "Fade In"; case .popIn: "Pop In"; case .scaleReveal: "Scale Reveal"
        case .slideInUp: "Slide Up In"; case .slideInDown: "Slide Down In"
        case .slideInLeft: "Slide Left In"; case .slideInRight: "Slide Right In"
        case .fadeOut: "Fade Out"; case .popOut: "Pop Out"
        case .slideOutUp: "Slide Up Out"; case .slideOutDown: "Slide Down Out"
        case .slideOutLeft: "Slide Left Out"; case .slideOutRight: "Slide Right Out"
        case .pulse: "Pulse"; case .bounce: "Bounce"; case .shake: "Shake"
        }
    }

    public enum Group: String, CaseIterable, Sendable { case entrance = "Entrance", exit = "Exit", emphasis = "Emphasis" }
    public var group: Group {
        switch self {
        case .fadeIn, .popIn, .scaleReveal, .slideInUp, .slideInDown, .slideInLeft, .slideInRight: .entrance
        case .fadeOut, .popOut, .slideOutUp, .slideOutDown, .slideOutLeft, .slideOutRight: .exit
        case .pulse, .bounce, .shake: .emphasis
        }
    }
}

/// Curated easing/spring per motion "character" (ai-pipeline.md §4).
public enum MotionCharacter: String, CaseIterable, Sendable {
    case gentle, snappy, bouncy, dramatic

    public var displayName: String { rawValue.capitalized }

    var spring: Spring {
        switch self {
        case .gentle: .gentle
        case .snappy: .snappy
        case .bouncy: .bouncy
        case .dramatic: Spring(stiffness: 220, damping: 16)
        }
    }
    /// Outgoing handle on the start keyframe of a bezier segment (ease-out feel).
    var easeOut: ControlPoint {
        switch self {
        case .gentle: ControlPoint(0.25, 0.1)
        case .snappy: ControlPoint(0.3, 0.0)
        case .bouncy: ControlPoint(0.34, 1.3) // slight overshoot
        case .dramatic: ControlPoint(0.7, 0.0)
        }
    }
    /// Incoming handle on the end keyframe.
    var easeIn: ControlPoint {
        switch self {
        case .gentle: ControlPoint(0.25, 1)
        case .snappy: ControlPoint(0.1, 1)
        case .bouncy: ControlPoint(0.6, 1)
        case .dramatic: ControlPoint(0.1, 1)
        }
    }
}

public struct PatternParams: Sendable {
    public var at: TimeInterval
    public var duration: TimeInterval
    public var character: MotionCharacter
    /// Travel distance for slides / amplitude for bounce/shake (points). Pattern picks a default.
    public var distance: Double?

    public init(at: TimeInterval = 0, duration: TimeInterval = 0.6,
                character: MotionCharacter = .snappy, distance: Double? = nil) {
        self.at = at; self.duration = duration; self.character = character; self.distance = distance
    }
}

public enum PatternLibrary {
    /// Expand a pattern on a layer into keyframe commands (deterministic). Reads the layer's rest
    /// transform (resolved at `at`) so entrances land on where the layer currently sits.
    public static func expand(_ pattern: MotionPattern, on layer: Layer, in comp: Composition,
                              params: PatternParams) -> [AnyCommand] {
        let id = layer.id
        let t0 = min(max(params.at, 0), comp.duration)
        let end = min(t0 + max(params.duration, 0.05), comp.duration)
        let ch = params.character
        let pos = layer.transform.position.resolve(at: t0)
        let scl = layer.transform.scale.resolve(at: t0)
        let op = max(layer.transform.opacity.resolve(at: t0), 0.001)
        let d = params.distance ?? 200

        switch pattern {
        case .fadeIn: return fade(id, t0, end, from: 0, to: op, ch)
        case .fadeOut: return fade(id, t0, end, from: op, to: 0, ch)

        case .popIn:
            return scaleSpring(id, t0, end, from: .zero, to: scl, ch)
                 + fade(id, t0, lerpT(t0, end, 0.6), from: 0, to: op, ch)
        case .popOut:
            return scaleSpring(id, t0, end, from: scl, to: .zero, ch)
                 + fade(id, lerpT(t0, end, 0.4), end, from: op, to: 0, ch)
        case .scaleReveal:
            return scaleBezier(id, t0, end, from: .zero, to: scl, ch) + fade(id, t0, lerpT(t0, end, 0.5), from: 0, to: op, ch)

        case .slideInUp: return slideIn(id, t0, end, rest: pos, offset: Vec2(0, d), op: op, ch)
        case .slideInDown: return slideIn(id, t0, end, rest: pos, offset: Vec2(0, -d), op: op, ch)
        case .slideInLeft: return slideIn(id, t0, end, rest: pos, offset: Vec2(d, 0), op: op, ch)
        case .slideInRight: return slideIn(id, t0, end, rest: pos, offset: Vec2(-d, 0), op: op, ch)
        case .slideOutUp: return slideOut(id, t0, end, rest: pos, offset: Vec2(0, -d), op: op, ch)
        case .slideOutDown: return slideOut(id, t0, end, rest: pos, offset: Vec2(0, d), op: op, ch)
        case .slideOutLeft: return slideOut(id, t0, end, rest: pos, offset: Vec2(-d, 0), op: op, ch)
        case .slideOutRight: return slideOut(id, t0, end, rest: pos, offset: Vec2(d, 0), op: op, ch)

        case .pulse:
            let mid = lerpT(t0, end, 0.5)
            return [scaleKey(id, t0, scl, .bezier, easeOut: ch.easeOut),
                    scaleKey(id, mid, Vec2(scl.x * 1.12, scl.y * 1.12), .bezier, easeOut: ch.easeOut, easeIn: ch.easeIn),
                    scaleKey(id, end, scl, .bezier, easeIn: ch.easeIn)]
        case .bounce:
            let mid = lerpT(t0, end, 0.35)
            let amp = params.distance ?? 80
            return [posKey(id, t0, pos, .bezier, easeOut: ch.easeOut),
                    posKey(id, mid, Vec2(pos.x, pos.y - amp), .spring(ch.spring), easeIn: ch.easeIn),
                    posKey(id, end, pos, .bezier, easeIn: ch.easeIn)]
        case .shake:
            let amp = params.distance ?? 24
            let steps = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
            let offsets = [0.0, 1.0, -0.8, 0.5, -0.3, 0.0]
            return zip(steps, offsets).map { f, o in
                posKey(id, lerpT(t0, end, f), Vec2(pos.x + amp * o, pos.y), .linear)
            }
        }
    }

    /// Expand a pattern across several layers with a staggered start (ai-pipeline.md §4 `Stagger`).
    public static func stagger(_ pattern: MotionPattern, on layers: [Layer], in comp: Composition,
                               params: PatternParams, gap: TimeInterval) -> [AnyCommand] {
        layers.enumerated().flatMap { i, layer in
            var p = params; p.at = params.at + Double(i) * gap
            return expand(pattern, on: layer, in: comp, params: p)
        }
    }

    // MARK: Builders

    private static func lerpT(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }

    private static func fade(_ id: EntityID, _ t0: Double, _ end: Double,
                             from: Double, to: Double, _ ch: MotionCharacter) -> [AnyCommand] {
        [opKey(id, t0, from, .bezier, easeOut: ch.easeOut), opKey(id, end, to, .bezier, easeIn: ch.easeIn)]
    }
    private static func scaleSpring(_ id: EntityID, _ t0: Double, _ end: Double,
                                    from: Vec2, to: Vec2, _ ch: MotionCharacter) -> [AnyCommand] {
        [scaleKey(id, t0, from, .spring(ch.spring)), scaleKey(id, end, to, .bezier, easeIn: ch.easeIn)]
    }
    private static func scaleBezier(_ id: EntityID, _ t0: Double, _ end: Double,
                                    from: Vec2, to: Vec2, _ ch: MotionCharacter) -> [AnyCommand] {
        [scaleKey(id, t0, from, .bezier, easeOut: ch.easeOut), scaleKey(id, end, to, .bezier, easeIn: ch.easeIn)]
    }
    private static func slideIn(_ id: EntityID, _ t0: Double, _ end: Double, rest: Vec2, offset: Vec2,
                                op: Double, _ ch: MotionCharacter) -> [AnyCommand] {
        [posKey(id, t0, rest + offset, .bezier, easeOut: ch.easeOut), posKey(id, end, rest, .bezier, easeIn: ch.easeIn)]
            + fade(id, t0, lerpT(t0, end, 0.6), from: 0, to: op, ch)
    }
    private static func slideOut(_ id: EntityID, _ t0: Double, _ end: Double, rest: Vec2, offset: Vec2,
                                 op: Double, _ ch: MotionCharacter) -> [AnyCommand] {
        [posKey(id, t0, rest, .bezier, easeOut: ch.easeOut), posKey(id, end, rest + offset, .bezier, easeIn: ch.easeIn)]
            + fade(id, lerpT(t0, end, 0.4), end, from: op, to: 0, ch)
    }

    private static func opKey(_ id: EntityID, _ t: Double, _ v: Double, _ interp: Interpolation,
                              easeOut: ControlPoint? = nil, easeIn: ControlPoint? = nil) -> AnyCommand {
        .setKeyframe(path: "\(id)/transform/opacity",
                     keyframe: AnyKeyframe(t: t, v: .scalar(v), interp: interp, easeOut: easeOut, easeIn: easeIn))
    }
    private static func posKey(_ id: EntityID, _ t: Double, _ v: Vec2, _ interp: Interpolation,
                              easeOut: ControlPoint? = nil, easeIn: ControlPoint? = nil) -> AnyCommand {
        .setKeyframe(path: "\(id)/transform/position",
                     keyframe: AnyKeyframe(t: t, v: .vec2(v), interp: interp, easeOut: easeOut, easeIn: easeIn))
    }
    private static func scaleKey(_ id: EntityID, _ t: Double, _ v: Vec2, _ interp: Interpolation,
                                easeOut: ControlPoint? = nil, easeIn: ControlPoint? = nil) -> AnyCommand {
        .setKeyframe(path: "\(id)/transform/scale",
                     keyframe: AnyKeyframe(t: t, v: .vec2(v), interp: interp, easeOut: easeOut, easeIn: easeIn))
    }
}
