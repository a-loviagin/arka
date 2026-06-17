import Foundation

/// Editing helpers on `AnimatableValue`. Commands target the **combined** track (component nil);
/// the editor's separated-dimension tracks are created explicitly. Times match within `epsilon`
/// so frame-snapped edits land on existing keyframes rather than spawning near-duplicates.
extension AnimatableValue {
    static var timeEpsilon: Double { 1e-6 }

    /// The combined (whole-value) track, creating an empty one if the value is currently static.
    private mutating func combinedTrackIndex() -> Int {
        switch self {
        case .static:
            self = .animated([Track(component: nil, keyframes: [])])
            return 0
        case .animated(var tracks):
            if let idx = tracks.firstIndex(where: { $0.component == nil }) {
                return idx
            }
            tracks.append(Track(component: nil, keyframes: []))
            self = .animated(tracks)
            return tracks.count - 1
        }
    }

    private mutating func mutateTracks(_ body: (inout [Track<V>]) -> Void) {
        if case .animated(var tracks) = self {
            body(&tracks)
            self = .animated(tracks)
        }
    }

    /// Insert a keyframe, or replace the existing one at the same time.
    mutating func upsertKeyframe(_ kf: Keyframe<V>) {
        let idx = combinedTrackIndex()
        mutateTracks { tracks in
            var t = tracks[idx]
            if let existing = t.keyframes.firstIndex(where: { abs($0.t - kf.t) < Self.timeEpsilon }) {
                t.keyframes[existing] = kf
            } else {
                t.keyframes.append(kf)
            }
            t.normalize()
            tracks[idx] = t
        }
    }

    /// Remove the keyframe at `t` from the combined track. If that empties the track and no other
    /// tracks carry keyframes, collapse back to the last value as static.
    mutating func removeKeyframe(at t: TimeInterval) {
        mutateTracks { tracks in
            for i in tracks.indices where tracks[i].component == nil {
                tracks[i].keyframes.removeAll { abs($0.t - t) < Self.timeEpsilon }
            }
        }
        if case .animated(let tracks) = self,
           tracks.allSatisfy({ $0.keyframes.isEmpty }) {
            // Nothing left to animate; leave an empty animated value for the caller to decide.
            // (We avoid guessing a static value here — the command layer handles collapse policy.)
        }
    }

    /// Set easing on the segment that starts at `t`: this keyframe's `easeOut` and the next
    /// keyframe's `easeIn` (schema stores incoming handles on the next keyframe).
    mutating func setSegmentEasing(at t: TimeInterval, easeIn: ControlPoint?, easeOut: ControlPoint?) {
        mutateTracks { tracks in
            for i in tracks.indices where tracks[i].component == nil {
                guard let kfIdx = tracks[i].keyframes.firstIndex(where: { abs($0.t - t) < Self.timeEpsilon })
                else { continue }
                tracks[i].keyframes[kfIdx].easeOut = easeOut
                if kfIdx + 1 < tracks[i].keyframes.count {
                    tracks[i].keyframes[kfIdx + 1].easeIn = easeIn
                }
            }
        }
    }

    /// Set the interpolation of the keyframe at `t` (the easing/spring of the segment it starts).
    mutating func setInterp(at t: TimeInterval, _ interp: Interpolation) {
        mutateTracks { tracks in
            for i in tracks.indices where tracks[i].component == nil {
                if let kfIdx = tracks[i].keyframes.firstIndex(where: { abs($0.t - t) < Self.timeEpsilon }) {
                    tracks[i].keyframes[kfIdx].interp = interp
                }
            }
        }
    }

    /// Retime a keyframe from `oldT` to `newT`.
    mutating func moveKeyframe(from oldT: TimeInterval, to newT: TimeInterval) {
        mutateTracks { tracks in
            for i in tracks.indices {
                guard let kfIdx = tracks[i].keyframes.firstIndex(where: { abs($0.t - oldT) < Self.timeEpsilon })
                else { continue }
                tracks[i].keyframes[kfIdx].t = newT
                tracks[i].normalize()
            }
        }
    }

    /// Whether any keyframe exists at `t`.
    func hasKeyframe(at t: TimeInterval) -> Bool {
        if case .animated(let tracks) = self {
            return tracks.contains { $0.keyframes.contains { abs($0.t - t) < Self.timeEpsilon } }
        }
        return false
    }
}
