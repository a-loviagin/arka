#if os(macOS)
import Foundation
import QuartzCore
import Observation

/// The playhead clock (render-engine.md §5). Time comes from a media clock anchored at play-start,
/// not wall-accumulation — so pause/scrub/loop are anchor manipulations and dropped frames never
/// accumulate drift. Designed as "ask a clock object," so audio can become the master later.
@MainActor
@Observable
final class PlaybackController {
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var loops = true
    var duration: TimeInterval

    private var anchorHostTime: TimeInterval = 0
    private var anchorPlayhead: TimeInterval = 0

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        reanchor()
    }

    func pause() {
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to t: TimeInterval) {
        currentTime = min(max(t, 0), duration)
        if isPlaying { reanchor() }
    }

    /// Advance the playhead from the media clock. Called once per display tick.
    func tick() {
        guard isPlaying else { return }
        let elapsed = CACurrentMediaTime() - anchorHostTime
        var t = anchorPlayhead + elapsed
        if t >= duration {
            if loops, duration > 0 {
                t = t.truncatingRemainder(dividingBy: duration)
                anchorHostTime = CACurrentMediaTime()
                anchorPlayhead = t
            } else {
                t = duration
                isPlaying = false
            }
        }
        currentTime = t
    }

    private func reanchor() {
        anchorHostTime = CACurrentMediaTime()
        anchorPlayhead = currentTime
    }
}
#endif
