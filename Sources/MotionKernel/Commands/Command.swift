import Foundation

/// Errors raised by command validation/application. Machine-readable enough to feed the AI
/// repair loop (ai-pipeline.md §5), human-legible enough to log.
public enum CommandError: Error, Equatable, Sendable, CustomStringConvertible {
    case layerNotFound(EntityID)
    case compositionNotFound(EntityID)
    case assetNotFound(EntityID)
    case effectNotFound(EntityID)
    case duplicateID(EntityID)
    case badPath(String)
    case typeMismatch(expected: String, got: String)
    case timeOutOfRange(t: TimeInterval, duration: TimeInterval)
    case valueOutOfRange(String)
    case parentCycle(layer: EntityID, parent: EntityID)
    case keyframeNotFound(path: String, t: TimeInterval)
    case unknownCommandType(String)

    public var description: String {
        switch self {
        case .layerNotFound(let id): "layer not found: \(id)"
        case .compositionNotFound(let id): "composition not found: \(id)"
        case .assetNotFound(let id): "asset not found: \(id)"
        case .effectNotFound(let id): "effect not found: \(id)"
        case .duplicateID(let id): "duplicate id: \(id)"
        case .badPath(let p): "bad property path: \(p)"
        case .typeMismatch(let e, let g): "type mismatch: expected \(e), got \(g)"
        case .timeOutOfRange(let t, let d): "time \(t)s out of comp range [0, \(d)]"
        case .valueOutOfRange(let m): "value out of range: \(m)"
        case .parentCycle(let l, let p): "parenting \(l) → \(p) would create a cycle"
        case .keyframeNotFound(let p, let t): "no keyframe at \(t)s on \(p)"
        case .unknownCommandType(let t): "unknown command type: \(t)"
        }
    }
}

/// The single write pathway (properties-and-commands.md §2). Every mutation — canvas drag,
/// keyframe nudge, AI generation — is a `Command`. Undo is snapshot-based (undo-system.md §1),
/// so the protocol carries no `inverted(against:)`.
public protocol Command: Sendable {
    /// IDs exist, values in range, times within comp duration. Pure check, no mutation.
    func validate(against doc: MotionDocument) throws
    /// Apply in place. Must be a no-op-on-throw at the call site (we apply to a copy first).
    func apply(to doc: inout MotionDocument) throws
}

public enum DocumentRules {
    /// Pure cycle check for re-parenting (multiplayer.md §2 "do now": must also be runnable
    /// server-side). Returns true if making `layer`'s parent `newParent` would create a cycle
    /// within `comp`.
    public static func wouldCreateCycle(layer: EntityID, newParent: EntityID?,
                                        in comp: Composition) -> Bool {
        guard let newParent else { return false }
        if newParent == layer { return true }
        let byId = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })
        var cursor: EntityID? = newParent
        var guardCount = 0
        while let c = cursor {
            if c == layer { return true }
            guardCount += 1
            if guardCount > comp.layers.count { return true } // pre-existing cycle; treat as unsafe
            cursor = byId[c]?.parentId
        }
        return false
    }
}
