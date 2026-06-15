import Foundation

/// What changed, for render invalidation (properties-and-commands.md §2). v1 sends `.full` on
/// every edit — diff-based path invalidation is a later optimization (undo-system.md §2).
public enum ChangeSet: Sendable, Equatable {
    case full
    case paths([String])
}

/// Layer selection. Restored (not undone) across undo steps (undo-system.md §4).
public struct Selection: Sendable, Equatable {
    public var layerIds: Set<EntityID>
    public init(layerIds: Set<EntityID> = []) { self.layerIds = layerIds }
    public static let empty = Selection()
}

/// Where an edit came from — drives the future history panel and AI accept/undo metrics
/// (undo-system.md §5).
public enum EditSource: Sendable, Equatable {
    case user
    case ai(generationID: String)
}

struct UndoRecord: Sendable {
    let label: String
    let before: MotionDocument
    let beforeSelection: Selection
    let afterSelection: Selection
    let source: EditSource
}

public typealias TransactionID = UUID

struct OpenTransaction {
    let id: TransactionID
    let label: String
    let snapshotAtOpen: MotionDocument
    let selectionAtOpen: Selection
    let source: EditSource
}

/// The command store: document truth + snapshot undo + gesture transactions (undo-system.md §2-3).
///
/// Not Combine-based (Apple-only); change notifications go through `onChange`. The app drives this
/// on the main thread; the render engine reads the immutable `document` snapshot it's handed.
public final class CommandStore {
    public private(set) var document: MotionDocument
    public var selection: Selection = .empty

    private var undoStack: [UndoRecord] = []
    private var redoStack: [UndoRecord] = []
    private var open: OpenTransaction?

    /// History cap (undo-system.md §2). Drops from the bottom.
    public var maxHistory = 200

    /// Render/UI invalidation hook. Replaces the spec's Combine subject.
    public var onChange: ((ChangeSet) -> Void)?

    public init(document: MotionDocument) {
        self.document = document
    }

    // MARK: Transactions

    /// Open a gesture transaction (mouse-down / key-down / AI start). One gesture → one undo record.
    public func begin(_ label: String, source: EditSource = .user) -> TransactionID {
        precondition(open == nil, "nested transactions are a programming error (undo-system.md §3)")
        let id = TransactionID()
        open = OpenTransaction(id: id, label: label, snapshotAtOpen: document,
                               selectionAtOpen: selection, source: source)
        return id
    }

    /// Validate → apply to the live document → publish. Touches no undo stack until `commit`.
    public func perform(_ command: AnyCommand, in id: TransactionID) throws {
        guard let open, open.id == id else {
            fatalError("perform in unknown/closed transaction")
        }
        try command.validate(against: document)
        var copy = document
        try command.apply(to: &copy) // atomic: live doc only changes if apply succeeds
        document = copy
        onChange?(.full)
    }

    /// Commit the gesture: push exactly one undo record (unless it was a no-op).
    public func commit(_ id: TransactionID) {
        guard let open, open.id == id else { fatalError("commit of unknown transaction") }
        defer { self.open = nil }
        // No-op detection: clicking without changing must not pollute the stack.
        if document == open.snapshotAtOpen { return }
        let record = UndoRecord(label: open.label, before: open.snapshotAtOpen,
                                beforeSelection: open.selectionAtOpen,
                                afterSelection: selection, source: open.source)
        pushUndo(record)
        redoStack.removeAll()
    }

    /// Esc-to-abort: revert to the open snapshot, push nothing.
    public func cancel(_ id: TransactionID) {
        guard let open, open.id == id else { fatalError("cancel of unknown transaction") }
        document = open.snapshotAtOpen
        selection = open.selectionAtOpen
        self.open = nil
        onChange?(.full)
    }

    /// Convenience for a non-gesture edit (a button, a menu command, one AI batch): implicit
    /// single-command transaction.
    @discardableResult
    public func perform(_ command: AnyCommand, label: String, source: EditSource = .user) throws -> Bool {
        let id = begin(label, source: source)
        do {
            try perform(command, in: id)
        } catch {
            cancel(id)
            throw error
        }
        let before = undoStack.count
        commit(id)
        return undoStack.count > before
    }

    // MARK: Undo / Redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    public func undo() {
        guard let record = undoStack.popLast() else { return }
        let redo = UndoRecord(label: record.label, before: document,
                              beforeSelection: selection, afterSelection: record.beforeSelection,
                              source: record.source)
        redoStack.append(redo)
        document = record.before
        selection = record.beforeSelection // selection follows the undo (undo-system.md §4)
        onChange?(.full)
    }

    public func redo() {
        guard let record = redoStack.popLast() else { return }
        let undo = UndoRecord(label: record.label, before: document,
                              beforeSelection: selection, afterSelection: record.beforeSelection,
                              source: record.source)
        undoStack.append(undo)
        document = record.before
        selection = record.beforeSelection
        onChange?(.full)
    }

    private func pushUndo(_ record: UndoRecord) {
        undoStack.append(record)
        if undoStack.count > maxHistory {
            undoStack.removeFirst(undoStack.count - maxHistory)
        }
    }
}
