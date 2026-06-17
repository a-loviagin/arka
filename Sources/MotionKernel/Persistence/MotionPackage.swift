import Foundation

/// Read/write the `.motion` package (motion-document-schema.md §1, export-and-format.md §5).
///
/// v1 format is a **bundle directory** (`Foo.motion/` with `document.json`, content-addressed
/// `assets/`, and `thumbnail.png`) — dependency-free and matching the schema doc's layout. A
/// single-file zip is a later refinement. Foundation-only, so a server can read/write `.motion`
/// with the identical kernel.
///
/// Sharing semantics: packages are **always self-contained** — assets are embedded, never external
/// paths, so there are no "missing media" surprises. On open, migrations run in sequence
/// (`SchemaMigrator`); on save, only assets referenced by the document are written (orphans drop).
public enum MotionPackage {
    public static let documentName = "document.json"
    public static let assetsDir = "assets"
    public static let thumbnailName = "thumbnail.png"

    public enum PackageError: Error, CustomStringConvertible {
        case missingDocument(URL)
        case missingAssetBytes(path: String)

        public var description: String {
            switch self {
            case .missingDocument(let u): "no \(documentName) in package at \(u.path)"
            case .missingAssetBytes(let p): "no bytes supplied for asset \(p)"
            }
        }
    }

    /// Write a package directory. `assetData` maps each asset's `path` (e.g. "assets/ab12.png") to
    /// its bytes; every referenced asset must be present. `thumbnailPNG` is optional.
    public static func write(_ document: MotionDocument, to url: URL,
                             assetData: [String: Data] = [:],
                             thumbnailPNG: Data? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: url.appendingPathComponent(documentName))

        if !document.assets.isEmpty {
            try fm.createDirectory(at: url.appendingPathComponent(assetsDir), withIntermediateDirectories: true)
            for asset in document.assets {
                guard let data = assetData[asset.path] else {
                    throw PackageError.missingAssetBytes(path: asset.path)
                }
                try data.write(to: url.appendingPathComponent(asset.path))
            }
        }

        if let thumbnailPNG {
            try thumbnailPNG.write(to: url.appendingPathComponent(thumbnailName))
        }
    }

    /// Read + migrate a package's document. Asset files stay in the package; resolve their bytes via
    /// `url.appendingPathComponent(asset.path)`.
    public static func read(at url: URL,
                            appVersion: String = MotionDocument.currentSchemaVersion) throws -> MotionDocument {
        let docURL = url.appendingPathComponent(documentName)
        guard FileManager.default.fileExists(atPath: docURL.path) else {
            throw PackageError.missingDocument(url)
        }
        let data = try Data(contentsOf: docURL)
        return try SchemaMigrator.load(from: data, appVersion: appVersion)
    }

    /// Read all asset bytes out of a package — used to copy a document to a new package location.
    public static func assetData(in url: URL, for document: MotionDocument) -> [String: Data] {
        var out: [String: Data] = [:]
        for asset in document.assets {
            let assetURL = url.appendingPathComponent(asset.path)
            if let data = try? Data(contentsOf: assetURL) { out[asset.path] = data }
        }
        return out
    }

    /// IDs of assets whose files are missing from the package (should be empty for a valid package).
    public static func missingAssets(in url: URL, for document: MotionDocument) -> [EntityID] {
        document.assets
            .filter { !FileManager.default.fileExists(atPath: url.appendingPathComponent($0.path).path) }
            .map(\.id)
    }
}
