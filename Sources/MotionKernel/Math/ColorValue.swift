import Foundation

/// An RGBA color. Components are stored **sRGB-encoded** (display/gamma space, 0…1) —
/// the designer-facing representation that matches hex colors.
///
/// Interpolation between keyframes happens in **OKLab** (motion-document-schema.md §4,
/// render-engine.md §4): visibly better gradients than naïve sRGB lerp, which muddies
/// crossfades. Alpha interpolates linearly. The render layer converts the resolved color
/// to its linear working space; that's not the kernel's concern.
///
/// Codable form: a four-element array `[r, g, b, a]`. Also decodes from a `"#RRGGBB"` /
/// `"#RRGGBBAA"` hex string for convenience (e.g. composition `backgroundColor`).
public struct ColorValue: Codable, Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = ColorValue(r: 0, g: 0, b: 0)
    public static let white = ColorValue(r: 1, g: 1, b: 1)
    public static let clear = ColorValue(r: 0, g: 0, b: 0, a: 0)

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let hex = try? single.decode(String.self) {
            guard let parsed = ColorValue(hex: hex) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid color hex string '\(hex)'"))
            }
            self = parsed
            return
        }
        var c = try decoder.unkeyedContainer()
        let r = try c.decode(Double.self)
        let g = try c.decode(Double.self)
        let b = try c.decode(Double.self)
        let a = c.isAtEnd ? 1.0 : try c.decode(Double.self)
        self.init(r: r, g: g, b: b, a: a)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(r)
        try c.encode(g)
        try c.encode(b)
        try c.encode(a)
    }
}

// MARK: - Hex

public extension ColorValue {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            self.init(r: Double((value >> 16) & 0xFF) / 255,
                      g: Double((value >> 8) & 0xFF) / 255,
                      b: Double(value & 0xFF) / 255,
                      a: 1)
        case 8:
            self.init(r: Double((value >> 24) & 0xFF) / 255,
                      g: Double((value >> 16) & 0xFF) / 255,
                      b: Double((value >> 8) & 0xFF) / 255,
                      a: Double(value & 0xFF) / 255)
        default:
            return nil
        }
    }
}

// MARK: - Interpolation (OKLab)

extension ColorValue: Interpolatable {
    public typealias Tangent = NoTangent

    public static func lerp(_ a: ColorValue, _ b: ColorValue, _ u: Double) -> ColorValue {
        let la = OKLab(a), lb = OKLab(b)
        let mixed = OKLab(
            L: Double.lerp(la.L, lb.L, u),
            a: Double.lerp(la.a, lb.a, u),
            b: Double.lerp(la.b, lb.b, u)
        )
        var out = mixed.toColor()
        out.a = Double.lerp(a.a, b.a, u)
        return out
    }
}

// MARK: - OKLab conversion (Björn Ottosson)

struct OKLab {
    var L: Double
    var a: Double
    var b: Double

    init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

    init(_ c: ColorValue) {
        // sRGB(display) → linear
        let r = OKLab.srgbToLinear(c.r)
        let g = OKLab.srgbToLinear(c.g)
        let bl = OKLab.srgbToLinear(c.b)
        // linear sRGB → LMS
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl
        let l_ = Foundation.cbrt(l)
        let m_ = Foundation.cbrt(m)
        let s_ = Foundation.cbrt(s)
        self.L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        self.a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        self.b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    }

    func toColor() -> ColorValue {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return ColorValue(
            r: OKLab.linearToSrgb(r),
            g: OKLab.linearToSrgb(g),
            b: OKLab.linearToSrgb(bl),
            a: 1
        )
    }

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : Foundation.pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ c: Double) -> Double {
        let clamped = min(max(c, 0), 1)
        return clamped <= 0.0031308
            ? 12.92 * clamped
            : 1.055 * Foundation.pow(clamped, 1 / 2.4) - 0.055
    }
}
