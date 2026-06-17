import Foundation

/// One animated property of a layer, for the timeline dope-sheet: its command `path`, a display
/// `label`, and the sorted union of keyframe times across its tracks (editor-ui.md §3).
public struct PropertyTrack: Sendable, Equatable {
    public let path: String
    public let label: String
    public let times: [TimeInterval]
}

public enum TimelineDigest {
    /// Sorted, de-duplicated keyframe times of an animatable value (empty if static).
    public static func keyframeTimes<V>(of value: AnimatableValue<V>) -> [TimeInterval] {
        guard case .animated(let tracks) = value else { return [] }
        var times = Set<TimeInterval>()
        for track in tracks { for kf in track.keyframes { times.insert(kf.t) } }
        return times.sorted()
    }

    /// The animated property tracks of a layer, in a stable display order. Only properties that
    /// actually carry keyframes appear.
    public static func tracks(for layer: Layer) -> [PropertyTrack] {
        var out: [PropertyTrack] = []
        let id = layer.id
        func add(_ suffix: String, _ label: String, _ times: [TimeInterval]) {
            if !times.isEmpty { out.append(PropertyTrack(path: "\(id)/\(suffix)", label: label, times: times)) }
        }

        let tr = layer.transform
        add("transform/position", "Position", keyframeTimes(of: tr.position))
        add("transform/scale", "Scale", keyframeTimes(of: tr.scale))
        add("transform/rotation", "Rotation", keyframeTimes(of: tr.rotation))
        add("transform/anchor", "Anchor", keyframeTimes(of: tr.anchor))
        add("transform/opacity", "Opacity", keyframeTimes(of: tr.opacity))
        if let skew = tr.skew { add("transform/skew", "Skew", keyframeTimes(of: skew)) }

        switch layer.content {
        case .shape(let s):
            add("content/size", "Size", keyframeTimes(of: s.size))
            if let fill = s.fillColor { add("content/fillColor", "Fill", keyframeTimes(of: fill)) }
            if let stroke = s.strokeColor { add("content/strokeColor", "Stroke", keyframeTimes(of: stroke)) }
            if let sw = s.strokeWidth { add("content/strokeWidth", "Stroke Width", keyframeTimes(of: sw)) }
            if let cr = s.cornerRadius { add("content/cornerRadius", "Corner Radius", keyframeTimes(of: cr)) }
        case .text(let t):
            add("content/fontSize", "Font Size", keyframeTimes(of: t.fontSize))
            if let tracking = t.tracking { add("content/tracking", "Tracking", keyframeTimes(of: tracking)) }
            add("content/fillColor", "Fill", keyframeTimes(of: t.fillColor))
        default:
            break
        }
        return out
    }
}
