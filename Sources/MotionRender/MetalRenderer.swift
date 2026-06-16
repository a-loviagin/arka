#if os(macOS)
import Foundation
import Metal
import QuartzCore
import simd

/// Per-instance SDF shape data. **Layout must match `InstanceUniform` in Shaders.swift exactly.**
struct InstanceUniform {
    var clipFromLocal: simd_float3x3
    var fill: SIMD4<Float>
    var stroke: SIMD4<Float>
    var size: SIMD2<Float>
    var cornerRadius: Float
    var strokeWidth: Float
    var kind: UInt32
    var opacity: Float
}

/// Per-instance textured-quad data (glyphs / images). **Must match `GlyphInstance` in Shaders.swift.**
struct GlyphInstance {
    var clipFromLocal: simd_float3x3
    var localOrigin: SIMD2<Float>
    var localSize: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var tint: SIMD4<Float>
    var opacity: Float
}

/// The GPU half of the engine (render-engine.md §1-2). Consumes a RenderTree and draws instanced
/// SDF shapes + textured glyph runs into a `CAMetalLayer` drawable, walking items in z-order so
/// shapes and text composite correctly. Knows nothing about the document.
///
/// v1 simplifications vs. spec: draws into an sRGB drawable rather than fp16 linear targets + EDR
/// (render-engine.md §4) — correct-looking pixels now; the linear pipeline is a later upgrade.
public final class MetalRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let shapePipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let pool: IntermediatePool

    private var shapeBuffer = GrowableBuffer<InstanceUniform>()
    private var glyphBuffer = GrowableBuffer<GlyphInstance>()

    /// Blur kernel parameters — must match `BlurParams` in Shaders.swift.
    private struct BlurParams { var texelStep: SIMD2<Float>; var sigma: Float; var taps: Int32 }
    /// Composite parameters — must match `CompositeParams` in Shaders.swift.
    private struct CompositeParams {
        var offsetNDC: SIMD2<Float>; var tint: SIMD4<Float>; var opacity: Float; var mode: UInt32
    }
    /// A composite of an intermediate into the main pass (shadow or normal), at the item's z-order.
    private struct CompositeOp {
        var texture: MTLTexture; var offsetNDC: SIMD2<Float>
        var tint: SIMD4<Float>; var opacity: Float; var mode: UInt32
    }

    public enum SetupError: Error { case noQueue, noLibrary }

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SetupError.noQueue }
        self.queue = queue

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: ShaderSource.metal, options: nil) }
        catch { throw SetupError.noLibrary }

        func pipeline(_ vfn: String, _ ffn: String, blend: Bool = true) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vfn)
            desc.fragmentFunction = library.makeFunction(name: ffn)
            let c = desc.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = blend
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one          // pre-multiplied "over"
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        self.shapePipeline = try pipeline("shape_vertex", "shape_fragment")
        self.glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
        self.imagePipeline = try pipeline("glyph_vertex", "image_fragment")
        self.blurPipeline = try pipeline("fullscreen_vertex", "blur_fragment", blend: false)
        self.compositePipeline = try pipeline("composite_vertex", "composite_fragment")

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sdesc)!
        self.pool = IntermediatePool(device: device)
    }

    /// Column-major comp→NDC projection, aspect-fit and centered into the drawable.
    private func projection(compSize: SIMD2<Float>, viewport: SIMD2<Float>) -> simd_float3x3 {
        let cw = max(compSize.x, 1), ch = max(compSize.y, 1)
        let vw = max(viewport.x, 1), vh = max(viewport.y, 1)
        let scale = min(vw / cw, vh / ch)
        let ox = (vw - cw * scale) / 2
        let oy = (vh - ch * scale) / 2
        let sx = 2 * scale / vw
        let sy = -2 * scale / vh
        let tx = 2 * ox / vw - 1
        let ty = 1 - 2 * oy / vh
        return simd_float3x3(SIMD3<Float>(sx, 0, 0), SIMD3<Float>(0, sy, 0), SIMD3<Float>(tx, ty, 1))
    }

    private enum DrawOp {
        case shapes(base: Int, count: Int)
        case glyphs(base: Int, count: Int, texture: MTLTexture)
        case image(base: Int, texture: MTLTexture)
        case composite(CompositeOp)
    }

    /// Draw a RenderTree into a drawable (the live preview path). `clear` is sRGB-encoded rgba.
    public func draw(items: [RenderItem], compSize: SIMD2<Float>, viewport: SIMD2<Float>,
                     clear: SIMD4<Double>, to drawable: CAMetalDrawable) {
        let proj = projection(compSize: compSize, viewport: viewport)
        guard let cmd = queue.makeCommandBuffer() else { return }
        renderFrame(items: items, proj: proj, clear: clear, target: drawable.texture, cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Render a RenderTree into an offscreen texture and read the pixels back (render-engine.md §5
    /// export path / §7 golden frames). 1:1 mapping when `pixelSize == compSize`. Same evaluate +
    /// encode objects as the preview path — that equivalence is the product's correctness promise.
    public func renderToImage(items: [RenderItem], compSize: SIMD2<Float>,
                              pixelSize: (width: Int, height: Int),
                              clear: SIMD4<Double>) -> PixelImage? {
        let vp = SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height))
        let proj = projection(compSize: compSize, viewport: vp)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelSize.width, height: pixelSize.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared // Apple Silicon: CPU-readable without a blit
        guard let texture = device.makeTexture(descriptor: desc),
              let cmd = queue.makeCommandBuffer() else { return nil }

        renderFrame(items: items, proj: proj, clear: clear, target: texture, cmd: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: pixelSize.width * pixelSize.height * 4)
        bgra.withUnsafeMutableBytes { ptr in
            texture.getBytes(ptr.baseAddress!, bytesPerRow: pixelSize.width * 4,
                             from: MTLRegionMake2D(0, 0, pixelSize.width, pixelSize.height),
                             mipmapLevel: 0)
        }
        return PixelImage(width: pixelSize.width, height: pixelSize.height, bgra: bgra)
    }

    /// One frame: pre-render effect layers into intermediates, then a single main pass that draws
    /// direct items and composites the effect results in z-order. The command buffer retains the
    /// transient buffers / pool textures until completion.
    private func renderFrame(items: [RenderItem], proj: simd_float3x3,
                             clear: SIMD4<Double>, target: MTLTexture, cmd: MTLCommandBuffer) {
        pool.releaseAll()
        let w = target.width, h = target.height
        var transient: [MTLBuffer] = []

        // Phase 1: render each effected layer (content → blur passes) into pooled textures.
        var effectOps: [Int: [CompositeOp]] = [:]
        for (i, item) in items.enumerated() where !item.effects.isEmpty {
            effectOps[i] = makeEffectComposites(item, proj: proj, w: w, h: h,
                                                cmd: cmd, transient: &transient)
        }

        // Phase 2: build the ordered main-pass op list (direct items batched; effect items → composites).
        var shapes: [InstanceUniform] = []
        var glyphs: [GlyphInstance] = []
        var ops: [DrawOp] = []
        var pendingShapeBase = 0
        var pendingShapeCount = 0
        func flushShapes() {
            if pendingShapeCount > 0 { ops.append(.shapes(base: pendingShapeBase, count: pendingShapeCount)); pendingShapeCount = 0 }
        }

        for (i, item) in items.enumerated() {
            if let composites = effectOps[i] {
                flushShapes()
                for c in composites { ops.append(.composite(c)) }
                continue
            }
            let clip = proj * item.world
            switch item.content {
            case .shape(let s):
                if pendingShapeCount == 0 { pendingShapeBase = shapes.count }
                shapes.append(shapeInstance(s, clip: clip, opacity: item.opacity))
                pendingShapeCount += 1
            case .glyphRun(let run):
                flushShapes()
                let base = glyphs.count
                glyphs.append(contentsOf: glyphInstances(run, clip: clip, opacity: item.opacity))
                if glyphs.count > base { ops.append(.glyphs(base: base, count: glyphs.count - base, texture: run.atlas)) }
            case .image(let img):
                flushShapes()
                let base = glyphs.count
                glyphs.append(imageInstance(img, clip: clip, opacity: item.opacity))
                ops.append(.image(base: base, texture: img.texture))
            }
        }
        flushShapes()

        shapeBuffer.upload(shapes, device: device)
        glyphBuffer.upload(glyphs, device: device)

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: clearedPass(target, clear)) else { return }
        for op in ops {
            switch op {
            case .shapes(let base, let count):
                if let buf = shapeBuffer.buffer { drawShapes(enc, buf, base: base, count: count) }
            case .glyphs(let base, let count, let texture):
                if let buf = glyphBuffer.buffer { drawTextured(enc, glyphPipeline, buf, base: base, count: count, texture: texture) }
            case .image(let base, let texture):
                if let buf = glyphBuffer.buffer { drawTextured(enc, imagePipeline, buf, base: base, count: 1, texture: texture) }
            case .composite(let c):
                drawComposite(enc, c)
            }
        }
        enc.endEncoding()
        _ = transient // retained by cmd until completion
    }

    // MARK: Effect pre-passes

    private func makeEffectComposites(_ item: RenderItem, proj: simd_float3x3, w: Int, h: Int,
                                      cmd: MTLCommandBuffer, transient: inout [MTLBuffer]) -> [CompositeOp] {
        guard let content = renderContent(item, proj: proj, w: w, h: h, cmd: cmd, transient: &transient)
        else { return [] }

        var ops: [CompositeOp] = []
        // Shadows draw first (behind), using a blurred copy of the sharp content's alpha.
        for fx in item.effects {
            if case .shadow(let offset, let radius, let color, let opacity) = fx {
                let blurred = blur(content, radius: radius, w: w, h: h, cmd: cmd)
                let offNDC = SIMD2<Float>(offset.x * proj.columns.0.x, offset.y * proj.columns.1.y)
                ops.append(CompositeOp(texture: blurred, offsetNDC: offNDC, tint: color,
                                       opacity: opacity * item.opacity, mode: 1))
            }
        }
        // Content on top, blurred if any blur effect is present.
        var result = content
        for fx in item.effects {
            if case .blur(let radius) = fx { result = blur(result, radius: radius, w: w, h: h, cmd: cmd) }
        }
        ops.append(CompositeOp(texture: result, offsetNDC: .zero, tint: SIMD4<Float>(1, 1, 1, 1),
                               opacity: item.opacity, mode: 0))
        return ops
    }

    /// Render a single layer's content (opacity 1) into a fresh pooled texture.
    private func renderContent(_ item: RenderItem, proj: simd_float3x3, w: Int, h: Int,
                               cmd: MTLCommandBuffer, transient: inout [MTLBuffer]) -> MTLTexture? {
        guard let tex = pool.acquire(width: w, height: h) else { return nil }
        let clip = proj * item.world
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: clearedPass(tex, .init(0, 0, 0, 0))) else { return tex }
        switch item.content {
        case .shape(let s):
            if let buf = makeBuffer([shapeInstance(s, clip: clip, opacity: 1)]) {
                transient.append(buf); drawShapes(enc, buf, base: 0, count: 1)
            }
        case .glyphRun(let run):
            let insts = glyphInstances(run, clip: clip, opacity: 1)
            if let buf = makeBuffer(insts) {
                transient.append(buf); drawTextured(enc, glyphPipeline, buf, base: 0, count: insts.count, texture: run.atlas)
            }
        case .image(let img):
            if let buf = makeBuffer([imageInstance(img, clip: clip, opacity: 1)]) {
                transient.append(buf); drawTextured(enc, imagePipeline, buf, base: 0, count: 1, texture: img.texture)
            }
        }
        enc.endEncoding()
        return tex
    }

    /// Separable Gaussian blur of `src` (premultiplied), returning a new pooled texture.
    private func blur(_ src: MTLTexture, radius: Float, w: Int, h: Int, cmd: MTLCommandBuffer) -> MTLTexture {
        guard let tmp = pool.acquire(width: w, height: h),
              let out = pool.acquire(width: w, height: h) else { return src }
        let sigma = max(radius / 2, 0.5)
        let taps = Int32(min(max(Int(ceil(Double(radius))), 1), 24))
        blurPass(src: src, dst: tmp, step: SIMD2<Float>(1 / Float(w), 0), sigma: sigma, taps: taps, cmd: cmd)
        blurPass(src: tmp, dst: out, step: SIMD2<Float>(0, 1 / Float(h)), sigma: sigma, taps: taps, cmd: cmd)
        return out
    }

    private func blurPass(src: MTLTexture, dst: MTLTexture, step: SIMD2<Float>, sigma: Float,
                          taps: Int32, cmd: MTLCommandBuffer) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: clearedPass(dst, .init(0, 0, 0, 0))) else { return }
        var p = BlurParams(texelStep: step, sigma: sigma, taps: taps)
        enc.setRenderPipelineState(blurPipeline)
        enc.setFragmentBytes(&p, length: MemoryLayout<BlurParams>.stride, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    // MARK: Draw helpers

    private func drawShapes(_ enc: MTLRenderCommandEncoder, _ buf: MTLBuffer, base: Int, count: Int) {
        var b = UInt32(base)
        enc.setRenderPipelineState(shapePipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&b, length: 4, index: 1)
        enc.setFragmentBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    private func drawTextured(_ enc: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState,
                              _ buf: MTLBuffer, base: Int, count: Int, texture: MTLTexture) {
        var b = UInt32(base)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&b, length: 4, index: 1)
        enc.setFragmentBuffer(buf, offset: 0, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    private func drawComposite(_ enc: MTLRenderCommandEncoder, _ c: CompositeOp) {
        var p = CompositeParams(offsetNDC: c.offsetNDC, tint: c.tint, opacity: c.opacity, mode: c.mode)
        enc.setRenderPipelineState(compositePipeline)
        enc.setVertexBytes(&p, length: MemoryLayout<CompositeParams>.stride, index: 0)
        enc.setFragmentBytes(&p, length: MemoryLayout<CompositeParams>.stride, index: 0)
        enc.setFragmentTexture(c.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: Instance builders

    private func shapeInstance(_ s: ResolvedShape, clip: simd_float3x3, opacity: Float) -> InstanceUniform {
        InstanceUniform(clipFromLocal: clip, fill: s.fill, stroke: s.stroke, size: s.size,
                        cornerRadius: s.cornerRadius, strokeWidth: s.strokeWidth,
                        kind: s.kind.rawValue, opacity: opacity)
    }
    private func glyphInstances(_ run: GlyphRun, clip: simd_float3x3, opacity: Float) -> [GlyphInstance] {
        run.glyphs.map {
            GlyphInstance(clipFromLocal: clip, localOrigin: $0.localOrigin, localSize: $0.localSize,
                          uvOrigin: $0.uvOrigin, uvSize: $0.uvSize, tint: run.fill, opacity: opacity)
        }
    }
    private func imageInstance(_ img: ImageQuad, clip: simd_float3x3, opacity: Float) -> GlyphInstance {
        GlyphInstance(clipFromLocal: clip, localOrigin: .zero, localSize: img.size,
                      uvOrigin: .zero, uvSize: SIMD2<Float>(1, 1), tint: SIMD4<Float>(1, 1, 1, 1), opacity: opacity)
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
    }

    private func clearedPass(_ target: MTLTexture, _ clear: SIMD4<Double>) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: clear.x, green: clear.y, blue: clear.z, alpha: clear.w)
        return pass
    }
}

/// A shared-storage MTLBuffer that grows as needed and is rewritten each frame. Steady-state
/// playback reuses the allocation (no per-frame churn once warm).
private struct GrowableBuffer<T> {
    private(set) var buffer: MTLBuffer?
    private var capacity = 0

    mutating func upload(_ values: [T], device: MTLDevice) {
        guard !values.isEmpty else { return }
        if values.count > capacity {
            let newCap = max(values.count, capacity * 2, 64)
            buffer = device.makeBuffer(length: newCap * MemoryLayout<T>.stride,
                                       options: .storageModeShared)
            capacity = newCap
        }
        if let buffer {
            values.withUnsafeBytes { src in
                buffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
    }
}
#endif
