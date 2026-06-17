import Foundation

/// A parsed property address (properties-and-commands.md §2): one string addresses everything
/// because the schema is uniform. Grammar:
///   `<layerId>/transform/<prop>`
///   `<layerId>/content/<prop>`
///   `<layerId>/effects/<effectId>/params/<paramName>`
public struct PropertyPath: Sendable, Equatable {
    public let layerId: EntityID
    public let raw: String
    public let tail: [String]

    public init(_ raw: String) throws {
        self.raw = raw
        let parts = raw.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw CommandError.badPath(raw) }
        self.layerId = EntityID(parts[0])
        self.tail = Array(parts.dropFirst())
    }
}

/// Type-erased typed animatable value extracted from a layer, with mutation operations that coerce
/// the type-erased command payloads. Read it from a layer, mutate, write it back.
public enum AnimatableSlot: Sendable {
    case scalar(AnimatableValue<Double>)
    case vec2(AnimatableValue<Vec2>)
    case color(AnimatableValue<ColorValue>)

    public mutating func setStatic(_ v: AnyValue) throws {
        switch self {
        case .scalar: self = .scalar(.static(try v.asScalar()))
        case .vec2: self = .vec2(.static(try v.asVec2()))
        case .color: self = .color(.static(try v.asColor()))
        }
    }

    public mutating func upsertKeyframe(_ kf: AnyKeyframe) throws {
        switch self {
        case .scalar(var av):
            av.upsertKeyframe(Keyframe(t: kf.t, v: try kf.v.asScalar(), interp: kf.interp,
                                       easeOut: kf.easeOut, easeIn: kf.easeIn))
            self = .scalar(av)
        case .vec2(var av):
            av.upsertKeyframe(Keyframe(t: kf.t, v: try kf.v.asVec2(), interp: kf.interp,
                                       easeOut: kf.easeOut, easeIn: kf.easeIn,
                                       spatialOut: kf.spatialOut, spatialIn: kf.spatialIn))
            self = .vec2(av)
        case .color(var av):
            av.upsertKeyframe(Keyframe(t: kf.t, v: try kf.v.asColor(), interp: kf.interp,
                                       easeOut: kf.easeOut, easeIn: kf.easeIn))
            self = .color(av)
        }
    }

    public mutating func removeKeyframe(at t: TimeInterval) {
        switch self {
        case .scalar(var av): av.removeKeyframe(at: t); self = .scalar(av)
        case .vec2(var av): av.removeKeyframe(at: t); self = .vec2(av)
        case .color(var av): av.removeKeyframe(at: t); self = .color(av)
        }
    }

    public mutating func setSegmentEasing(at t: TimeInterval, easeIn: ControlPoint?, easeOut: ControlPoint?) {
        switch self {
        case .scalar(var av): av.setSegmentEasing(at: t, easeIn: easeIn, easeOut: easeOut); self = .scalar(av)
        case .vec2(var av): av.setSegmentEasing(at: t, easeIn: easeIn, easeOut: easeOut); self = .vec2(av)
        case .color(var av): av.setSegmentEasing(at: t, easeIn: easeIn, easeOut: easeOut); self = .color(av)
        }
    }

    public mutating func setInterp(at t: TimeInterval, _ interp: Interpolation) {
        switch self {
        case .scalar(var av): av.setInterp(at: t, interp); self = .scalar(av)
        case .vec2(var av): av.setInterp(at: t, interp); self = .vec2(av)
        case .color(var av): av.setInterp(at: t, interp); self = .color(av)
        }
    }

    public mutating func moveKeyframe(from oldT: TimeInterval, to newT: TimeInterval) {
        switch self {
        case .scalar(var av): av.moveKeyframe(from: oldT, to: newT); self = .scalar(av)
        case .vec2(var av): av.moveKeyframe(from: oldT, to: newT); self = .vec2(av)
        case .color(var av): av.moveKeyframe(from: oldT, to: newT); self = .color(av)
        }
    }

    public func hasKeyframe(at t: TimeInterval) -> Bool {
        switch self {
        case .scalar(let av): av.hasKeyframe(at: t)
        case .vec2(let av): av.hasKeyframe(at: t)
        case .color(let av): av.hasKeyframe(at: t)
        }
    }
}

// MARK: - Routing a path to a slot on a layer

extension Layer {
    /// Read the animatable slot addressed by `tail` (path components after the layer id).
    func readSlot(_ tail: [String], rawPath: String) throws -> AnimatableSlot {
        switch tail.first {
        case "transform":
            guard tail.count == 2 else { throw CommandError.badPath(rawPath) }
            switch tail[1] {
            case "position": return .vec2(transform.position)
            case "scale": return .vec2(transform.scale)
            case "anchor": return .vec2(transform.anchor)
            case "rotation": return .scalar(transform.rotation)
            case "opacity": return .scalar(transform.opacity)
            case "skew": return .scalar(transform.skew ?? .static(0))
            case "skewAxis": return .scalar(transform.skewAxis ?? .static(0))
            default: throw CommandError.badPath(rawPath)
            }
        case "content":
            guard tail.count == 2 else { throw CommandError.badPath(rawPath) }
            return try readContentSlot(tail[1], rawPath: rawPath)
        case "effects":
            // effects/<id>/params/<name>
            guard tail.count == 4, tail[2] == "params" else { throw CommandError.badPath(rawPath) }
            let effectId = EntityID(tail[1])
            guard let fx = effects.first(where: { $0.id == effectId }) else {
                throw CommandError.effectNotFound(effectId)
            }
            guard let param = fx.params[tail[3]] else { throw CommandError.badPath(rawPath) }
            switch param {
            case .scalar(let v): return .scalar(v)
            case .vec2(let v): return .vec2(v)
            case .color(let v): return .color(v)
            }
        default:
            throw CommandError.badPath(rawPath)
        }
    }

