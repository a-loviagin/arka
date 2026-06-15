import Foundation

/// Order-preserving fractional index for z-order (multiplayer.md §2 "do now").
///
/// The schema's original "array position = z-order" corrupts under concurrency (two inserts
/// at index 3 collide). Instead each layer carries a `SortKey` string; render order = sort by
/// key. Inserting between two neighbors mints a key strictly between them without renumbering
/// anyone — Figma's approach. The editor still thinks in indexes; conversion happens at the
/// command boundary.
///
/// Keys are base-62 strings compared lexicographically. `keyBetween(a, b)` returns a key `k`
/// with `a < k < b` (either bound may be nil for "before everything" / "after everything").
public struct SortKey: Codable, Sendable, Equatable, Hashable, Comparable,
                       ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func < (a: SortKey, b: SortKey) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }

    // Base-62 digit alphabet, ordered so ASCII comparison matches digit value.
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let minDigit = digits.first!   // "0"
    static let maxDigit = digits.last!    // "z"

    /// A reasonable starting key for the first element in an empty list.
    public static let initial = SortKey("a0")

    /// Mint a key strictly between `lower` and `upper` (lexicographic). Pass nil for an open end.
    public static func between(_ lower: SortKey?, _ upper: SortKey?) -> SortKey {
        let a = lower?.rawValue ?? ""
        let b = upper?.rawValue ?? ""
        return SortKey(midpoint(a, b))
    }

    /// Core fractional-indexing midpoint between two base-62 strings (exclusive bounds).
    private static func midpoint(_ a: String, _ b: String) -> String {
        let aChars = Array(a)
        let bChars = Array(b)
        var result: [Character] = []
        var i = 0
        while true {
            let lo = i < aChars.count ? digitValue(aChars[i]) : 0
            // When `b` is empty (open upper bound), treat its digits as one past the top.
            let hi = i < bChars.count ? digitValue(bChars[i]) : (b.isEmpty ? digits.count : 0)

            if lo == hi {
                result.append(digits[lo])
                i += 1
                continue
            }
            if hi - lo > 1 {
                result.append(digits[(lo + hi) / 2])
                return String(result)
            }
            // Adjacent digits (hi == lo + 1): keep `a`'s digit and descend into its fraction,
            // appending a midpoint digit deeper so the result stays > a and < b.
            result.append(digits[lo])
            i += 1
            // Walk a's trailing digits; we need to go strictly above a's continuation.
            while true {
                let av = i < aChars.count ? digitValue(aChars[i]) : -1
                if av == digits.count - 1 {
                    result.append(digits[av])
                    i += 1
                    continue
                }
                result.append(digits[(av + 1 + digits.count) / 2])
                return String(result)
            }
        }
    }

    private static func digitValue(_ c: Character) -> Int {
        digits.firstIndex(of: c) ?? 0
    }
}
