import Foundation

/// One keyframe on a track. `interp` describes how this keyframe reaches the **next** one.
///
/// Wire form is flat (motion-document-schema.md §4), e.g.
/// `{ "t": 0.0, "v": [200, 540], "easeOut": [0.33, 0.0], "spatialOut": [60, 0] }`.
/// Omitted fields take defaults; `interp` defaults to `.bezier`.
public struct Keyframe<V: Interpolatable>: Sendable, Equatable {
    /// Time in seconds within the composition.
    public var t: TimeInterval
    /// Value at this time (type implied by the property).
    public var v: V
    /// How to reach the next keyframe.
    public var interp: Interpolation
    /// Outgoing temporal handle (this keyframe → next).
    public var easeOut: ControlPoint?
    /// Incoming temporal handle (prev keyframe → this). Stored on this keyframe per schema.
    public var easeIn: ControlPoint?
    /// Outgoing spatial tangent (value-space) for curved motion paths.
    public var spatialOut: V.Tangent?
    /// Incoming spatial tangent.
    public var spatialIn: V.Tangent?

    public init(t: TimeInterval, v: V,
                interp: Interpolation = .bezier,
                easeOut: ControlPoint? = nil, easeIn: ControlPoint? = nil,
                spatialOut: V.Tangent? = nil, spatialIn: V.Tangent? = nil) {
        self.t = t
        self.v = v
        self.interp = interp
        self.easeOut = easeOut
        self.easeIn = easeIn
        self.spatialOut = spatialOut
        self.spatialIn = spatialIn
    }
}

extension Keyframe: Codable where V: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, v, easeOut, easeIn, spatialOut, spatialIn
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(TimeInterval.self, forKey: .t)
        v = try c.decode(V.self, forKey: .v)
        interp = try Interpolation(from: decoder) // reads `interp` + optional `spring`
        easeOut = try c.decodeIfPresent(ControlPoint.self, forKey: .easeOut)
        easeIn = try c.decodeIfPresent(ControlPoint.self, forKey: .easeIn)
        spatialOut = try c.decodeIfPresent(V.Tangent.self, forKey: .spatialOut)
        spatialIn = try c.decodeIfPresent(V.Tangent.self, forKey: .spatialIn)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(v, forKey: .v)
        try interp.encode(to: encoder) // writes `interp` (+ `spring`)
        try c.encodeIfPresent(easeOut, forKey: .easeOut)
        try c.encodeIfPresent(easeIn, forKey: .easeIn)
        try c.encodeIfPresent(spatialOut, forKey: .spatialOut)
        try c.encodeIfPresent(spatialIn, forKey: .spatialIn)
    }
}
