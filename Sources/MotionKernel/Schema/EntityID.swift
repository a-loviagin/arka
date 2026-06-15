import Foundation

/// A stable string identity for any entity (document, comp, layer, asset, effect, keyframe-track).
///
/// Every entity has one (motion-document-schema.md §1): undo, AI patches, and cross-references
/// all hang off IDs, never array indices.
///
/// IDs are **client-prefixed** (multiplayer.md §2 "do now"): `layer_<clientId>_<counter>`
/// so two offline clients can never mint the same ID. Cheap now, prevents a merge nightmare later.
public struct EntityID: Codable, Sendable, Equatable, Hashable, RawRepresentable,
                         ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Mints client-prefixed IDs deterministically per (client, prefix). Not thread-safe by design;
/// the CommandStore owns one on the main actor.
public struct IDGenerator: Sendable {
    public let clientId: String
    private var counters: [String: Int] = [:]

    public init(clientId: String) {
        self.clientId = clientId
    }

    public mutating func next(_ prefix: String) -> EntityID {
        let n = (counters[prefix] ?? 0) + 1
        counters[prefix] = n
        return EntityID("\(prefix)_\(clientId)_\(n)")
    }
}
