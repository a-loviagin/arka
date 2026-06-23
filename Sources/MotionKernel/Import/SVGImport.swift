import Foundation

/// Extracts drawable shapes from an SVG document — the `<path>` elements with their fills — and
/// parses each into editable `PathData` (via `SVGPathParser`). v1 scope: `<path>` only (the common
/// export shape; rect/circle/polygon primitives and transforms are a follow-up). Foundation-only.
public enum SVGImport {
    public struct Shape: Sendable, Equatable {
        public let path: PathData
        public let fill: ColorValue?   // nil = no fill ("none")
    }

    public static func shapes(fromSVG text: String) -> [Shape] {
        var shapes: [Shape] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard let open = range(of: "<path", in: chars, from: i) else { break }
            // The element runs to the next '>'.
            var j = open.upperBound
            while j < chars.count, chars[j] != ">" { j += 1 }
            let tag = String(chars[open.lowerBound..<min(j, chars.count)])
            i = min(j + 1, chars.count)
            guard let d = attribute("d", in: tag) else { continue }
            let subpaths = SVGPathParser.parse(d)
            guard !subpaths.isEmpty else { continue }
            shapes.append(Shape(path: PathData(subpaths: subpaths), fill: fill(in: tag)))
        }
        return shapes
    }

    // MARK: Attribute scanning

    private static func range(of needle: String, in chars: [Character], from: Int) -> Range<Int>? {
        let n = Array(needle)
        var i = from
        while i + n.count <= chars.count {
            if Array(chars[i..<i + n.count]) == n { return i..<(i + n.count) }
            i += 1
        }
        return nil
    }

    /// `name="value"` or `name='value'` within an element's tag text.
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

    /// Fill from `fill="…"` or `style="…;fill:…;…"`. `none` → no fill; unknown → black (visible).
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
