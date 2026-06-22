import Foundation

/// A minimal ordered-agnostic JSON value, used to assemble foreign JSON documents (Lottie export)
/// without a typed struct per node. Foundation-only and Linux-clean. Encodes via `JSONEncoder`.
public indirect enum JSONValue: Encodable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case number(Double)
    case int(Int)
    case string(String)
    case bool(Bool)
    case null

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .number(let n): try c.encode(n)
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    /// Encode to compact UTF-8 JSON data.
    public func data() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

// Ergonomic builders.
public extension JSONValue {
    static func num(_ v: Double) -> JSONValue { .number(v) }
    static func nums(_ vs: [Double]) -> JSONValue { .array(vs.map { .number($0) }) }
}
