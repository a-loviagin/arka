import Foundation

/// Parses an SVG `d` path-data string into our `PathData` (cubic-bezier subpaths) — so imported
/// vectors become *editable* shape layers, not rasterized images. Foundation-only and deterministic.
///
/// Supports M/m L/l H/h V/v C/c S/s Q/q T/t Z/z (absolute + relative). Quadratics are exactly raised
/// to cubics; S/T reflect the previous control point. Elliptical arcs (A/a) are approximated by a
/// line to the endpoint for v1 (rare in icon/logo exports; noted as a follow-up).
public enum SVGPathParser {
    public static func parse(_ d: String) -> [PathData.Subpath] {
        var tokens = Tokenizer(d)
        var subpaths: [PathData.Subpath] = []
        var verts: [Builder] = []
        var cur = Vec2.zero, start = Vec2.zero
        var lastCubicCtrl: Vec2?   // for S
        var lastQuadCtrl: Vec2?    // for T
        var cmd: Character = " "

        func flush(closed: Bool) {
            guard verts.count >= 1 else { verts = []; return }
            subpaths.append(PathData.Subpath(vertices: verts.map(\.vertex), closed: closed))
            verts = []
        }
        func lineTo(_ p: Vec2) { verts.append(Builder(point: p)); cur = p; lastCubicCtrl = nil; lastQuadCtrl = nil }
        func cubicTo(_ c1: Vec2, _ c2: Vec2, _ p: Vec2) {
            if !verts.isEmpty { verts[verts.count - 1].outAbs = c1 }
            verts.append(Builder(point: p, inAbs: c2)); cur = p; lastCubicCtrl = c2; lastQuadCtrl = nil
        }
        func quadTo(_ c: Vec2, _ p: Vec2) {
            let c1 = cur + (c - cur) * (2.0 / 3.0)
            let c2 = p + (c - p) * (2.0 / 3.0)
            cubicTo(c1, c2, p); lastQuadCtrl = c; lastCubicCtrl = nil
        }

        while let tok = tokens.next() {
            if case .command(let c) = tok { cmd = c; if c == "Z" || c == "z" {
                flush(closed: true); cur = start; continue
            } } else { tokens.pushBack(tok) }

            let rel = cmd.isLowercase
            func num() -> Double? { if case .number(let v)? = tokens.next() { return v }; return nil }
            func pt() -> Vec2? { guard let x = num(), let y = num() else { return nil }
                                 return rel ? cur + Vec2(x, y) : Vec2(x, y) }

            switch cmd.uppercased() {
            case "M":
                guard let p = pt() else { return finish(subpaths, verts) }
                flush(closed: false)
                verts = [Builder(point: p)]; cur = p; start = p
                cmd = rel ? "l" : "L" // subsequent implicit pairs are lineto
            case "L":
                guard let p = pt() else { break }; lineTo(p)
            case "H":
                guard let x = num() else { break }; lineTo(Vec2(rel ? cur.x + x : x, cur.y))
            case "V":
                guard let y = num() else { break }; lineTo(Vec2(cur.x, rel ? cur.y + y : y))
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { break }; cubicTo(c1, c2, p)
            case "S":
                guard let c2 = pt(), let p = pt() else { break }
                let c1 = lastCubicCtrl.map { cur + (cur - $0) } ?? cur
                cubicTo(c1, c2, p)
            case "Q":
                guard let c = pt(), let p = pt() else { break }; quadTo(c, p)
            case "T":
                guard let p = pt() else { break }
                let c = lastQuadCtrl.map { cur + (cur - $0) } ?? cur
                quadTo(c, p)
            case "A":
                // Approximate: consume rx ry rot large sweep x y, line to endpoint.
                _ = num(); _ = num(); _ = num(); _ = num(); _ = num()
                guard let p = pt() else { break }; lineTo(p)
            default:
                _ = num() // unknown command param — skip a token to avoid spinning
            }
        }
        flush(closed: false)
        return subpaths
    }

    private static func finish(_ subs: [PathData.Subpath], _ verts: [Builder]) -> [PathData.Subpath] {
        var s = subs
        if !verts.isEmpty { s.append(PathData.Subpath(vertices: verts.map(\.vertex), closed: false)) }
        return s
    }

    /// A vertex whose handles are accumulated as absolute control points, converted to point-relative
    /// tangents (our schema) on build.
    private struct Builder {
        var point: Vec2
        var inAbs: Vec2?
        var outAbs: Vec2?
        var vertex: PathData.Vertex {
            PathData.Vertex(point: point,
                            inTangent: inAbs.map { $0 - point } ?? .zero,
                            outTangent: outAbs.map { $0 - point } ?? .zero)
        }
    }

    private enum Token { case command(Character); case number(Double) }

    /// Hand-rolled scanner: SVG path data separates tokens by whitespace/commas, lets a sign or a
    /// second decimal point start a new number, and uses single letters as commands.
    private struct Tokenizer {
        private let chars: [Character]
        private var i = 0
        private var pushed: Token?
        init(_ s: String) { chars = Array(s) }

        mutating func pushBack(_ t: Token) { pushed = t }

        mutating func next() -> Token? {
            if let p = pushed { pushed = nil; return p }
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter { i += 1; return .command(c) }
            return scanNumber()
        }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n"
                  || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        }

        private mutating func scanNumber() -> Token? {
            var s = ""
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
            var seenDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c); i += 1 }
                else if c == "." { if seenDot { break }; seenDot = true; s.append(c); i += 1 }
                else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < chars.count, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
                } else { break }
            }
            guard let v = Double(s) else { return nil }
            return .number(v)
        }
    }
}
