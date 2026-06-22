#if os(macOS)
import Foundation
import simd
import MotionKernel

/// Triangulated *stroke* (outline) for a vector path, in layer-local points — the companion to
/// `PathTessellator`'s fill (properties-and-commands.md §1, Tier 2). Each subpath's flattened
/// polyline becomes a constant-width ribbon: per-vertex miter offsets (clamped so sharp corners
/// don't spike), two triangles per segment. Butt caps / miter joins for v1; round joins are a
/// follow-up. Output is a flat triangle list drawn through the same path pipeline as the fill.
enum PathStroker {
    static func mesh(_ path: PathData, width: Float, color: SIMD4<Float>) -> PathMesh? {
        guard width > 0, color.w > 0.001 else { return nil }
        let half = width / 2
        var tris: [SIMD2<Float>] = []
        for sub in path.subpaths {
            let pts = PathTessellator.flatten(sub)
            guard pts.count >= 2 else { continue }
            tris.append(contentsOf: ribbon(pts, closed: sub.closed, half: half))
        }
        guard !tris.isEmpty else { return nil }
        return PathMesh(vertices: tris, fill: color)
    }

    /// A constant-width ribbon around a polyline. `closed` wraps the last→first segment.
    static func ribbon(_ p: [SIMD2<Float>], closed: Bool, half: Float) -> [SIMD2<Float>] {
        let n = p.count
        guard n >= 2 else { return [] }
        func segNormal(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            let d = b - a
            let len = simd_length(d)
            guard len > 1e-6 else { return SIMD2<Float>(0, 1) }
            let u = d / len
            return SIMD2<Float>(-u.y, u.x) // left normal (y-down space)
        }
        var left = [SIMD2<Float>](), right = [SIMD2<Float>]()
        left.reserveCapacity(n); right.reserveCapacity(n)
        for i in 0..<n {
            let prevN: SIMD2<Float>? = i > 0 ? segNormal(p[i - 1], p[i])
                                             : (closed ? segNormal(p[n - 1], p[0]) : nil)
            let nextN: SIMD2<Float>? = i < n - 1 ? segNormal(p[i], p[i + 1])
                                                 : (closed ? segNormal(p[n - 1], p[0]) : nil)
            var normal = SIMD2<Float>(0, 1)
            var scale: Float = 1
            switch (prevN, nextN) {
            case let (a?, b?):
                var m = a + b
                let len = simd_length(m)
                if len < 1e-4 { normal = b } else {
                    m /= len
                    normal = m
                    scale = min(1 / max(simd_dot(m, b), 0.2), 4) // miter, clamped
                }
            case let (a?, nil): normal = a
            case let (nil, b?): normal = b
            default: break
            }
            left.append(p[i] + normal * (half * scale))
            right.append(p[i] - normal * (half * scale))
        }
        var tris: [SIMD2<Float>] = []
        let segs = closed ? n : n - 1
        for i in 0..<segs {
            let j = (i + 1) % n
            tris += [left[i], right[i], left[j], right[i], right[j], left[j]]
        }
        return tris
    }
}
#endif
