import Foundation

/// Schema migration harness (export-and-format.md §5, motion-document-schema.md §1). Migrations
/// run in sequence on open (v0.1 → v0.2 → …); migrated documents save as the current version.
/// Migration code is **append-only** and covered by fixture documents from every released version.
///
/// v0.1 is the baseline, so there are no migrations yet — but the harness and the semver check
/// exist from day one, per the schema doc's "write migrations from day one" rule.
public enum SchemaMigrator {
    public enum MigrationError: Error, CustomStringConvertible {
        case unparseableVersion(String)
        case documentFromFuture(documentVersion: String, appVersion: String)

        public var description: String {
            switch self {
            case .unparseableVersion(let v): "unparseable schemaVersion '\(v)'"
            case .documentFromFuture(let d, let a):
                "document schemaVersion \(d) is newer than this app (\(a)) — update to open"
            }
        }
    }

    /// A single version-to-version migration step that rewrites the raw JSON object.
    struct Step: Sendable {
        let from: SemVer
        let to: SemVer
        let migrate: @Sendable (inout [String: Any]) throws -> Void
    }

    /// Ordered migration steps. Empty at v0.1; append future steps here.
    static let steps: [Step] = []

    /// Decode a document, running any needed migrations on the raw JSON first.
    ///
    /// - Same major version, doc minor ≤ app minor: migrate forward through `steps`.
    /// - Doc *newer* (minor) than app: open with unknown fields preserved round-trip is an
    ///   app-layer concern; here we surface the version so the app can decide. A doc with a newer
    ///   **major** version is rejected (incompatible).
    public static func load(from data: Data,
                            appVersion: String = MotionDocument.currentSchemaVersion) throws -> MotionDocument {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.unparseableVersion("<not a JSON object>")
        }
        let rawVersion = (object["schemaVersion"] as? String) ?? "0.1.0"
        guard let docVer = SemVer(rawVersion) else { throw MigrationError.unparseableVersion(rawVersion) }
        guard let appVer = SemVer(appVersion) else { throw MigrationError.unparseableVersion(appVersion) }

        if docVer.major > appVer.major {
            throw MigrationError.documentFromFuture(documentVersion: rawVersion, appVersion: appVersion)
        }

        for step in steps where step.from >= docVer && step.to <= appVer {
            try step.migrate(&object)
            object["schemaVersion"] = step.to.string
        }

        let migrated = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MotionDocument.self, from: migrated)
    }
}

/// Minimal semver for migration ordering (major.minor.patch).
public struct SemVer: Comparable, Equatable, Sendable {
    public let major, minor, patch: Int

    public init?(_ string: String) {
        let parts = string.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2] else { return nil }
        major = a; minor = b; patch = c
    }

    public var string: String { "\(major).\(minor).\(patch)" }

    public static func < (l: SemVer, r: SemVer) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}
