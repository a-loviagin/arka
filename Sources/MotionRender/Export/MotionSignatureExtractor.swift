#if os(macOS)
import Foundation
import simd
import MotionKernel

/// Extracts a deterministic `MotionSignature` from frames (ai-pipeline.md §3). Activity is the
/// normalized mean-absolute inter-frame difference; onsets are rising threshold crossings; the
/// palette reuses the OKLab quantizer. No model — this is the offline, reproducible half of clip
/// analysis and the render-compare verifier.
public enum MotionSignatureExtractor {
    public static func signature(frames: [PixelImage], fps: Double,
                                 onsetThreshold: Double = 0.04) -> MotionSignature {
        guard frames.count > 1 else {
            return MotionSignature(fps: fps, activity: [], palette: palette(frames), onsets: [])
        }
        var activity: [Double] = []
        activity.reserveCapacity(frames.count - 1)
        for i in 0..<(frames.count - 1) {
            activity.append(frames[i].meanAbsoluteDifference(to: frames[i + 1]) / 255.0)
        }
        // Rising threshold crossings → onset times (at the *later* frame of the pair).
        var onsets: [TimeInterval] = []
        for i in activity.indices {
            let prev = i > 0 ? activity[i - 1] : 0
            if prev < onsetThreshold && activity[i] >= onsetThreshold {
                onsets.append(Double(i + 1) / max(fps, 1))
            }
        }
        return MotionSignature(fps: fps, activity: activity, palette: palette(frames), onsets: onsets)
    }

    /// Render-compare verifier: render `frameCount` frames of a document's comp and take its
    /// signature, so a synthesized candidate can be scored against a reference clip's signature.
    public static func signature(of document: MotionDocument, compId: EntityID, renderer: MetalRenderer,
                                 textures: (any TextureProvider)? = nil, width: Int, height: Int,
                                 frameCount: Int = 16) -> MotionSignature? {
        guard let comp = document.composition(compId) else { return nil }
        let engine = TextEngine(device: renderer.device)
        let bg = comp.backgroundColor
        var frames: [PixelImage] = []
        let n = max(frameCount, 2)
        for i in 0..<n {
            let t = comp.duration * Double(i) / Double(n - 1)
            let nodes = RenderTreeBuilder(document: document, textEngine: engine, textures: textures)
                .build(compId: compId, at: t)
            guard let img = renderer.renderToImage(nodes: nodes,
                                                   compSize: SIMD2<Float>(Float(comp.size.x), Float(comp.size.y)),
                                                   pixelSize: (max(width, 1), max(height, 1)),
                                                   clear: SIMD4<Double>(bg.r, bg.g, bg.b, 1)) else { continue }
            frames.append(img)
        }
        let fps = comp.duration > 0 ? Double(n) / comp.duration : Double(n)
        return signature(frames: frames, fps: fps)
    }

    private static func palette(_ frames: [PixelImage], maxColors: Int = 6) -> [String] {
        guard !frames.isEmpty else { return [] }
        let pal = GIFQuantizer.palette(from: frames, maxColors: maxColors)
        return pal.rgb.map { String(format: "#%02X%02X%02X",
                                    Int(min(max($0.r, 0), 255)), Int(min(max($0.g, 0), 255)), Int(min(max($0.b, 0), 255))) }
    }
}
#endif
