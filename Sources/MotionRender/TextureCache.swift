#if os(macOS)
import Foundation
import Metal
import CoreGraphics
import ImageIO
import MotionKernel

/// Supplies decoded textures for image/video layers, keyed by `assetId` (render-engine.md §2:
/// "decoded once via ImageIO into MTLTexture, keyed by assetId"). The RenderTree builder asks a
/// provider for each image layer's texture; the app backs it with a real cache, tests with
/// procedurally-registered images.
public protocol TextureProvider: AnyObject {
    func texture(forAssetId id: EntityID) -> MTLTexture?
}

/// Decodes and caches image assets as premultiplied rgba8 textures.
public final class TextureCache: TextureProvider {
    private let device: MTLDevice
    private var cache: [EntityID: MTLTexture] = [:]

    public init(device: MTLDevice) {
        self.device = device
    }

    public func texture(forAssetId id: EntityID) -> MTLTexture? {
        cache[id]
    }

    /// Decode + cache an asset from disk relative to a `.motion` package's base URL.
    @discardableResult
    public func load(asset: Asset, baseURL: URL) -> MTLTexture? {
        if let t = cache[asset.id] { return t }
        let url = baseURL.appending(path: asset.path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return register(id: asset.id, cgImage: cg)
    }

    /// Register an in-memory image (procedural demo content, tests).
    @discardableResult
    public func register(id: EntityID, cgImage cg: CGImage) -> MTLTexture? {
        if let t = cache[id] { return t }
        guard let texture = Self.makeTexture(from: cg, device: device) else { return nil }
        cache[id] = texture
        return texture
    }

    /// Decode a CGImage into a premultiplied rgba8 (top-left origin) Metal texture. Shared by the
    /// image cache and the video frame provider.
    static func makeTexture(from cg: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // premultipliedLast, big-endian byte order → R,G,B,A in memory == Metal .rgba8Unorm.
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
        // CGContext origin is bottom-left; flip so memory row 0 = top of image, matching Metal's
        // top-left uv origin (otherwise the texture samples upside down).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // sRGB texture → samples auto-decode to linear, matching the renderer's linear working space.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes { ptr in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                            withBytes: ptr.baseAddress!, bytesPerRow: w * 4)
        }
        return texture
    }
}
#endif
