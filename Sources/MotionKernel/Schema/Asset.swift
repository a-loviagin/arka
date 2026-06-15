import Foundation

/// A content-addressed asset reference (motion-document-schema.md §1). The `path` filename is a
/// hash, so duplicates collapse and AI patches reference assets unambiguously. The bytes live
/// outside the document in the `.motion` package's `assets/` directory.
public struct Asset: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, video, audio }

    public var id: EntityID
    public var type: Kind
    public var path: String          // e.g. "assets/a1b2c3.png"
    public var pixelSize: Vec2?      // for image/video

    public init(id: EntityID, type: Kind, path: String, pixelSize: Vec2? = nil) {
        self.id = id
        self.type = type
        self.path = path
        self.pixelSize = pixelSize
    }
}
