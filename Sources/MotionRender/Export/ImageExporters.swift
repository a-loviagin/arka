#if os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd
import MotionKernel

/// Shared per-frame offscreen rendering for the image-based exporters.
private struct FrameSource {
    let document: MotionDocument
    let compId: EntityID
    let renderer: MetalRenderer
    let textEngine: TextEngine?
    let textures: (any TextureProvider)?
    let comp: Composition
    let pixelSize: (width: Int, height: Int)
    let clear: SIMD4<Double>

    func image(at t: TimeInterval) -> PixelImage? {
        let nodes = RenderTreeBuilder(document: document, textEngine: textEngine, textures: textures)
            .build(compId: compId, at: t)
        return renderer.renderToImage(
            nodes: nodes,
            compSize: SIMD2<Float>(Float(comp.size.x), Float(comp.size.y)),
            pixelSize: pixelSize, clear: clear)
    }
}

private func frameSource(_ document: MotionDocument, _ compId: EntityID, _ renderer: MetalRenderer,
                         _ textures: (any TextureProvider)?, width: Int, height: Int,
                         transparent: Bool) -> FrameSource? {
    guard let comp = document.composition(compId) else { return nil }
    let bg = comp.backgroundColor
    return FrameSource(document: document, compId: compId, renderer: renderer,
                       textEngine: TextEngine(device: renderer.device), textures: textures, comp: comp,
                       pixelSize: (max(width, 1), max(height, 1)),
                       clear: transparent ? SIMD4(0, 0, 0, 0) : SIMD4(bg.r, bg.g, bg.b, 1))
}

/// Animated GIF export (export-and-format.md §1). fps is capped at 50 (GIF delays are
/// centisecond-quantized; 50fps = 2cs exactly). Palette quantization is ImageIO's adaptive
/// per-image palette for v1 — per-scene libimagequant palettes are a later quality upgrade.
public enum GIFExporter {
    public enum GIFError: Error { case setup, noFrame }

    public static func export(document: MotionDocument, compId: EntityID, renderer: MetalRenderer,
                              textures: (any TextureProvider)? = nil,
                              width: Int, height: Int, fps: Double,
                              startTime: TimeInterval, endTime: TimeInterval,
                              to url: URL, progress: ((Double) -> Void)? = nil) throws {
        guard let src = frameSource(document, compId, renderer, textures, width: width, height: height,
                                    transparent: false) else { throw GIFError.setup }
        let cappedFps = min(max(fps, 1), 50)
        let duration = max(endTime - startTime, 1 / cappedFps)
        let frameCount = max(Int((duration * cappedFps).rounded()), 1)
        let delay = max((100.0 / cappedFps).rounded() / 100.0, 0.02) // seconds, centisecond-quantized

        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount,
            [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        else { throw GIFError.setup }

        let frameProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary
        for i in 0..<frameCount {
            let t = startTime + Double(i) / cappedFps
            guard let cg = src.image(at: t)?.cgImage() else { throw GIFError.noFrame }
            CGImageDestinationAddImage(dest, cg, frameProps)
            progress?(Double(i + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(dest) else { throw GIFError.setup }
    }
}

/// PNG image-sequence export (export-and-format.md §1): zero-padded numbered frames into a folder.
public enum ImageSequenceExporter {
    public enum SequenceError: Error { case setup, noFrame }

    public static func export(document: MotionDocument, compId: EntityID, renderer: MetalRenderer,
                              textures: (any TextureProvider)? = nil,
                              width: Int, height: Int, fps: Double,
                              startTime: TimeInterval, endTime: TimeInterval,
                              transparent: Bool = true, to directory: URL,
                              baseName: String = "frame", progress: ((Double) -> Void)? = nil) throws {
        guard let src = frameSource(document, compId, renderer, textures, width: width, height: height,
                                    transparent: transparent) else { throw SequenceError.setup }
        let duration = max(endTime - startTime, 1 / max(fps, 1))
        let frameCount = max(Int((duration * fps).rounded()), 1)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0..<frameCount {
            let t = startTime + Double(i) / fps
            guard let data = src.image(at: t)?.pngData() else { throw SequenceError.noFrame }
            let name = String(format: "%@_%04d.png", baseName, i)
            try data.write(to: directory.appendingPathComponent(name))
            progress?(Double(i + 1) / Double(frameCount))
        }
    }
}
#endif
