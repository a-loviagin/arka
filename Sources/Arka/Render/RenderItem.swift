#if os(macOS)
import Foundation
import simd
import MotionKernel

/// The flat, immutable draw unit the GPU side consumes (render-engine.md §1). The renderer knows
/// nothing about keyframes, easing, or the document — only resolved geometry, style, and a world
/// matrix. This is the RenderTree boundary: `simd` and Metal live here, never in MotionKernel.
struct RenderItem {
    /// Maps layer-local space (origin at the layer's top-left, spanning `size`) to comp space.
    var world: simd_float3x3
    var opacity: Float
    var shape: ResolvedShape
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