    private func readContentSlot(_ prop: String, rawPath: String) throws -> AnimatableSlot {
        switch content {
        case .shape(let s):
            switch prop {
            case "size": return .vec2(s.size)
            case "fillColor": return .color(s.fillColor ?? .static(.black))
            case "strokeColor": return .color(s.strokeColor ?? .static(.clear))
            case "strokeWidth": return .scalar(s.strokeWidth ?? .static(0))
            case "cornerRadius": return .scalar(s.cornerRadius ?? .static(0))
            default: throw CommandError.badPath(rawPath)
            }
        case .text(let t):
            switch prop {
            case "fontSize": return .scalar(t.fontSize)
            case "tracking": return .scalar(t.tracking ?? .static(0))
            case "fillColor": return .color(t.fillColor)
            default: throw CommandError.badPath(rawPath)
            }
        default:
            throw CommandError.badPath(rawPath)
        }
    }

    /// Write a mutated slot back into the layer at the same address.
    mutating func writeSlot(_ slot: AnimatableSlot, tail: [String], rawPath: String) throws {
        switch tail.first {
        case "transform":
            guard tail.count == 2 else { throw CommandError.badPath(rawPath) }
            switch tail[1] {
            case "position": transform.position = try slot.vec2Value(rawPath)
            case "scale": transform.scale = try slot.vec2Value(rawPath)
            case "anchor": transform.anchor = try slot.vec2Value(rawPath)
            case "rotation": transform.rotation = try slot.scalarValue(rawPath)
            case "opacity": transform.opacity = try slot.scalarValue(rawPath)
            case "skew": transform.skew = try slot.scalarValue(rawPath)
            case "skewAxis": transform.skewAxis = try slot.scalarValue(rawPath)
            default: throw CommandError.badPath(rawPath)
            }
        case "content":
            guard tail.count == 2 else { throw CommandError.badPath(rawPath) }
            try writeContentSlot(slot, prop: tail[1], rawPath: rawPath)
        case "effects":
            guard tail.count == 4, tail[2] == "params" else { throw CommandError.badPath(rawPath) }
            let effectId = EntityID(tail[1])
            guard let idx = effects.firstIndex(where: { $0.id == effectId }) else {
                throw CommandError.effectNotFound(effectId)
            }
            switch slot {
            case .scalar(let v): effects[idx].params[tail[3]] = .scalar(v)
            case .vec2(let v): effects[idx].params[tail[3]] = .vec2(v)
            case .color(let v): effects[idx].params[tail[3]] = .color(v)
            }
        default:
            throw CommandError.badPath(rawPath)
        }
    }

    private mutating func writeContentSlot(_ slot: AnimatableSlot, prop: String, rawPath: String) throws {
        switch content {
        case .shape(var s):
            switch prop {
            case "size": s.size = try slot.vec2Value(rawPath)
            case "fillColor": s.fillColor = try slot.colorValue(rawPath)
            case "strokeColor": s.strokeColor = try slot.colorValue(rawPath)
            case "strokeWidth": s.strokeWidth = try slot.scalarValue(rawPath)
            case "cornerRadius": s.cornerRadius = try slot.scalarValue(rawPath)
            default: throw CommandError.badPath(rawPath)
            }
            content = .shape(s)
        case .text(var t):
            switch prop {
            case "fontSize": t.fontSize = try slot.scalarValue(rawPath)
            case "tracking": t.tracking = try slot.scalarValue(rawPath)
            case "fillColor": t.fillColor = try slot.colorValue(rawPath)
            default: throw CommandError.badPath(rawPath)
            }
            content = .text(t)
        default:
            throw CommandError.badPath(rawPath)
        }
    }
}

private extension AnimatableSlot {
    func scalarValue(_ path: String) throws -> AnimatableValue<Double> {
        guard case .scalar(let v) = self else { throw CommandError.typeMismatch(expected: "scalar", got: "other") }
        return v
    }
    func vec2Value(_ path: String) throws -> AnimatableValue<Vec2> {
        guard case .vec2(let v) = self else { throw CommandError.typeMismatch(expected: "vec2", got: "other") }
        return v
    }
    func colorValue(_ path: String) throws -> AnimatableValue<ColorValue> {
        guard case .color(let v) = self else { throw CommandError.typeMismatch(expected: "color", got: "other") }
        return v
    }
}
