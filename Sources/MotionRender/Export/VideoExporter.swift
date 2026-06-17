#if os(macOS)
import Foundation
import AVFoundation
import CoreVideo
import Metal
import simd
import MotionKernel

/// Offscreen MP4/MOV export (export-and-format.md §1-2, render-engine.md §5). Steps each frame at
/// **exact rational time** `t = startFrame/fps` — no clock is reachable from this path, so export
/// never depends on wall time or dropped frames. Frames render into `CVPixelBuffer`-backed Metal
/// textures (zero-copy via `CVMetalTextureCache`) and feed an `AVAssetWriter`.
public final class VideoExporter {
    public struct Settings: Sendable {
        public enum Codec: Sendable { case h264, hevc }
        public var width: Int
        public var height: Int
        public var fps: Double
        public var startTime: TimeInterval
        public var endTime: TimeInterval
        public var codec: Codec
        /// Quality as bits per pixel per frame (~0.12 good, ~0.2 high — export-and-format.md §1).
        public var bitsPerPixelPerFrame: Double

        public init(width: Int, height: Int, fps: Double,
                    startTime: TimeInterval, endTime: TimeInterval,
                    codec: Codec = .h264, bitsPerPixelPerFrame: Double = 0.12) {
            // H.264/HEVC require even dimensions; round down.
            self.width = max(width - (width % 2), 2)
            self.height = max(height - (height % 2), 2)
            self.fps = fps
            self.startTime = startTime
            self.endTime = endTime
            self.codec = codec
            self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
        }

        /// 1× full-comp H.264 preset.
        public static func standard(for comp: Composition) -> Settings {
            Settings(width: Int(comp.size.x), height: Int(comp.size.y), fps: comp.fps,
                     startTime: 0, endTime: comp.duration)
        }
    }

    public enum ExportError: Error, CustomStringConvertible {
        case writerSetup(String)
        case pixelBufferUnavailable
        case textureCreationFailed
        case appendFailed(Int)
        case cancelled
        case finishFailed(String)

        public var description: String {
            switch self {
            case .writerSetup(let m): "export writer setup failed: \(m)"
            case .pixelBufferUnavailable: "no pixel buffer available from the pool"
            case .textureCreationFailed: "could not back a pixel buffer with a Metal texture"
            case .appendFailed(let f): "failed to append frame \(f)"
            case .cancelled: "export cancelled"
            case .finishFailed(let m): "finishing the file failed: \(m)"
            }
        }
    }

    private let renderer: MetalRenderer
    private let textEngine: TextEngine?
    private weak var textures: (any TextureProvider)?

    public init(renderer: MetalRenderer, textures: (any TextureProvider)? = nil) {
        self.renderer = renderer
        self.textEngine = TextEngine(device: renderer.device)
        self.textures = textures
    }

    /// `cancel` is polled between frames. `progress` is called with 0…1 after each frame.
    public func export(document: MotionDocument, compId: EntityID, settings: Settings, to url: URL,
                       progress: ((Double) -> Void)? = nil,
                       cancel: (() -> Bool)? = nil) throws {
        guard let comp = document.composition(compId) else {
            throw ExportError.writerSetup("composition \(compId) not found")
        }
        try? FileManager.default.removeItem(at: url)

        let fileType: AVFileType = .mp4
        let writer = try AVAssetWriter(url: url, fileType: fileType)

        let bitrate = Int(settings.bitsPerPixelPerFrame
                          * Double(settings.width * settings.height) * settings.fps)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
        compression[AVVideoExpectedSourceFrameRateKey] = Int(settings.fps.rounded())

        let codec: AVVideoCodecType = settings.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])

        guard writer.canAdd(input) else { throw ExportError.writerSetup("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerSetup(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        var cacheRef: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &cacheRef)
        guard let textureCache = cacheRef else { throw ExportError.textureCreationFailed }

        let compSize = SIMD2<Float>(Float(comp.size.x), Float(comp.size.y))
        let bg = comp.backgroundColor
        let clear = SIMD4<Double>(bg.r, bg.g, bg.b, 1) // opaque frames for video
        let duration = max(settings.endTime - settings.startTime, 1.0 / settings.fps)
        let frameCount = max(Int((duration * settings.fps).rounded()), 1)
        let timescale = Int32(max(settings.fps.rounded(), 1))
        let frameDuration = CMTime(value: 1, timescale: timescale)

        for i in 0..<frameCount {
            if cancel?() == true {
                writer.cancelWriting()
                throw ExportError.cancelled
            }
            while !input.isReadyForMoreMediaData { usleep(2000) }

            guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferUnavailable }
            var pbRef: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbRef) == kCVReturnSuccess,
                  let pixelBuffer = pbRef else { throw ExportError.pixelBufferUnavailable }
            guard let texture = metalTexture(from: pixelBuffer, cache: textureCache) else {
                throw ExportError.textureCreationFailed
            }

            let t = settings.startTime + Double(i) / settings.fps
            let nodes = RenderTreeBuilder(document: document, textEngine: textEngine, textures: textures)
                .build(compId: compId, at: t)
            renderer.render(nodes: nodes, compSize: compSize, clear: clear, into: texture)

            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw ExportError.appendFailed(i)
            }
            progress?(Double(i + 1) / Double(frameCount))
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        if writer.status == .failed {
            throw ExportError.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    private func metalTexture(from pixelBuffer: CVPixelBuffer,
                              cache: CVMetalTextureCache) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return texture
    }
}
#endif
