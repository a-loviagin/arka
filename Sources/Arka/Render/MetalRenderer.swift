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
final class MetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let shapePipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var shapeBuffer = GrowableBuffer<InstanceUniform>()
    private var glyphBuffer = GrowableBuffer<GlyphInstance>()

    enum SetupError: Error { case noQueue, noLibrary }

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SetupError.noQueue }
        self.queue = queue

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: ShaderSource.metal, options: nil) }
        catch { throw SetupError.noLibrary }

        func pipeline(_ vfn: String, _ ffn: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vfn)
            desc.fragmentFunction = library.makeFunction(name: ffn)
            let c = desc.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
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

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear
        sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge
        sdesc.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sdesc)!
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
    }

    /// Draw a RenderTree into a drawable. `clear` is sRGB-encoded rgba (the comp background).
    func draw(items: [RenderItem], compSize: SIMD2<Float>, viewport: SIMD2<Float>,
              clear: SIMD4<Double>, to drawable: CAMetalDrawable) {
        let proj = projection(compSize: compSize, viewport: viewport)

        // Flatten the ordered RenderTree into two instance arrays + an ordered op list, batching
        // consecutive shapes into one instanced draw and flushing on each glyph run.
        var shapes: [InstanceUniform] = []
        var glyphs: [GlyphInstance] = []
        var ops: [DrawOp] = []
        var pendingShapeBase = 0
        var pendingShapeCount = 0

        func flushShapes() {
            if pendingShapeCount > 0 {
                ops.append(.shapes(base: pendingShapeBase, count: pendingShapeCount))
                pendingShapeCount = 0
            }
        }

        for item in items {
            let clipFromLocal = proj * item.world
            switch item.content {
            case .shape(let s):
                if pendingShapeCount == 0 { pendingShapeBase = shapes.count }
                shapes.append(InstanceUniform(
                    clipFromLocal: clipFromLocal, fill: s.fill, stroke: s.stroke,
                    size: s.size, cornerRadius: s.cornerRadius, strokeWidth: s.strokeWidth,
                    kind: s.kind.rawValue, opacity: item.opacity))
                pendingShapeCount += 1
            case .glyphRun(let run):
                flushShapes()
                let base = glyphs.count
                for g in run.glyphs {
                    glyphs.append(GlyphInstance(
                        clipFromLocal: clipFromLocal, localOrigin: g.localOrigin,
                        localSize: g.localSize, uvOrigin: g.uvOrigin, uvSize: g.uvSize,
                        tint: run.fill, opacity: item.opacity))
                }
                if glyphs.count > base {
                    ops.append(.glyphs(base: base, count: glyphs.count - base, texture: run.atlas))
                }
            }
        }
        flushShapes()

        shapeBuffer.upload(shapes, device: device)
        glyphBuffer.upload(glyphs, device: device)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: clear.x, green: clear.y,
                                                            blue: clear.z, alpha: clear.w)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        for op in ops {
            switch op {
            case .shapes(let base, let count):
                guard let buf = shapeBuffer.buffer else { continue }
                var b = UInt32(base)
                enc.setRenderPipelineState(shapePipeline)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&b, length: 4, index: 1)
                enc.setFragmentBuffer(buf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: count)
            case .glyphs(let base, let count, let texture):
                guard let buf = glyphBuffer.buffer else { continue }
                var b = UInt32(base)
                enc.setRenderPipelineState(glyphPipeline)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setVertexBytes(&b, length: 4, index: 1)
                enc.setFragmentBuffer(buf, offset: 0, index: 0)
                enc.setFragmentTexture(texture, index: 0)
                enc.setFragmentSamplerState(sampler, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: count)
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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
