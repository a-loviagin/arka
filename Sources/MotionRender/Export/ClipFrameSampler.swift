#if os(macOS)
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Samples evenly-spaced frames from a reference clip (mov/mp4/gif/…) as JPEG bytes, for the vision
/// taste analyzer (ai-pipeline.md §3). Downscaled (vision doesn't need full res) and frame-accurate
/// via `AVAssetImageGenerator`. Lives in the render layer (AVFoundation/ImageIO); the analyzer in
/// MotionAI consumes the resulting bytes, staying Foundation-only.
public enum ClipFrameSampler {
    public enum SamplerError: Error { case noFrames, encode }

    public struct Sampled: Sendable {
        public let frames: [Data]   // JPEG
        public let fps: Double      // effective sampling rate (frames spread across the clip)
    }

    public static func sample(url: URL, count: Int = 12, maxDimension: Int = 512,
                              quality: Double = 0.7) async throws -> Sampled {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let n = max(count, 1)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: maxDimension, height: maxDimension)

        var frames: [Data] = []
        for i in 0..<n {
            let frac = n > 1 ? Double(i) / Double(n - 1) : 0
            let t = CMTime(seconds: max(duration, 0) * frac, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image, let data = jpeg(cg, quality: quality) else { continue }
            frames.append(data)
        }
        guard !frames.isEmpty else { throw SamplerError.noFrames }
        // Effective fps across the clip (so the analyzer can talk in real seconds).
        let fps = duration > 0 ? Double(frames.count) / duration : Double(frames.count)
        return Sampled(frames: frames, fps: fps)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
#endif
