#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A CPU-side BGRA8 image read back from an offscreen render (render-engine.md §5/§7). The store
/// order is the drawable's native BGRA; accessors return straight (r, g, b, a) for convenience.
/// Values are pre-multiplied sRGB-encoded (what the renderer wrote), so for a fully-opaque pixel
/// `r/g/b` are the shape's fill bytes directly.
public struct PixelImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    /// (r, g, b, a) at a pixel, each 0…255. Out-of-bounds returns zero.
    public func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let i = (y * width + x) * 4
        return (bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3])
    }

    /// Mean absolute per-channel difference vs another image of the same size (0…255).
    /// The perceptual-tolerance knob for golden-frame comparison (render-engine.md §7).
    public func meanAbsoluteDifference(to other: PixelImage) -> Double {
        guard width == other.width, height == other.height, bgra.count == other.bgra.count else {
            return .infinity
        }
        var sum = 0.0
        for i in 0..<bgra.count {
            sum += abs(Double(bgra[i]) - Double(other.bgra[i]))
        }
        return sum / Double(bgra.count)
    }

    // MARK: PNG via ImageIO

    /// Reconstruct a `CGImage` from the BGRA bytes (premultipliedFirst + little-endian = BGRA).
    public func cgImage() -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: cs, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func load(pngData data: Data) -> PixelImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bgra, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return PixelImage(width: w, height: h, bgra: bgra)
    }
}
#endif
