#if os(macOS)
import Foundation
import Metal
import QuartzCore
import simd
import MotionKernel

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

/// Per-path uniform (tessellated vector fill). **Must match `PathUniform` in Shaders.swift.**
struct PathUniform {
    var clipFromLocal: simd_float3x3
    var fill: SIMD4<Float>
    var opacity: Float
}

/// Gradient fill params for the shape/path fragments. **Must match `GradientParams` in Shaders.swift.**
struct GradientParams {
    var start: SIMD2<Float> = .zero
    var end: SIMD2<Float> = .zero
    var kind: UInt32 = 0
    var hasGradient: UInt32 = 0
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
    private let pathPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let colorAdjustPipeline: MTLRenderPipelineState
    private let mattePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    /// Composite pipelines for non-normal blend modes (same shader, different fixed-function blend).
    private let blendPipelines: [BlendMode: MTLRenderPipelineState]
    /// Masked composite of a blurred backdrop (background blur).
    private let backdropPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let pool: IntermediatePool
    /// 1×1 white LUT bound to shape/path draws that have no gradient (the fragment ignores it when
    /// `hasGradient == 0`, but a texture must still be bound).
    private lazy var dummyLUT: MTLTexture = makeLUT([SIMD4<Float>(1, 1, 1, 1)])

    /// Blur kernel parameters — must match `BlurParams` in Shaders.swift.
    private struct BlurParams { var texelStep: SIMD2<Float>; var sigma: Float; var taps: Int32 }
    /// Color-adjust parameters — must match `ColorAdjustParams` in Shaders.swift.
    private struct ColorAdjustParams { var brightness: Float; var contrast: Float; var saturation: Float; var hue: Float }
    /// Composite parameters — must match `CompositeParams` in Shaders.swift.
    private struct CompositeParams {
        var offsetNDC: SIMD2<Float>; var tint: SIMD4<Float>; var opacity: Float; var mode: UInt32
    }
    /// A composite of an intermediate into the main pass (shadow or normal), at the item's z-order.
    private struct CompositeOp {
        var texture: MTLTexture; var offsetNDC: SIMD2<Float>
        var tint: SIMD4<Float>; var opacity: Float; var mode: UInt32
        var blend: BlendMode = .normal
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
            c.pixelFormat = .bgra8Unorm_srgb // linear-space compositing (render-engine.md §4)
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
        self.pathPipeline = try pipeline("path_vertex", "path_fragment")
        self.glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
        self.imagePipeline = try pipeline("glyph_vertex", "image_fragment")
        self.blurPipeline = try pipeline("fullscreen_vertex", "blur_fragment", blend: false)
        self.colorAdjustPipeline = try pipeline("fullscreen_vertex", "coloradjust_fragment", blend: false)
        self.mattePipeline = try pipeline("fullscreen_vertex", "matte_fragment", blend: false)
        self.compositePipeline = try pipeline("composite_vertex", "composite_fragment")

