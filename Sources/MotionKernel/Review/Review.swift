import Foundation

/// Playback-level review (multiplayer.md: "review as the killer collab feature"). A creator shares a
/// board/frame; a viewer plays it on the web and leaves comments anchored to a **timeline moment**
/// and (optionally) a **board pin**. The creator sees those comments back on the timeline.
public struct ReviewComment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Timeline position the comment is anchored to (seconds).
    public var time: TimeInterval
    /// Optional pin in comp/board coordinates (where on the canvas the note points).
    public var pin: Vec2?
    public var author: String
    public var text: String
    /// Unix epoch seconds; set by the store on creation.
    public var createdAt: TimeInterval
    public var resolved: Bool

    public init(id: String = "", time: TimeInterval, pin: Vec2? = nil, author: String,
                text: String, createdAt: TimeInterval = 0, resolved: Bool = false) {
        self.id = id; self.time = time; self.pin = pin; self.author = author
        self.text = text; self.createdAt = createdAt; self.resolved = resolved
    }

    // Lenient decode: a web client posts only { time, pin?, author, text }.
    private enum CodingKeys: String, CodingKey { case id, time, pin, author, text, createdAt, resolved }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        time = try c.decodeIfPresent(TimeInterval.self, forKey: .time) ?? 0
        pin = try c.decodeIfPresent(Vec2.self, forKey: .pin)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? "Anonymous"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

/// Metadata a viewer needs to lay out playback + map pins (the Lottie itself is fetched separately).
public struct ShareMeta: Codable, Sendable, Equatable {
    public var name: String
    public var width: Double
    public var height: Double
    public var duration: TimeInterval
    public var fps: Double
    /// "board" or a frame name — shown in the viewer header.
    public var scope: String

    public init(name: String, width: Double, height: Double, duration: TimeInterval,
                fps: Double, scope: String = "board") {
        self.name = name; self.width = width; self.height = height
        self.duration = duration; self.fps = fps; self.scope = scope
    }
}

/// The creator's upload: review metadata + the Lottie JSON (as a string) the viewer will play.
public struct ShareUpload: Codable, Sendable {
    public var meta: ShareMeta
    public var lottieJSON: String
    public init(meta: ShareMeta, lottieJSON: String) { self.meta = meta; self.lottieJSON = lottieJSON }
}

/// In-memory share + comment store (Foundation-only, so it's unit-testable independent of the HTTP
/// layer; the server wraps it). A real deployment swaps this for a persisted backing store behind the
/// same async surface.
public actor ShareStore {
    public struct Share: Sendable {
        public var meta: ShareMeta
        public var lottieJSON: String
        public var comments: [ReviewComment]
    }

    private var shares: [String: Share] = [:]
    private let now: @Sendable () -> TimeInterval
    private let makeID: @Sendable () -> String

    /// Injectable clock + id generator keep tests deterministic; production uses wall-clock + UUIDs.
    public init(now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
                makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.now = now
        self.makeID = makeID
    }

    @discardableResult
    public func create(_ upload: ShareUpload) -> String {
        let id = String(makeID().replacingOccurrences(of: "-", with: "").prefix(10))
        shares[id] = Share(meta: upload.meta, lottieJSON: upload.lottieJSON, comments: [])
        return id
    }

    public func share(_ id: String) -> Share? { shares[id] }
    public func meta(_ id: String) -> ShareMeta? { shares[id]?.meta }
    public func lottie(_ id: String) -> String? { shares[id]?.lottieJSON }
    public func comments(_ id: String) -> [ReviewComment] {
        (shares[id]?.comments ?? []).sorted { $0.time < $1.time }
    }

    /// Append a comment (stamping id + createdAt); nil if the share doesn't exist.
    public func addComment(_ id: String, _ draft: ReviewComment) -> ReviewComment? {
        guard shares[id] != nil else { return nil }
        var c = draft
        c.id = makeID()
        c.createdAt = now()
        shares[id]!.comments.append(c)
        return c
    }

    public func resolveComment(_ id: String, commentID: String, resolved: Bool) {
        guard var share = shares[id], let i = share.comments.firstIndex(where: { $0.id == commentID }) else { return }
        share.comments[i].resolved = resolved
        shares[id] = share
    }
}
