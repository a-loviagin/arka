#if os(macOS)
import Foundation
import Metal

/// A pool of offscreen render-target textures, size-bucketed and reused across frames
/// (render-engine.md §3: "allocate intermediates from a texture pool ... zero steady-state
/// allocation during playback"). Acquire during a frame; `releaseAll()` at frame end returns
/// everything to the free list for reuse next frame.
final class IntermediatePool {
    private let device: MTLDevice
    private struct Key: Hashable { let w: Int; let h: Int }
    private var free: [Key: [MTLTexture]] = [:]
    private var inUse: [(Key, MTLTexture)] = []

    init(device: MTLDevice) { self.device = device }

    func acquire(width: Int, height: Int) -> MTLTexture? {
        let key = Key(w: width, h: height)
        let texture: MTLTexture
        if var bucket = free[key], let reused = bucket.popLast() {
            free[key] = bucket
            texture = reused
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let t = device.makeTexture(descriptor: desc) else { return nil }
            texture = t
        }
        inUse.append((key, texture))
        return texture
    }

    func releaseAll() {
        for (key, texture) in inUse {
            free[key, default: []].append(texture)
        }
        inUse.removeAll(keepingCapacity: true)
    }
}
#endif
