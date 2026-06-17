import Foundation

/// Stable, deterministic content hash for asset dedup filenames (motion-document-schema.md §1:
/// "filename = hash"). Not cryptographic — FNV-1a run with two basis constants for a 128-bit digest,
/// which is plenty to collapse duplicate imports without collisions in practice. Deterministic and
/// dependency-free (no CryptoKit), so it's identical on every platform.
public enum ContentHash {
    public static func hex(_ data: Data) -> String {
        let a = fnv1a(data, offset: 0xcbf29ce484222325)
        let b = fnv1a(data, offset: 0x84222325cbf29ce4)
        return String(format: "%016llx%016llx", a, b)
    }

    private static func fnv1a(_ data: Data, offset: UInt64) -> UInt64 {
        let prime: UInt64 = 0x100000001b3
        var hash = offset
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

public extension Asset {
    /// Build a content-addressed asset whose path is `assets/<hash>.<ext>` so identical bytes
    /// collapse to one file across imports.
    static func contentAddressed(id: EntityID, type: Kind, data: Data, ext: String,
                                 pixelSize: Vec2? = nil) -> Asset {
        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let path = "\(MotionPackage.assetsDir)/\(ContentHash.hex(data)).\(cleanExt)"
        return Asset(id: id, type: type, path: path, pixelSize: pixelSize)
    }
}
