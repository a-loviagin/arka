#if os(macOS)
import Foundation
import Metal
import CoreText
import CoreGraphics
import simd

/// Per-(font,size) glyph cache rasterized into a shared atlas texture (render-engine.md §2).
/// Glyphs are grayscale coverage (R8); the shader tints them with the text's fill color and
/// composites on the transparent intermediate — grayscale AA, not subpixel, exactly as specced.
///
/// A simple shelf packer fills one atlas. Big scale changes should get their own size bucket;
/// v1 keys by (fontName, rounded pixel size, glyphID) and assumes the corpus fits 2048².
final class GlyphAtlas {
    struct GlyphInfo {
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        // Glyph image bounding box relative to the pen origin (baseline), CoreGraphics y-up points.
        var bboxMinX: Float
        var bboxMinY: Float
        var bboxW: Float
        var bboxH: Float
    }

    let texture: MTLTexture
    private let dimension: Int
    private let pad = 1

    private var cursorX = 1
    private var cursorY = 1
    private var shelfHeight = 0
    private var cache: [Key: GlyphInfo] = [:]

    private struct Key: Hashable { let font: String; let sizeBucket: Int; let glyph: UInt16 }

    init?(device: MTLDevice, dimension: Int = 2048) {
        self.dimension = dimension
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: dimension, height: dimension, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = tex
    }

    /// Fetch (rasterizing on first use) the atlas entry for a glyph in a given CTFont.
    func glyph(_ glyph: CGGlyph, font: CTFont, fontName: String, size: CGFloat) -> GlyphInfo? {
        let key = Key(font: fontName, sizeBucket: Int((size).rounded()), glyph: glyph)
        if let cached = cache[key] { return cached }
        guard let info = rasterize(glyph, font: font) else { return nil }
        cache[key] = info
        return info
    }

    private func rasterize(_ glyph: CGGlyph, font: CTFont) -> GlyphInfo? {
        var g = glyph
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &g, &bbox, 1)

        // Whitespace / zero-area glyphs (space) carry advance but no image.
        let w = Int(ceil(bbox.width)) + 2 * pad
        let h = Int(ceil(bbox.height)) + 2 * pad
        if bbox.width <= 0 || bbox.height <= 0 {
            let empty = GlyphInfo(uvOrigin: .zero, uvSize: .zero,
                                  bboxMinX: 0, bboxMinY: 0, bboxW: 0, bboxH: 0)
            return empty
        }

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        // Place the glyph so its bbox sits inside the padded bitmap (CG default y-up).
        var pos = CGPoint(x: CGFloat(pad) - bbox.minX, y: CGFloat(pad) - bbox.minY)
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

        guard let (x, y) = allocate(w: w, h: h), let data = ctx.data else { return nil }
        texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: w)

        let d = Float(dimension)
        return GlyphInfo(
            uvOrigin: SIMD2<Float>(Float(x) / d, Float(y) / d),
            uvSize: SIMD2<Float>(Float(w) / d, Float(h) / d),
            bboxMinX: Float(bbox.minX) - Float(pad),
            bboxMinY: Float(bbox.minY) - Float(pad),
            bboxW: Float(w),
            bboxH: Float(h)
        )
    }

    /// Shelf allocator: returns the top-left of a free w×h slot, or nil if the atlas is full.
    private func allocate(w: Int, h: Int) -> (Int, Int)? {
        if cursorX + w + pad > dimension { // new shelf
            cursorX = 1
            cursorY += shelfHeight + pad
            shelfHeight = 0
        }
        if cursorY + h + pad > dimension { return nil } // full (v1: no eviction)
        let x = cursorX, y = cursorY
        cursorX += w + pad
        shelfHeight = max(shelfHeight, h)
        return (x, y)
    }
}
#endif
