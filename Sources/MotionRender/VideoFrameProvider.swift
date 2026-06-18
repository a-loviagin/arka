#if os(macOS)
import Foundation
import AVFoundation
import CoreGraphics
import Metal
import MotionKernel

/// Decodes video frames at an exact composition time into Metal textures (render-engine.md §2,5).
/// Frame-accurate and deterministic — `AVAssetImageGenerator` with zero tolerance gives the same
/// frame for the same time, so preview, golden frames, and export agree. Frames are cached per
/// (asset, frame index) so scrubbing and playback don't re-decode.
///
/// macOS-only (AVFoundation) and lives behind the RenderTree boundary, like the rest of MotionRender.
public final class VideoFrameProvider {
    private let device: MTLDevice
    private var generators: [EntityID: AVAssetImageGenerator] = [:]
    private var durations: [EntityID: Double] = [:]
    private var frames: [FrameKey: MTLTexture] = [:]

    private struct FrameKey: Hashable { var asset: EntityID; var frame: Int }

    /// Frame quantization for caching/determinism. 60 buckets/sec ≈ frame granularity.
    private let timeScale: CMTimeScale = 600

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Texture for a video layer at composition time `t`. `assetURL` resolves the asset's bytes
    /// (absolute, or `baseURL/asset.path`). Honors `trimStart`, `speed`, and `trimEnd`; clamps to the
    /// asset's playable range. Returns nil if the asset can't be opened or the frame can't be decoded.
    public func texture(for video: VideoContent, asset: Asset, assetURL: URL,
                        at t: TimeInterval) -> MTLTexture? {
        guard let generator = generator(for: asset, url: assetURL) else { return nil }
        let duration = durations[asset.id] ?? 0

        // Map comp time → asset time, then clamp to the trimmed, playable range.
        var assetTime = video.trimStart + max(t, 0) * max(video.speed, 0)
        let upper = min(video.trimEnd ?? duration, duration)
        assetTime = Swift.min(Swift.max(assetTime, 0), Swift.max(upper, 0))

        let frameIndex = Int((assetTime * Double(timeScale)).rounded())
        let key = FrameKey(asset: asset.id, frame: frameIndex)
        if let cached = frames[key] { return cached }

        let cm = CMTime(value: CMTimeValue(frameIndex), timescale: timeScale)
        guard let cg = try? generator.copyCGImage(at: cm, actualTime: nil),
              let texture = TextureCache.makeTexture(from: cg, device: device) else { return nil }
        frames[key] = texture
        return texture
    }

    /// The intrinsic pixel size of a video asset (for the quad extents when `asset.pixelSize` is nil).
    public func pixelSize(for asset: Asset, assetURL: URL) -> Vec2? {
        guard generator(for: asset, url: assetURL) != nil else { return nil }
        // Image generator's first frame carries the (transform-applied) dimensions.
        guard let g = generators[asset.id],
              let cg = try? g.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return Vec2(Double(cg.width), Double(cg.height))
    }

    private func generator(for asset: Asset, url: URL) -> AVAssetImageGenerator? {
        if let g = generators[asset.id] { return g }
        let avAsset = AVURLAsset(url: url)
        let g = AVAssetImageGenerator(asset: avAsset)
        g.appliesPreferredTrackTransform = true          // honor rotation metadata
        g.requestedTimeToleranceBefore = .zero           // frame-accurate, deterministic
        g.requestedTimeToleranceAfter = .zero
        generators[asset.id] = g
        durations[asset.id] = CMTimeGetSeconds(avAsset.duration)
        return g
    }
}
#endif
