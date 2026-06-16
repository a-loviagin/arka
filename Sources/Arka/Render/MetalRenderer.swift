#if os(macOS)
import Foundation
import Metal
import QuartzCore
import simd

/// Per-instance shape data. **Layout must match `InstanceUniform` in Shaders.metal exactly.**
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

/// The GPU half of the engine (render-engine.md §1-2). Consumes a RenderTree (resolved draw items)
/// and draws instanced SDF shapes into a `CAMetalLayer` drawable. Knows nothing about the document.
///
/// v1 simplifications vs. the spec target: draws straight into an sRGB drawable rather than fp16
/// linear working targets + EDR (render-engine.md §4) — correct-looking pixels now; the linear
/// pipeline is a later upgrade behind this same interface.
final class MetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var instanceBuffer: MTLBuffer?
    private var instanceCapacity = 0

    enum SetupError: Error { case noDevice, noLibrary, noQueue }

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SetupError.noQueue }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        } catch {
            throw SetupError.noLibrary
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "shape_vertex")
        desc.fragmentFunction = library.makeFunction(name: "shape_fragment")
        let color = desc.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        // Pre-multiplied "over" blending.
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
    }

    /// Column-major comp→NDC projection, aspect-fit and centered into the drawable (comp is y-down,
    /// 0…W × 0…H; NDC is y-up). Letterboxes when comp and viewport aspects differ.
    private func projection(compSize: SIMD2<Float>, viewport: SIMD2<Float>) -> simd_float3x3 {
        let cw = max(compSize.x, 1), ch = max(compSize.y, 1)
        let vw = max(viewport.x, 1), vh = max(viewport.y, 1)
        let scale = min(vw / cw, vh / ch)
        let ox = (vw - cw * scale) / 2
        let oy = (vh - ch * scale) / 2
        // comp (cx,cy) → pixel (ox + cx*scale, oy + cy*scale) → NDC (2*px/vw - 1, 1 - 2*py/vh).
        // Compose directly into a column-major 3x3.
        let sx = 2 * scale / vw
        let sy = -2 * scale / vh
        let tx = 2 * ox / vw - 1
        let ty = 1 - 2 * oy / vh
        return simd_float3x3(
            SIMD3<Float>(sx, 0, 0),
            SIMD3<Float>(0, sy, 0),
            SIMD3<Float>(tx, ty, 1)
        )
    }

    private func ensureInstanceCapacity(_ count: Int) {
        guard count > instanceCapacity else { return }
        let newCap = max(count, instanceCapacity * 2, 64)
        instanceBuffer = device.makeBuffer(length: newCap * MemoryLayout<InstanceUniform>.stride,
                                           options: .storageModeShared)
        instanceCapacity = newCap
    }

    /// Draw a RenderTree into a drawable. `clear` is sRGB-encoded rgba (the comp background).
    func draw(items: [RenderItem], compSize: SIMD2<Float>, viewport: SIMD2<Float>,
              clear: SIMD4<Double>, to drawable: CAMetalDrawable) {
        let proj = projection(compSize: compSize, viewport: viewport)

        ensureInstanceCapacity(items.count)
        if let buffer = instanceBuffer, !items.isEmpty {
            let ptr = buffer.contents().bindMemory(to: InstanceUniform.self, capacity: items.count)
            for (i, item) in items.enumerated() {
                ptr[i] = InstanceUniform(
                    clipFromLocal: proj * item.world,
                    fill: item.shape.fill,
                    stroke: item.shape.stroke,
                    size: item.shape.size,
                    cornerRadius: item.shape.cornerRadius,
                    strokeWidth: item.shape.strokeWidth,
                    kind: item.shape.kind.rawValue,
                    opacity: item.opacity
                )
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: clear.x, green: clear.y,
                                                            blue: clear.z, alpha: clear.w)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if !items.isEmpty, let buffer = instanceBuffer {
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setFragmentBuffer(buffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: items.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
#endif
