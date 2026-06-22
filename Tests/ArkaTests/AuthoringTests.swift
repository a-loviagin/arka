#if os(macOS)
import XCTest
@testable import Arka
import MotionKernel

/// Direct unit coverage for the editor's hand-authoring paths (create / duplicate / delete),
/// which build commands on top of the kernel's already-tested vocabulary.
@MainActor
final class AuthoringTests: XCTestCase {
    private func freshModel() -> DocumentModel {
        let m = DocumentModel()
        m.selection = []
        return m
    }

    func testCreateLayerAddsSelectedTopLayer() throws {
        let m = freshModel()
        let before = m.mainComp!.layers.count
        let id = try XCTUnwrap(m.createLayer(.rect, at: Vec2(100, 100)))
        XCTAssertEqual(m.mainComp!.layers.count, before + 1)
        XCTAssertEqual(m.selection, [id], "new layer is selected")
        let layer = try XCTUnwrap(m.layer(id))
        XCTAssertEqual(layer.transform.position.resolve(at: 0), Vec2(100, 100))
        // Top of z-order: highest sortKey.
        XCTAssertEqual(m.mainComp!.layers.max(by: { $0.sortKey < $1.sortKey })?.id, id)
        // One undo reverts the creation.
        m.store.undo()
        XCTAssertEqual(m.mainComp!.layers.count, before)
    }

    func testCreateEllipseAndTextDistinctContent() throws {
        let m = freshModel()
        let e = try XCTUnwrap(m.createLayer(.ellipse, at: Vec2(0, 0)))
        if case .shape(let s) = try XCTUnwrap(m.layer(e)).content {
            XCTAssertEqual(s.geometry, .ellipse)
        } else { XCTFail("expected shape") }
        let t = try XCTUnwrap(m.createLayer(.text, at: Vec2(0, 0)))
        guard case .text = try XCTUnwrap(m.layer(t)).content else { return XCTFail("expected text") }
    }

    func testDuplicateClonesOffsetsAndSelectsCopy() throws {
        let m = freshModel()
        let id = try XCTUnwrap(m.createLayer(.rect, at: Vec2(100, 100)))
        let countAfterCreate = m.mainComp!.layers.count
        m.duplicateSelectedLayers()
        XCTAssertEqual(m.mainComp!.layers.count, countAfterCreate + 1)
        XCTAssertEqual(m.selection.count, 1)
        let copyId = try XCTUnwrap(m.selection.first)
        XCTAssertNotEqual(copyId, id, "copy has a fresh id")
        let copy = try XCTUnwrap(m.layer(copyId))
        XCTAssertEqual(copy.transform.position.resolve(at: 0), Vec2(120, 120), "static position offset by 20")
    }

    func testGroupReparentsSelectionUnderNewGroup() throws {
        let m = freshModel()
        let a = try XCTUnwrap(m.createLayer(.rect, at: Vec2(10, 10)))
        let b = try XCTUnwrap(m.createLayer(.ellipse, at: Vec2(20, 20)))
        m.selection = [a, b]
        let before = m.mainComp!.layers.count
        m.groupSelection()
        XCTAssertEqual(m.mainComp!.layers.count, before + 1, "one new group layer")
        let groupId = try XCTUnwrap(m.selection.first)
        XCTAssertEqual(m.selection, [groupId])
        if case .group = try XCTUnwrap(m.layer(groupId)).content {} else { XCTFail("group content") }
        XCTAssertEqual(m.layer(a)?.parentId, groupId)
        XCTAssertEqual(m.layer(b)?.parentId, groupId)
        m.store.undo() // one step reverts the whole grouping
        XCTAssertEqual(m.mainComp!.layers.count, before)
        XCTAssertNil(m.layer(a)?.parentId)
    }

    func testUngroupFreesChildrenAndRemovesGroup() throws {
        let m = freshModel()
        let a = try XCTUnwrap(m.createLayer(.rect, at: Vec2(10, 10)))
        m.selection = [a]
        m.groupSelection()
        let groupId = try XCTUnwrap(m.selection.first)
        m.ungroupSelection()
        XCTAssertNil(m.layer(groupId), "group removed")
        XCTAssertNotNil(m.layer(a), "child survives")
        XCTAssertNil(m.layer(a)?.parentId, "child reparented to the group's parent (root)")
        XCTAssertEqual(m.selection, [a])
    }

    func testDrawToSizeSetsRectSizeAndPositionInOneStep() throws {
        let m = freshModel()
        let undosBefore = m.mainComp!.layers.count
        let created = try XCTUnwrap(m.beginCreateLayer(.rect, at: Vec2(100, 100)))
        m.updateCreateRect(created.id, from: Vec2(100, 100), to: Vec2(300, 260), within: created.txn)
        m.store.commit(created.txn)
        let layer = try XCTUnwrap(m.layer(created.id))
        if case .shape(let s) = layer.content {
            XCTAssertEqual(s.size.resolve(at: 0), Vec2(200, 160))
        } else { XCTFail("expected shape") }
        XCTAssertEqual(layer.transform.position.resolve(at: 0), Vec2(200, 180))
        m.store.undo() // create + resize is one undo step
        XCTAssertEqual(m.mainComp!.layers.count, undosBefore)
    }

    func testAutosaveSessionRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_rec_\(UInt32.random(in: 0..<UInt32.max)).motion")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let m = freshModel()
        let id = try XCTUnwrap(m.createLayer(.rect, at: Vec2(123, 45)))
        try m.writeSession(to: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "recovery package written")

        // A fresh model can reopen the autosaved session and recover the work.
        let recovered = DocumentModel()
        try recovered.open(tmp)
        XCTAssertNotNil(recovered.layer(id), "autosaved layer recovered")
        XCTAssertEqual(recovered.layer(id)?.transform.position.resolve(at: 0), Vec2(123, 45))
    }

    func testDeleteSelectedLayersIsOneUndoStep() throws {
        let m = freshModel()
        let a = try XCTUnwrap(m.createLayer(.rect, at: Vec2(10, 10)))
        let b = try XCTUnwrap(m.createLayer(.ellipse, at: Vec2(20, 20)))
        m.selection = [a, b]
        let before = m.mainComp!.layers.count
        m.deleteSelectedLayers()
        XCTAssertEqual(m.mainComp!.layers.count, before - 2)
        XCTAssertTrue(m.selection.isEmpty)
        // Atomic: one undo restores both.
        m.store.undo()
        XCTAssertEqual(m.mainComp!.layers.count, before)
    }
}
#endif
