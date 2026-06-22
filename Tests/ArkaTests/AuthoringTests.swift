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
