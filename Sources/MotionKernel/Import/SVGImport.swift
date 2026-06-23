import Foundation

/// Extracts drawable shapes from an SVG document — `<path>` plus the basic primitives (rect, circle,
/// ellipse, line, polyline, polygon) — converts each to editable `PathData`, applies any element
/// `transform`, and reads its fill. Foundation-only. (Grouped `<g transform>`, gradients, and CSS
/// stylesheets are a follow-up; per-element transforms cover most exports.)
public enum SVGImport {
    public struct Shape: Sendable, Equatable {
        public let path: PathData
        public let fill: ColorValue?   // nil = no fill ("none")
    }

    private static let kappa = 0.5522847498307936

    public static func shapes(fromSVG text: String) -> [Shape] {
        let elements = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]
        var shapes: [Shape] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "<" else { i += 1; continue }
            // Read the element name.
            var k = i + 1
            var name = ""
            while k < chars.count, chars[k].isLetter { name.append(chars[k]); k += 1 }
            guard elements.contains(name) else { i += 1; continue }
            // The tag runs to '>'.
            var j = k
            while j < chars.count, chars[j] != ">" { j += 1 }
            let tag = String(chars[i..<min(j, chars.count)])
            i = min(j + 1, chars.count)

            guard var subs = subpaths(name: name, tag: tag), !subs.isEmpty else { continue }
            if let tf = attribute("transform", in: tag), let m = Transform2D(svg: tf) {
                subs = subs.map { m.apply(to: $0) }
            }
            shapes.append(Shape(path: PathData(subpaths: subs), fill: fill(in: tag)))
        }
        return shapes
    }

    // MARK: Element → subpaths

    private static func subpaths(name: String, tag: String) -> [PathData.Subpath]? {
        func n(_ a: String) -> Double { Double(attribute(a, in: tag) ?? "") ?? 0 }
        switch name {
        case "path":
            guard let d = attribute("d", in: tag) else { return nil }
            return SVGPathParser.parse(d)
        case "rect":
            let x = n("x"), y = n("y"), w = n("width"), h = n("height")
            guard w > 0, h > 0 else { return nil }
            return [closedPolygon([Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)])]
        case "circle":
            let r = n("r"); guard r > 0 else { return nil }
            return [ellipse(cx: n("cx"), cy: n("cy"), rx: r, ry: r)]
        case "ellipse":
            let rx = n("rx"), ry = n("ry"); guard rx > 0, ry > 0 else { return nil }
            return [ellipse(cx: n("cx"), cy: n("cy"), rx: rx, ry: ry)]
        case "line":
            return [PathData.Subpath(vertices: [PathData.Vertex(point: Vec2(n("x1"), n("y1"))),
                                                PathData.Vertex(point: Vec2(n("x2"), n("y2")))], closed: false)]
        case "polyline", "polygon":
            let pts = points(attribute("points", in: tag) ?? "")
            guard pts.count >= 2 else { return nil }
            return [PathData.Subpath(vertices: pts.map { PathData.Vertex(point: $0) }, closed: name == "polygon")]
        default:
            return nil
        }
    }

    private static func closedPolygon(_ pts: [Vec2]) -> PathData.Subpath {
        PathData.Subpath(vertices: pts.map { PathData.Vertex(point: $0) }, closed: true)
    }

    private static func ellipse(cx: Double, cy: Double, rx: Double, ry: Double) -> PathData.Subpath {
        let kx = rx * kappa, ky = ry * kappa
        return PathData.Subpath(vertices: [
            PathData.Vertex(point: Vec2(cx + rx, cy), inTangent: Vec2(0, -ky), outTangent: Vec2(0, ky)),
            PathData.Vertex(point: Vec2(cx, cy + ry), inTangent: Vec2(kx, 0), outTangent: Vec2(-kx, 0)),
            PathData.Vertex(point: Vec2(cx - rx, cy), inTangent: Vec2(0, ky), outTangent: Vec2(0, -ky)),
            PathData.Vertex(point: Vec2(cx, cy - ry), inTangent: Vec2(-kx, 0), outTangent: Vec2(kx, 0)),
        ], closed: true)
    }

    private static func points(_ s: String) -> [Vec2] {
        let nums = s.split { !"-+.eE0123456789".contains($0) }.compactMap { Double($0) }
        var out: [Vec2] = []
        var i = 0
        while i + 1 < nums.count { out.append(Vec2(nums[i], nums[i + 1])); i += 2 }
        return out
    }

    // MARK: Attribute scanning

    private static func range(of needle: String, in chars: [Character], from: Int) -> Range<Int>? {
        let nd = Array(needle)
        var i = from
        while i + nd.count <= chars.count {
            if Array(chars[i..<i + nd.count]) == nd { return i..<(i + nd.count) }
            i += 1
        }
        return nil
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let chars = Array(tag)
        var search = 0
        while let r = range(of: name, in: chars, from: search) {
            var k = r.upperBound
            while k < chars.count, chars[k] == " " { k += 1 }
            guard k < chars.count, chars[k] == "=" else { search = r.upperBound; continue }
            k += 1
            while k < chars.count, chars[k] == " " { k += 1 }
            guard k < chars.count, chars[k] == "\"" || chars[k] == "'" else { search = r.upperBound; continue }
            let quote = chars[k]; k += 1
            var value = ""
            while k < chars.count, chars[k] != quote { value.append(chars[k]); k += 1 }
            return value
        }
        return nil
    }

    static func fill(in tag: String) -> ColorValue? {
        var raw = attribute("fill", in: tag)
        if raw == nil, let style = attribute("style", in: tag) {
            for decl in style.split(separator: ";") {
                let kv = decl.split(separator: ":", maxSplits: 1)
                if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "fill" {
                    raw = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased() else { return .black }
        switch value {
        case "none", "transparent": return nil
        case "black": return .black
        case "white": return .white
        default: return ColorValue(hex: value) ?? .black
        }
    }
}

/// A 2-D affine `[a c e; b d f]` parsed from an SVG `transform` list and applied to path geometry.
struct Transform2D {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    func point(_ p: Vec2) -> Vec2 { Vec2(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }
    func vector(_ v: Vec2) -> Vec2 { Vec2(a * v.x + c * v.y, b * v.x + d * v.y) } // no translation for tangents

    func apply(to sub: PathData.Subpath) -> PathData.Subpath {
        PathData.Subpath(vertices: sub.vertices.map {
            PathData.Vertex(point: point($0.point), inTangent: vector($0.inTangent), outTangent: vector($0.outTangent))
        }, closed: sub.closed)
    }

    func concat(_ m: Transform2D) -> Transform2D {
        Transform2D(a: a * m.a + c * m.b, b: b * m.a + d * m.b,
                    c: a * m.c + c * m.d, d: b * m.c + d * m.d,
                    e: a * m.e + c * m.f + e, f: b * m.e + d * m.f + f)
    }

    init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, e: Double = 0, f: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    /// Parse `translate(...) scale(...) rotate(...) matrix(...) skewX/Y(...)`, composed left→right.
    init?(svg: String) {
        var result = Transform2D()
        let chars = Array(svg)
        var i = 0
        var found = false
        while i < chars.count {
            while i < chars.count, !chars[i].isLetter { i += 1 }
            var name = ""
            while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
            guard i < chars.count, chars[i] == "(" else { break }
            i += 1
            var args = ""
            while i < chars.count, chars[i] != ")" { args.append(chars[i]); i += 1 }
            if i < chars.count { i += 1 } // ')'
            let v = args.split { !"-+.eE0123456789".contains($0) }.compactMap { Double($0) }
            let m: Transform2D
            switch name.lowercased() {
            case "translate": m = Transform2D(e: v.first ?? 0, f: v.count > 1 ? v[1] : 0)
            case "scale": m = Transform2D(a: v.first ?? 1, d: v.count > 1 ? v[1] : (v.first ?? 1))
            case "rotate":
                let r = (v.first ?? 0) * .pi / 180, cs = cos(r), sn = sin(r)
                var rot = Transform2D(a: cs, b: sn, c: -sn, d: cs)
                if v.count >= 3 { // rotate around (cx,cy)
                    rot = Transform2D(e: v[1], f: v[2]).concat(rot).concat(Transform2D(e: -v[1], f: -v[2]))
                }
                m = rot
            case "matrix":
                guard v.count >= 6 else { continue }
                m = Transform2D(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
            case "skewx": m = Transform2D(c: tan((v.first ?? 0) * .pi / 180))
            case "skewy": m = Transform2D(b: tan((v.first ?? 0) * .pi / 180))
            default: continue
            }
            result = result.concat(m); found = true
        }
        guard found else { return nil }
        self = result
    }
}
