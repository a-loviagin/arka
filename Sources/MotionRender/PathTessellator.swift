#if os(macOS)
import Foundation
import simd
import MotionKernel

/// Triangulated fill for a vector path, in layer-local points (origin top-left). v1: flatten each
/// cubic-bezier subpath to a polyline, then ear-clip triangulate each subpath independently (no
/// even-odd holes yet). Output is a flat triangle list the renderer uploads as a vertex buffer.
struct PathMesh {
    var vertices: [SIMD2<Float>]   // 3 per triangle
    var fill: SIMD4<Float>         // straight sRGB rgba (premultiplied in the shader)
}

enum PathTessellator {
    /// Subdivisions per cubic segment when flattening. Fixed (not adaptive) — fine at these sizes.
    static let segmentSteps = 24

    static func mesh(_ path: PathData, fill: SIMD4<Float>) -> PathMesh? {
        var tris: [SIMD2<Float>] = []
        for sub in path.subpaths {
            let contour = flatten(sub)
            guard contour.count >= 3 else { continue }
            tris.append(contentsOf: earClip(contour))
        }
        guard !tris.isEmpty else { return nil }
        return PathMesh(vertices: tris, fill: fill)
    }

    // MARK: Flatten

    /// Flatten a subpath to a closed polyline of points (layer-local). Open subpaths are treated as
    /// closed for filling (their implied closing segment is added).
    private static func flatten(_ sub: PathData.Subpath) -> [SIMD2<Float>] {
        let vs = sub.vertices
        guard vs.count >= 2 else { return vs.map(point) }
        var out: [SIMD2<Float>] = []
        for i in 0..<vs.count {
            let isLast = (i == vs.count - 1)
            if isLast && !sub.closed { break }
            let a = vs[i]
            let b = vs[(i + 1) % vs.count]
            appendCubic(&out, a: a, b: b, includeStart: out.isEmpty)
        }
        return dedup(out)
    }

    private static func appendCubic(_ out: inout [SIMD2<Float>], a: PathData.Vertex,
                                    b: PathData.Vertex, includeStart: Bool) {
        let p0 = point(a)
        let p3 = point(b)
        if includeStart { out.append(p0) }
        // A segment with no handles is a straight line — one point, no subdivision.
        if a.outTangent == .zero && b.inTangent == .zero {
            out.append(p3)
            return
        }
        let p1 = p0 + vec(a.outTangent)
        let p2 = p3 + vec(b.inTangent)
        for s in 1...segmentSteps {
            let t = Float(s) / Float(segmentSteps)
            out.append(cubic(p0, p1, p2, p3, t))
        }
    }

    private static func cubic(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>,
                              _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        let u = 1 - t
        return u*u*u*p0 + 3*u*u*t*p1 + 3*u*t*t*p2 + t*t*t*p3
    }

    private static func dedup(_ pts: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for p in pts where out.last.map({ simd_distance($0, p) > 1e-4 }) ?? true { out.append(p) }
        // Drop a duplicated wrap-around endpoint.
        if out.count > 1, simd_distance(out.first!, out.last!) < 1e-4 { out.removeLast() }
        return out
    }

    // MARK: Ear clipping

    /// Triangulate a simple polygon (CCW or CW) into a triangle list. Robust enough for the convex
    /// and mildly-concave outlines paths produce; degenerate input yields fewer triangles, never a crash.
    private static func earClip(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var poly = polygon
        if signedArea(poly) < 0 { poly.reverse() } // force CCW (positive area)
        var indices = Array(poly.indices)
        var tris: [SIMD2<Float>] = []
        var guardCount = 0
        let maxIter = poly.count * poly.count + 8

        while indices.count > 3 && guardCount < maxIter {
            guardCount += 1
            var clipped = false
            for k in indices.indices {
                let i0 = indices[(k + indices.count - 1) % indices.count]
                let i1 = indices[k]
                let i2 = indices[(k + 1) % indices.count]
                let a = poly[i0], b = poly[i1], c = poly[i2]
                if cross(b - a, c - a) <= 0 { continue } // reflex (CCW) — not an ear tip
                if indices.contains(where: { idx in
                    idx != i0 && idx != i1 && idx != i2 && pointInTriangle(poly[idx], a, b, c)
                }) { continue }
                tris.append(contentsOf: [a, b, c])
                indices.remove(at: k)
                clipped = true
                break
            }
            if !clipped { break } // not a simple polygon — stop with what we have
        }
        if indices.count == 3 {
            tris.append(contentsOf: indices.map { poly[$0] })
        }
        return tris
    }

    private static func signedArea(_ p: [SIMD2<Float>]) -> Float {
        var a: Float = 0
        for i in 0..<p.count {
            let j = (i + 1) % p.count
            a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return a / 2
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

    private static func pointInTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>,
                                        _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        let d1 = cross(p - a, b - a)
        let d2 = cross(p - b, c - b)
        let d3 = cross(p - c, a - c)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }

    private static func point(_ v: PathData.Vertex) -> SIMD2<Float> {
        SIMD2<Float>(Float(v.point.x), Float(v.point.y))
    }
    private static func vec(_ v: Vec2) -> SIMD2<Float> { SIMD2<Float>(Float(v.x), Float(v.y)) }
}
#endif
