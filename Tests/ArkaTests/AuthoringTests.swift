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

    func testAlignFlipReorder() throws {
        let m = freshModel()
        let id = try XCTUnwrap(m.createLayer(.rect, at: Vec2(500, 300))) // 240×160, anchor 0.5
        m.selection = [id]

        m.align(.left)   // box.min.x → 0 ⇒ position.x = halfWidth = 120
        XCTAssertEqual(m.layer(id)!.transform.position.resolve(at: 0).x, 120, accuracy: 1.0)
        m.align(.top)    // box.min.y → 0 ⇒ position.y = halfHeight = 80
        XCTAssertEqual(m.layer(id)!.transform.position.resolve(at: 0).y, 80, accuracy: 1.0)

        m.flip(horizontal: true)
        XCTAssertLessThan(m.layer(id)!.transform.scale.resolve(at: 0).x, 0)

        let other = try XCTUnwrap(m.createLayer(.ellipse, at: Vec2(0, 0))) // lands on top
        m.selection = [id]
        m.reorder(toFront: true)
        XCTAssertGreaterThan(m.layer(id)!.sortKey, m.layer(other)!.sortKey, "brought to front")
    }

    func testGenericSettersWriteAndAutoKeyframe() throws {
        let m = freshModel()
        let id = try XCTUnwrap(m.createLayer(.rect, at: Vec2(0, 0)))

        // Static write through a transaction (size).
        let txn = m.store.begin("Size")
        m.setAnimatable(path: "\(id)/content/size", value: .vec2(Vec2(300, 200)), isAnimated: false, within: txn)
        m.store.commit(txn)
        guard case .shape(let s1) = try XCTUnwrap(m.layer(id)).content else { return XCTFail("shape") }
        XCTAssertEqual(s1.size.resolve(at: 0), Vec2(300, 200))

        // One-shot color write (fill).
        m.setAnimatableOnce(path: "\(id)/content/fillColor", value: .color(ColorValue(hex: "#FF0000")!),
                            isAnimated: false, label: "Fill")
        guard case .shape(let s2) = try XCTUnwrap(m.layer(id)).content else { return XCTFail("shape") }
        XCTAssertEqual(s2.fillColor?.resolve(at: 0).r ?? 0, 1.0, accuracy: 0.01)
        XCTAssertFalse(s2.fillColor?.isAnimated ?? true, "static write, no keyframes")

        // Toggling a keyframe animates the property.
        m.toggleKeyframe(path: "\(id)/content/fillColor", value: .color(ColorValue(hex: "#00FF00")!), existingTimes: [])
        guard case .shape(let s3) = try XCTUnwrap(m.layer(id)).content else { return XCTFail("shape") }
        XCTAssertTrue(s3.fillColor?.isAnimated ?? false, "keyframe toggle animates fill")
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
