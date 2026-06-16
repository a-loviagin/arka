#if os(macOS)
import Foundation
import simd
import Metal
import MotionKernel

/// The flat, immutable draw unit the GPU side consumes (render-engine.md §1). The renderer knows
/// nothing about keyframes, easing, or the document — only resolved geometry, style, and a world
/// matrix. This is the RenderTree boundary: `simd` and Metal live here, never in MotionKernel.
public struct RenderItem {
    /// Maps layer-local space (origin at the layer's top-left) to comp space.
    var world: simd_float3x3
    var opacity: Float
    var content: RenderContent
    /// Effects applied to this layer's rasterized result, in order. A non-empty list forces the
    /// layer through an intermediate texture (render-engine.md §3).
    var effects: [ResolvedEffect] = []
}

/// An effect resolved to concrete values at one time (render-engine.md §3, properties §1 Tier 2).
enum ResolvedEffect {
    case blur(radius: Float)
    case shadow(offset: SIMD2<Float>, radius: Float, color: SIMD4<Float>, opacity: Float)
}

/// What a RenderItem draws. SDF shapes and textured runs (glyphs now, images next) share the
/// ordered draw walk so z-order is always respected.
enum RenderContent {
    case shape(ResolvedShape)
    case glyphRun(GlyphRun)
    case image(ImageQuad)
}

/// An image layer resolved to a textured quad spanning the layer's local bounds (uv full).
struct ImageQuad {
    var texture: MTLTexture
    var size: SIMD2<Float>   // layer-local extents (points) = the asset's pixel size
}

/// A laid-out run of glyphs sharing one atlas texture, tinted by the text's fill color. Positions
/// are in text-local space (y-down; origin at the layer's top-left).
struct GlyphRun {
    var atlas: MTLTexture
    var fill: SIMD4<Float>
    var glyphs: [GlyphQuad]
}

struct GlyphQuad {
    var localOrigin: SIMD2<Float>   // top-left in text-local space
    var localSize: SIMD2<Float>
    var uvOrigin: SIMD2<Float>      // normalized atlas coords
    var uvSize: SIMD2<Float>
}

enum ShapeKind: UInt32 {
    case rect = 0
    case ellipse = 1
}

/// A Tier-1 parametric shape resolved to concrete values at one time.
struct ResolvedShape {
    var kind: ShapeKind
    var size: SIMD2<Float>
    var cornerRadius: Float
    var fill: SIMD4<Float>      // straight (non-premultiplied) sRGB-encoded rgba
    var stroke: SIMD4<Float>
    var strokeWidth: Float
}

extension simd_float3x3 {
    /// Column-major 3x3 from the kernel's row-vector `Affine2D` (p' = p·M).
    init(_ m: Affine2D) {
        // Row-vector affine [a b 0; c d 0; tx ty 1] → column-major float3x3 with the same action
        // when we compute `M * float3(p, 1)` in the shader (we transpose into columns accordingly).
        self.init(
            SIMD3<Float>(Float(m.a), Float(m.b), 0),
            SIMD3<Float>(Float(m.c), Float(m.d), 0),
            SIMD3<Float>(Float(m.tx), Float(m.ty), 1)
        )
    }
}

extension SIMD4 where Scalar == Float {
    init(_ c: ColorValue) {
        self.init(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}
#endif
