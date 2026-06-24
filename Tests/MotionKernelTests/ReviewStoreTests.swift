import XCTest
@testable import MotionKernel

/// Playback-level review store + comment model (multiplayer.md).
private final class Seq: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return "id\(n)" }
}

final class ReviewStoreTests: XCTestCase {
    private func store() -> ShareStore {
        let seq = Seq()
        return ShareStore(now: { 1000 }, makeID: { seq.next() })
    }
    private func upload() -> ShareUpload {
        ShareUpload(meta: ShareMeta(name: "Promo", width: 640, height: 480, duration: 3, fps: 30, scope: "board"),
                    lottieJSON: #"{"v":"5.7.0","layers":[]}"#)
    }

    func testCreateAndFetchShare() async {
        let s = store()
        let id = await s.create(upload())
        XCTAssertEqual(id, "id1")
        let meta = await s.meta(id)
        XCTAssertEqual(meta?.name, "Promo")
        let lottie = await s.lottie(id)
        XCTAssertEqual(lottie, #"{"v":"5.7.0","layers":[]}"#)
        let missing = await s.meta("nope")
        XCTAssertNil(missing)
    }

    func testAddCommentsStampsAndSortsByTime() async {
        let s = store()
        let id = await s.create(upload())
        _ = await s.addComment(id, ReviewComment(time: 2.0, author: "Mat", text: "tighten this"))
        let saved = await s.addComment(id, ReviewComment(time: 0.5, pin: Vec2(100, 50), author: "Mat", text: "logo earlier"))
        XCTAssertEqual(saved?.createdAt, 1000, "stamped with the injected clock")
        XCTAssertFalse(saved?.id.isEmpty ?? true, "stamped with an id")
        let list = await s.comments(id)
        XCTAssertEqual(list.map(\.time), [0.5, 2.0], "sorted by timeline position")
        XCTAssertEqual(list.first?.pin, Vec2(100, 50))
    }

    func testCommentOnMissingShareFails() async {
        let s = store()
        let result = await s.addComment("ghost", ReviewComment(time: 1, author: "x", text: "y"))
        XCTAssertNil(result)
    }

    func testResolveComment() async {
        let s = store()
        let id = await s.create(upload())
        let c = await s.addComment(id, ReviewComment(time: 1, author: "a", text: "fix"))!
        await s.resolveComment(id, commentID: c.id, resolved: true)
        let list = await s.comments(id)
        XCTAssertTrue(list.first { $0.id == c.id }?.resolved ?? false)
    }

    func testCommentDecodesLenientClientPayload() throws {
        // What the web viewer posts: only time/pin/author/text.
        let json = #"{"time":1.5,"pin":[10,20],"author":"Viewer","text":"nice"}"#
        let c = try JSONDecoder().decode(ReviewComment.self, from: Data(json.utf8))
        XCTAssertEqual(c.time, 1.5); XCTAssertEqual(c.pin, Vec2(10, 20))
        XCTAssertEqual(c.author, "Viewer"); XCTAssertFalse(c.resolved)
    }
}