        // Premultiplied blend states for the non-normal modes (render-engine.md §3). The source is a
        // premultiplied intermediate, so transparent areas (rgb=a=0) leave the backdrop untouched.
        func blendComposite(_ srcRGB: MTLBlendFactor, _ dstRGB: MTLBlendFactor,
                            _ op: MTLBlendOperation) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "composite_vertex")
            desc.fragmentFunction = library.makeFunction(name: "composite_fragment")
            let c = desc.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm_srgb
            c.isBlendingEnabled = true
            c.rgbBlendOperation = op
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = srcRGB
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = dstRGB
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        self.blendPipelines = [
            .multiply: try blendComposite(.destinationColor, .oneMinusSourceAlpha, .add),
            .screen: try blendComposite(.oneMinusDestinationColor, .one, .add),
            .add: try blendComposite(.one, .one, .add),
            .lighten: try blendComposite(.one, .one, .max),
        ]
        self.backdropPipeline = try pipeline("fullscreen_vertex", "backdrop_fragment")

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
        /// A single gradient-filled shape (broken out of the flat batch — it binds its own LUT).
        case gradientShape(base: Int, gradient: ResolvedGradient)
        case path(buffer: MTLBuffer, count: Int, uniform: PathUniform, gradient: ResolvedGradient?)
        case glyphs(base: Int, count: Int, texture: MTLTexture)
        case image(base: Int, texture: MTLTexture)
        case composite(CompositeOp)
        /// Background blur: snapshot the target so far, blur it, composite masked by `content`'s
        /// coverage, then draw `content` on top. Segments the encoder (needs the backdrop as input).
        case backdrop(content: MTLTexture, radius: Float, opacity: Float)
    }

    /// Draw a RenderTree into a drawable (the live preview path). `clear` is sRGB-encoded rgba.
    public func draw(nodes: [RenderNode], compSize: SIMD2<Float>, viewport: SIMD2<Float>,
                     clear: SIMD4<Double>, to drawable: CAMetalDrawable) {
        let proj = projection(compSize: compSize, viewport: viewport)
        guard let cmd = queue.makeCommandBuffer() else { return }
        renderScene(nodes: nodes, proj: proj, clear: clear, target: drawable.texture, cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Draw with a caller-supplied scene→NDC projection (the multi-frame board path, which places
    /// each frame at a board position under a shared pan/zoom). Build it with `boardProjection`.
    public func draw(nodes: [RenderNode], projection proj: simd_float3x3,
                     clear: SIMD4<Double>, to drawable: CAMetalDrawable) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        renderScene(nodes: nodes, proj: proj, clear: clear, target: drawable.texture, cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Column-major board→NDC projection: a board point `p` maps to view pixel `pan + p * zoom`,
    /// then to NDC over a `viewport`-sized drawable (y-down → y-up). Pure (no GPU state), so callers
    /// can also use it to keep an overlay's coordinate math in lockstep with the rendered board.
    public func boardProjection(pan: SIMD2<Float>, zoom: Float, viewport: SIMD2<Float>) -> simd_float3x3 {
        let vw = max(viewport.x, 1), vh = max(viewport.y, 1)
        let sx = 2 * zoom / vw
        let sy = -2 * zoom / vh
        let tx = 2 * pan.x / vw - 1
        let ty = 1 - 2 * pan.y / vh
        return simd_float3x3(SIMD3<Float>(sx, 0, 0), SIMD3<Float>(0, sy, 0), SIMD3<Float>(tx, ty, 1))
    }

    /// Render a RenderTree into a caller-supplied texture (e.g. a `CVPixelBuffer`-backed export
    /// target — render-engine.md §5). Blocks until the GPU finishes so the texture can be read or
    /// encoded. Same evaluate + encode objects as the preview path: preview/export equivalence.
    public func render(nodes: [RenderNode], compSize: SIMD2<Float>,
                       clear: SIMD4<Double>, into target: MTLTexture) {
        let vp = SIMD2<Float>(Float(target.width), Float(target.height))
        let proj = projection(compSize: compSize, viewport: vp)
        guard let cmd = queue.makeCommandBuffer() else { return }
        renderScene(nodes: nodes, proj: proj, clear: clear, target: target, cmd: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// Render a RenderTree into an offscreen texture and read the pixels back (render-engine.md §5
    /// export path / §7 golden frames). 1:1 mapping when `pixelSize == compSize`. Same evaluate +
    /// encode objects as the preview path — that equivalence is the product's correctness promise.
    public func renderToImage(nodes: [RenderNode], compSize: SIMD2<Float>,
                              pixelSize: (width: Int, height: Int),
                              clear: SIMD4<Double>) -> PixelImage? {
        let vp = SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height))
        let proj = projection(compSize: compSize, viewport: vp)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: pixelSize.width, height: pixelSize.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared // Apple Silicon: CPU-readable without a blit
        guard let texture = device.makeTexture(descriptor: desc),
              let cmd = queue.makeCommandBuffer() else { return nil }

        renderScene(nodes: nodes, proj: proj, clear: clear, target: texture, cmd: cmd)
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

    /// One top-level frame: reset the pool, rasterize precomp/group subtrees into textures, then
    /// encode the main pass into `target`.
    private func renderScene(nodes: [RenderNode], proj: simd_float3x3,
                             clear: SIMD4<Double>, target: MTLTexture, cmd: MTLCommandBuffer) {
        pool.releaseAll()
        var transient: [MTLBuffer] = []
        let resolved = resolveTree(nodes, proj: proj, w: target.width, h: target.height,
                                   cmd: cmd, transient: &transient)
        encodeMain(resolved, proj: proj, clear: clear, target: target, cmd: cmd, transient: &transient)
        _ = transient // retained by cmd until completion
    }

    /// A node whose precomp/group subtree has been rasterized into a texture.
    private enum ResolvedNode {
        case item(RenderItem)
        case group(texture: MTLTexture, opacity: Float, effects: [ResolvedEffect], blend: BlendMode)
    }

    /// Depth-first resolve: a precomp renders its comp into a `compSize` texture, becoming an image
    /// leaf composited through the precomp transform; a group renders its children into a
    /// target-size texture (same projection → children keep absolute positions), composited
    /// fullscreen as a unit. The pool is never released mid-frame, so these textures stay valid
    /// until the command buffer completes.
    private func resolveTree(_ nodes: [RenderNode], proj: simd_float3x3, w: Int, h: Int,
                             cmd: MTLCommandBuffer, transient: inout [MTLBuffer]) -> [ResolvedNode] {
        var out: [ResolvedNode] = []
        for node in nodes {
            switch node {
            case .leaf(let item):
                out.append(.item(item))
            case .precomp(let pre):
                let pw = max(Int(pre.compSize.x), 1), ph = max(Int(pre.compSize.y), 1)
                guard let tex = pool.acquire(width: pw, height: ph) else { continue }
                let subProj = projection(compSize: pre.compSize, viewport: pre.compSize) // 1:1
                let sub = resolveTree(pre.children, proj: subProj, w: pw, h: ph, cmd: cmd, transient: &transient)
                // Precomps are transparent by default (the nested comp's background doesn't occlude).
                encodeMain(sub, proj: subProj, clear: SIMD4<Double>(0, 0, 0, 0), target: tex, cmd: cmd, transient: &transient)
                out.append(.item(RenderItem(world: pre.world, opacity: pre.opacity,
                                            content: .image(ImageQuad(texture: tex, size: pre.compSize)),
                                            effects: pre.effects)))
            case .group(let g):
                guard let tex = pool.acquire(width: w, height: h) else { continue }
                let sub = resolveTree(g.children, proj: proj, w: w, h: h, cmd: cmd, transient: &transient)
                encodeMain(sub, proj: proj, clear: SIMD4<Double>(0, 0, 0, 0), target: tex, cmd: cmd, transient: &transient)
                out.append(.group(texture: tex, opacity: g.opacity, effects: g.effects, blend: g.blendMode))
            case .matte(let m):
                guard let contentTex = pool.acquire(width: w, height: h),
                      let matteTex = pool.acquire(width: w, height: h),
                      let outTex = pool.acquire(width: w, height: h) else { continue }
                let cSub = resolveTree(m.content, proj: proj, w: w, h: h, cmd: cmd, transient: &transient)
                encodeMain(cSub, proj: proj, clear: SIMD4<Double>(0, 0, 0, 0), target: contentTex, cmd: cmd, transient: &transient)
                let mSub = resolveTree(m.matte, proj: proj, w: w, h: h, cmd: cmd, transient: &transient)
                encodeMain(mSub, proj: proj, clear: SIMD4<Double>(0, 0, 0, 0), target: matteTex, cmd: cmd, transient: &transient)
                applyMatte(content: contentTex, matte: matteTex, kind: m.kind, target: outTex, cmd: cmd)
                // The matted result composites fullscreen like a group.
                out.append(.group(texture: outTex, opacity: 1, effects: [], blend: .normal))
            }
        }
        return out
    }

    /// Mask `content` by `matte` (alpha or luminance, optionally inverted) into `target`.
    private func applyMatte(content: MTLTexture, matte: MTLTexture, kind: MatteKind,
                            target: MTLTexture, cmd: MTLCommandBuffer) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: clearedPass(target, .init(0, 0, 0, 0))) else { return }
        var k: UInt32 = { switch kind { case .alpha: 0; case .alphaInverted: 1; case .luma: 2; case .lumaInverted: 3 } }()
        enc.setRenderPipelineState(mattePipeline)
        enc.setFragmentTexture(content, index: 0)
        enc.setFragmentTexture(matte, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&k, length: MemoryLayout<UInt32>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// Encode effect/group pre-passes + the main pass for resolved nodes into `target`. Does not
    /// touch the pool's free list (caller owns frame lifetime), so it composes under `resolveTree`.
    private func encodeMain(_ nodes: [ResolvedNode], proj: simd_float3x3, clear: SIMD4<Double>,
                            target: MTLTexture, cmd: MTLCommandBuffer, transient: inout [MTLBuffer]) {
        let w = target.width, h = target.height

        // Phase 1: anything needing an intermediate (effected items, groups) → composite ops.
        var composites: [Int: [CompositeOp]] = [:]
        var backdrops: [Int: (content: MTLTexture, radius: Float, opacity: Float)] = [:]
        for (i, node) in nodes.enumerated() {
            switch node {
            case .item(let item) where !item.effects.isEmpty || item.blendMode != .normal:
                guard let content = renderContent(item, proj: proj, w: w, h: h, cmd: cmd, transient: &transient)
                else { break }
                if let radius = backgroundBlurRadius(item.effects) {
                    backdrops[i] = (content, radius, item.opacity)
                } else {
                    composites[i] = effectComposites(content: content, opacity: item.opacity,
                                                     effects: item.effects, blend: item.blendMode,
                                                     proj: proj, w: w, h: h, cmd: cmd)
                }
            case .group(let tex, let opacity, let effects, let blend):
                composites[i] = effectComposites(content: tex, opacity: opacity,
                                                 effects: effects, blend: blend, proj: proj, w: w, h: h, cmd: cmd)
            default:
                break
            }
        }

        // Phase 2: ordered main pass (direct items batched; effected items + groups → composites).
        var shapes: [InstanceUniform] = []
        var glyphs: [GlyphInstance] = []
        var ops: [DrawOp] = []
        var pendingShapeBase = 0
        var pendingShapeCount = 0
        func flushShapes() {
            if pendingShapeCount > 0 { ops.append(.shapes(base: pendingShapeBase, count: pendingShapeCount)); pendingShapeCount = 0 }
        }

        for (i, node) in nodes.enumerated() {
            if let cops = composites[i] {
                flushShapes()
                for c in cops { ops.append(.composite(c)) }
                continue
            }
            if let bd = backdrops[i] {
                flushShapes()
                ops.append(.backdrop(content: bd.content, radius: bd.radius, opacity: bd.opacity))
                continue
            }
            guard case .item(let item) = node else { continue }
            let clip = proj * item.world
            switch item.content {
            case .shape(let s):
                if let g = s.gradient { // gradient shapes bind their own LUT → can't batch
                    flushShapes()
                    let idx = shapes.count
                    shapes.append(shapeInstance(s, clip: clip, opacity: item.opacity))
                    ops.append(.gradientShape(base: idx, gradient: g))
                } else {
                    if pendingShapeCount == 0 { pendingShapeBase = shapes.count }
                    shapes.append(shapeInstance(s, clip: clip, opacity: item.opacity))
                    pendingShapeCount += 1
                }
            case .path(let meshes):
                flushShapes()
                for mesh in meshes {
                    if let buf = makeBuffer(mesh.vertices) {
                        transient.append(buf)
                        ops.append(.path(buffer: buf, count: mesh.vertices.count,
                                         uniform: PathUniform(clipFromLocal: clip, fill: mesh.fill, opacity: item.opacity),
                                         gradient: mesh.gradient))
                    }
                }
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

        // Own buffers per call: encodeMain runs once per intermediate + once top-level, all in one
        // command buffer, so a shared buffer would let a later upload corrupt an earlier pass.
        let shapeBuf = makeBuffer(shapes); if let b = shapeBuf { transient.append(b) }
        let glyphBuf = makeBuffer(glyphs); if let b = glyphBuf { transient.append(b) }

        guard let firstEnc = cmd.makeRenderCommandEncoder(descriptor: clearedPass(target, clear)) else { return }
        var enc = firstEnc // reassigned around backdrop ops, which must read the target mid-pass
        for op in ops {
            switch op {
            case .shapes(let base, let count):
                if let buf = shapeBuf { drawShapes(enc, buf, base: base, count: count) }
            case .gradientShape(let base, let gradient):
                if let buf = shapeBuf { drawShapes(enc, buf, base: base, count: 1, gradient: gradient) }
            case .path(let buffer, let count, let uniform, let gradient):
                drawPath(enc, buffer, count: count, uniform: uniform, gradient: gradient)
            case .glyphs(let base, let count, let texture):
                if let buf = glyphBuf { drawTextured(enc, glyphPipeline, buf, base: base, count: count, texture: texture) }
            case .image(let base, let texture):
                if let buf = glyphBuf { drawTextured(enc, imagePipeline, buf, base: base, count: 1, texture: texture) }
            case .composite(let c):
                drawComposite(enc, c)
            case .backdrop(let content, let radius, let opacity):
                // End the current pass so the target holds the backdrop, snapshot + blur it, then
                // composite the blur masked by the layer, and draw the layer content on top.
                enc.endEncoding()
                guard let snapshot = pool.acquire(width: w, height: h),
                      let next = encodeBackdropBlur(content: content, radius: radius, opacity: opacity,
                                                    target: target, snapshot: snapshot, w: w, h: h, cmd: cmd)
                else {
                    guard let resume = cmd.makeRenderCommandEncoder(descriptor: loadedPass(target)) else { return }
                    enc = resume; continue
                }
                enc = next
            }
        }
        enc.endEncoding()
    }

    /// Background-blur pass: blit the target into `snapshot`, blur it, then on a fresh load-encoder
    /// composite the blurred backdrop masked by `content`'s coverage and draw `content` over it.
    /// Returns the open encoder for the caller to continue drawing into.
    private func encodeBackdropBlur(content: MTLTexture, radius: Float, opacity: Float,
                                    target: MTLTexture, snapshot: MTLTexture, w: Int, h: Int,
                                    cmd: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: snapshot, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        let blurred = blur(snapshot, radius: radius, w: w, h: h, cmd: cmd)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: loadedPass(target)) else { return nil }
        // Masked blurred backdrop (over the sharp backdrop).
        enc.setRenderPipelineState(backdropPipeline)
        enc.setFragmentTexture(blurred, index: 0)
        enc.setFragmentTexture(content, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        // The layer's own content on top.
        drawComposite(enc, CompositeOp(texture: content, offsetNDC: .zero, tint: SIMD4<Float>(1, 1, 1, 1),
                                       opacity: opacity, mode: 0))
        return enc
    }

    private func backgroundBlurRadius(_ effects: [ResolvedEffect]) -> Float? {
        for e in effects { if case .backgroundBlur(let r) = e { return r } }
        return nil
    }

    private func loadedPass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    // MARK: Effect pre-passes

    /// Given a pre-rendered content texture, produce composite ops: shadows (blurred, tinted, offset,
    /// behind) then the content (blurred if a blur effect is present), faded by `opacity`. Shared by
    /// effected leaves and isolation groups.
    private func effectComposites(content: MTLTexture, opacity: Float, effects: [ResolvedEffect],
                                  blend: BlendMode, proj: simd_float3x3, w: Int, h: Int,
                                  cmd: MTLCommandBuffer) -> [CompositeOp] {
        var ops: [CompositeOp] = []
        for fx in effects {
            if case .shadow(let offset, let radius, let color, let shOpacity) = fx {
                let blurred = blur(content, radius: radius, w: w, h: h, cmd: cmd)
                let offNDC = SIMD2<Float>(offset.x * proj.columns.0.x, offset.y * proj.columns.1.y)
                ops.append(CompositeOp(texture: blurred, offsetNDC: offNDC, tint: color,
                                       opacity: shOpacity * opacity, mode: 1)) // shadow always over
            }
        }
        var result = content
        for fx in effects {
            if case .blur(let radius) = fx { result = blur(result, radius: radius, w: w, h: h, cmd: cmd) }
            if case .colorAdjust(let br, let ct, let sat, let hue) = fx {
                result = colorAdjust(result, params: ColorAdjustParams(brightness: br, contrast: ct, saturation: sat, hue: hue),
                                     w: w, h: h, cmd: cmd)
            }
        }
        // The layer's own composite carries its blend mode (the shadows behind it stay normal).
        ops.append(CompositeOp(texture: result, offsetNDC: .zero, tint: SIMD4<Float>(1, 1, 1, 1),
                               opacity: opacity, mode: 0, blend: blend))
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
                transient.append(buf); drawShapes(enc, buf, base: 0, count: 1, gradient: s.gradient)
            }
        case .path(let meshes):
            for mesh in meshes {
                if let buf = makeBuffer(mesh.vertices) {
                    transient.append(buf)
                    drawPath(enc, buf, count: mesh.vertices.count,
                             uniform: PathUniform(clipFromLocal: clip, fill: mesh.fill, opacity: 1),
                             gradient: mesh.gradient)
                }
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

    /// Color-adjust pass: one fullscreen draw sampling `src` → a new pooled texture.
    private func colorAdjust(_ src: MTLTexture, params: ColorAdjustParams, w: Int, h: Int,
                             cmd: MTLCommandBuffer) -> MTLTexture {
        guard let out = pool.acquire(width: w, height: h),
              let enc = cmd.makeRenderCommandEncoder(descriptor: clearedPass(out, .init(0, 0, 0, 0)))
        else { return src }
        var p = params
        enc.setRenderPipelineState(colorAdjustPipeline)
        enc.setFragmentBytes(&p, length: MemoryLayout<ColorAdjustParams>.stride, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
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

    private func drawShapes(_ enc: MTLRenderCommandEncoder, _ buf: MTLBuffer, base: Int, count: Int,
                            gradient: ResolvedGradient? = nil) {
        var b = UInt32(base)
        enc.setRenderPipelineState(shapePipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&b, length: 4, index: 1)
        enc.setFragmentBuffer(buf, offset: 0, index: 0)
        bindGradient(enc, gradient)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    private func drawPath(_ enc: MTLRenderCommandEncoder, _ buf: MTLBuffer, count: Int,
                          uniform: PathUniform, gradient: ResolvedGradient? = nil) {
        var u = uniform
        enc.setRenderPipelineState(pathPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<PathUniform>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PathUniform>.stride, index: 0)
        bindGradient(enc, gradient)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
    }

    /// Bind the gradient LUT + params at fragment slot 1 / texture 0 for the shape & path pipelines.
    /// A dummy LUT + `hasGradient == 0` is bound when there's no gradient (the fragment ignores it).
    private func bindGradient(_ enc: MTLRenderCommandEncoder, _ g: ResolvedGradient?) {
        var params = GradientParams()
        var lut = dummyLUT
        if let g {
            params = GradientParams(start: g.start, end: g.end, kind: g.kind, hasGradient: 1)
            lut = makeGradientLUT(g)
        }
        enc.setFragmentBytes(&params, length: MemoryLayout<GradientParams>.stride, index: 1)
        enc.setFragmentTexture(lut, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
    }

    /// Bake a gradient's stops into a 256×1 sRGB-encoded LUT (the fragment linearizes on sample).
    private func makeGradientLUT(_ g: ResolvedGradient) -> MTLTexture {
        let stops = g.stops.isEmpty
            ? [ResolvedGradient.Stop(position: 0, color: SIMD4<Float>(0, 0, 0, 1)),
               ResolvedGradient.Stop(position: 1, color: SIMD4<Float>(1, 1, 1, 1))]
            : g.stops.sorted { $0.position < $1.position }
        var colors = [SIMD4<Float>](); colors.reserveCapacity(256)
        for i in 0..<256 { colors.append(sampleStops(stops, Float(i) / 255)) }
        return makeLUT(colors)
    }

    private func sampleStops(_ stops: [ResolvedGradient.Stop], _ t: Float) -> SIMD4<Float> {
        guard let first = stops.first else { return SIMD4<Float>(0, 0, 0, 1) }
        if t <= first.position { return first.color }
        if t >= stops.last!.position { return stops.last!.color }
        for i in 1..<stops.count {
            let a = stops[i - 1], b = stops[i]
            if t <= b.position {
                let span = max(b.position - a.position, 1e-5)
                let f = (t - a.position) / span
                return a.color + (b.color - a.color) * f
            }
        }
        return stops.last!.color
    }

    /// A `colors.count`×1 RGBA8 texture holding sRGB-encoded bytes (clamp-sampled as a LUT).
    private func makeLUT(_ colors: [SIMD4<Float>]) -> MTLTexture {
        let w = max(colors.count, 1)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w,
                                                            height: 1, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        var bytes = [UInt8](repeating: 0, count: w * 4)
        for (i, c) in colors.enumerated() {
            bytes[i * 4 + 0] = UInt8(max(0, min(1, c.x)) * 255)
            bytes[i * 4 + 1] = UInt8(max(0, min(1, c.y)) * 255)
            bytes[i * 4 + 2] = UInt8(max(0, min(1, c.z)) * 255)
            bytes[i * 4 + 3] = UInt8(max(0, min(1, c.w)) * 255)
        }
        bytes.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, 1), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: w * 4)
        }
        return tex
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
        enc.setRenderPipelineState(blendPipelines[c.blend] ?? compositePipeline) // normal → over
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
        // sRGB targets sRGB-encode on store, so the clear value must be given in linear space to end
        // up as the intended sRGB color (the clear comes in sRGB-encoded, like every ColorValue).
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Self.srgbToLinear(clear.x), green: Self.srgbToLinear(clear.y),
            blue: Self.srgbToLinear(clear.z), alpha: clear.w)
        return pass
    }

    /// sRGB → linear for a single channel (matches the shader's `srgbToLinear`).
    private static func srgbToLinear(_ c: Double) -> Double {
        c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
    }
}
#endif
