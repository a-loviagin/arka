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
                guard let rx = num(), let ry = num(), let rot = num(),
                      let large = tokens.nextFlag(), let sweep = tokens.nextFlag(),
                      let p = pt() else { break }
                let segs = arcToCubics(from: cur, rx: rx, ry: ry, rotDeg: rot,
                                       largeArc: large != 0, sweep: sweep != 0, to: p)
                if segs.isEmpty { lineTo(p) } else { for s in segs { cubicTo(s.c1, s.c2, s.end) } }
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

    /// Elliptical arc → cubic-bezier segments (W3C endpoint→center conversion, then ≤90° pieces each
    /// approximated by a cubic). Empty ⇒ caller should draw a straight line.
    static func arcToCubics(from p0: Vec2, rx rxIn: Double, ry ryIn: Double, rotDeg: Double,
                            largeArc: Bool, sweep: Bool, to p1: Vec2) -> [(c1: Vec2, c2: Vec2, end: Vec2)] {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 1e-9, ry > 1e-9, (p0 - p1).length > 1e-9 else { return [] }
        let phi = rotDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        // Step 1: midpoint in the rotated frame.
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        // Step 2: correct out-of-range radii.
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
        // Step 3: center in the rotated frame.
        let num = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den > 0 ? (num / den).squareRoot() : 0
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry
        let cyp = coef * -ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        // Step 4: start angle + sweep.
        func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var a = acos(min(max(len > 0 ? dot / len : 0, -1), 1))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let theta1 = ang(1, 0, ux, uy)
        var delta = ang(ux, uy, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        // Step 5: split into ≤90° pieces, cubic per piece.
        let n = max(Int(ceil(abs(delta) / (.pi / 2))), 1)
        let step = delta / Double(n)
        let t = 4.0 / 3.0 * tan(step / 4)
        func point(_ a: Double) -> Vec2 {
            let x = rx * cos(a), y = ry * sin(a)
            return Vec2(cx + cosP * x - sinP * y, cy + sinP * x + cosP * y)
        }
        func deriv(_ a: Double) -> Vec2 {
            let x = -rx * sin(a), y = ry * cos(a)
            return Vec2(cosP * x - sinP * y, sinP * x + cosP * y)
        }
        var out: [(Vec2, Vec2, Vec2)] = []
        var a = theta1
        for _ in 0..<n {
            let a2 = a + step
            let pA = point(a), pB = point(a2)
            let c1 = pA + deriv(a) * t
            let c2 = pB - deriv(a2) * t
            out.append((c1, c2, pB))
            a = a2
        }
        return out
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

        /// Arc flags are single 0/1 digits and may be packed without separators ("0 0 1" or "001").
        mutating func nextFlag() -> Double? {
            skipSeparators()
            guard i < chars.count else { return nil }
            switch chars[i] { case "0": i += 1; return 0; case "1": i += 1; return 1; default: return nil }
        }

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
