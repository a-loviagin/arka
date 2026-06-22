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
    /// Trim span in normalized arc length: `start`/`end` in 0…1, `offset` rotates the span (wraps on
    /// closed paths). `nil` = the whole path.
    struct Trim: Equatable { var start: Double; var end: Double; var offset: Double }

    static func mesh(_ path: PathData, width: Float, color: SIMD4<Float>, trim: Trim? = nil) -> PathMesh? {
        guard width > 0, color.w > 0.001 else { return nil }
        // A degenerate trim (start ≥ end after clamping) draws nothing.
        if let tr = trim, min(tr.end, 1) - max(tr.start, 0) <= 1e-6, tr.end <= 1, tr.start >= 0 { return nil }
        let half = width / 2
        var tris: [SIMD2<Float>] = []
        for sub in path.subpaths {
            let pts = PathTessellator.flatten(sub)
            guard pts.count >= 2 else { continue }
            if let tr = trim, !isFullTrim(tr) {
                for piece in trimmedPolylines(pts, closed: sub.closed, trim: tr) where piece.count >= 2 {
                    tris.append(contentsOf: ribbon(piece, closed: false, half: half)) // trimmed pieces are open
                }
            } else {
                tris.append(contentsOf: ribbon(pts, closed: sub.closed, half: half))
            }
        }
        guard !tris.isEmpty else { return nil }
        return PathMesh(vertices: tris, fill: color)
    }

    private static func isFullTrim(_ t: Trim) -> Bool {
        abs(t.start) < 1e-6 && abs(t.end - 1) < 1e-6 && abs(t.offset.truncatingRemainder(dividingBy: 1)) < 1e-6
    }

    /// Extract the trimmed portion(s) of a polyline by arc length. A closed path whose span wraps
    /// past the seam returns two open pieces; everything else returns one.
    static func trimmedPolylines(_ pts: [SIMD2<Float>], closed: Bool, trim: Trim) -> [[SIMD2<Float>]] {
        // Segment list with lengths (closed wraps last→first).
        let n = pts.count
        var segs: [(a: Int, b: Int, len: Float)] = []
        var total: Float = 0
        let count = closed ? n : n - 1
        for i in 0..<count {
            let a = i, b = (i + 1) % n
            let len = simd_distance(pts[a], pts[b])
            if len > 1e-6 { segs.append((a, b, len)); total += len }
        }
        guard total > 1e-6 else { return [] }

        let span = max(min(trim.end, 1) - max(trim.start, 0), 0)
        if span <= 1e-6 { return [] }
        if closed {
            var a = (trim.start + trim.offset).truncatingRemainder(dividingBy: 1)
            if a < 0 { a += 1 }
            let b = a + span // may exceed 1 → wraps the seam
            if b <= 1 {
                return [arcSlice(pts, segs, from: Float(a) * total, to: Float(b) * total)]
            }
            return [arcSlice(pts, segs, from: Float(a) * total, to: total),
                    arcSlice(pts, segs, from: 0, to: Float(b - 1) * total)]
        } else {
            let a = max(min(trim.start + trim.offset, 1), 0)
            let b = max(min(trim.end + trim.offset, 1), 0)
            guard b > a else { return [] }
            return [arcSlice(pts, segs, from: Float(a) * total, to: Float(b) * total)]
        }
    }

    /// Walk the segment list, emitting the contiguous polyline covering arc lengths [from, to].
    private static func arcSlice(_ pts: [SIMD2<Float>], _ segs: [(a: Int, b: Int, len: Float)],
                                 from: Float, to: Float) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        var acc: Float = 0
        for s in segs {
            let segStart = acc, segEnd = acc + s.len
            if segEnd >= from && segStart <= to {
                let t0 = min(max((from - segStart) / s.len, 0), 1)
                let t1 = min(max((to - segStart) / s.len, 0), 1)
                let p0 = mix(pts[s.a], pts[s.b], t: t0)
                let p1 = mix(pts[s.a], pts[s.b], t: t1)
                if out.isEmpty { out.append(p0) }
                out.append(p1)
            }
            acc = segEnd
        }
        return out
    }

    private static func mix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, t: Float) -> SIMD2<Float> {
        a + (b - a) * t
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
