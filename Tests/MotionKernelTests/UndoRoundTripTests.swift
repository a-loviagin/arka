import XCTest
@testable import MotionKernel

/// The workhorse (undo-system.md §9.1): apply N random valid commands in random transaction
/// groupings, undo everything → byte-identical to the original; redo everything → byte-identical
/// to the final state. This single test catches nearly every undo bug class.
final class UndoRoundTripTests: XCTestCase {

    func testUndoAllThenRedoAll() throws {
        for seed in UInt64(1)...20 {
            try runRoundTrip(seed: seed, gestures: 40)
        }
    }

    private func runRoundTrip(seed: UInt64, gestures: Int) throws {
        var rng = SeededRNG(seed: seed)
        let doc0 = Fixtures.sampleDocument()
        let store = CommandStore(document: doc0)
        let originalData = try doc0.canonicalData()

        for _ in 0..<gestures {
            let id = store.begin("gesture")
            let n = Int.random(in: 1...4, using: &rng)
            for _ in 0..<n {
                if let cmd = randomCommand(store.document, &rng) {
                    // Some randoms may still be invalid (e.g. removing an already-removed layer);
                    // perform validates and throws — swallow and continue, mirroring real input.
                    try? store.perform(cmd, in: id)
                }
            }
            store.commit(id)
        }

        let finalData = try store.document.canonicalData()

        var undoSteps = 0
        while store.canUndo { store.undo(); undoSteps += 1 }
        XCTAssertEqual(try store.document.canonicalData(), originalData,
                       "seed \(seed): undo-all should restore the original byte-for-byte")

        while store.canRedo { store.redo() }
        XCTAssertEqual(try store.document.canonicalData(), finalData,
                       "seed \(seed): redo-all should restore the final state byte-for-byte")
        _ = undoSteps
    }

    /// Generate a random *plausible* command against the current document. Type-correct by
    /// construction so most apply cleanly; the store still validates.
    private func randomCommand(_ doc: MotionDocument, _ rng: inout SeededRNG) -> AnyCommand? {
        guard let comp = doc.mainComposition, !comp.layers.isEmpty else { return nil }
        let layer = comp.layers.randomElement(using: &rng)!
        let paths = Fixtures.animatablePaths(for: layer)
        guard let (path, sample) = paths.randomElement(using: &rng) else { return nil }

        switch Int.random(in: 0...6, using: &rng) {
        case 0:
            return .setProperty(path: path, value: jitter(sample, &rng))
        case 1:
            let t = (Double(Int.random(in: 0...300, using: &rng)) / 60).rounded(toFrame: comp.fps)
            let interp: Interpolation = Bool.random(using: &rng) ? .bezier : .linear
            return .setKeyframe(path: path, keyframe: AnyKeyframe(t: min(t, comp.duration),
                                                                  v: jitter(sample, &rng), interp: interp))
        case 2:
            // Remove a keyframe if one exists (harmless otherwise).
            return .removeKeyframe(path: path, t: 0.0)
        case 3:
            return .setProperty(path: "\(layer.id)/transform/opacity",
                                value: .scalar(Double.random(in: 0...1, using: &rng)))
        case 4:
            let key = SortKey.between(SortKey("a0"), SortKey("a9"))
            return .reorderLayer(layerId: layer.id, sortKey: key)
        case 5:
            return .setCompositionSetting(compId: comp.id,
                                          setting: .duration(Double.random(in: 1...10, using: &rng)))
        default:
            // Set a non-cycling parent (or detach).
            let others = comp.layers.filter { $0.id != layer.id
                && !DocumentRules.wouldCreateCycle(layer: $0.id, newParent: layer.id, in: comp) }
            let parent = Bool.random(using: &rng) ? others.randomElement(using: &rng)?.id : nil
            if let parent, DocumentRules.wouldCreateCycle(layer: layer.id, newParent: parent, in: comp) {
                return nil
            }
            return .setLayerParent(layerId: layer.id, parentId: parent)
        }
    }

    private func jitter(_ v: AnyValue, _ rng: inout SeededRNG) -> AnyValue {
        switch v {
        case .scalar: .scalar(Double.random(in: -200...200, using: &rng))
        case .vec2: .vec2(Vec2(Double.random(in: -500...500, using: &rng),
                               Double.random(in: -500...500, using: &rng)))
        case .color: .color(ColorValue(r: .random(in: 0...1, using: &rng),
                                       g: .random(in: 0...1, using: &rng),
                                       b: .random(in: 0...1, using: &rng), a: 1))
        }
    }
}

private extension Double {
    func rounded(toFrame fps: Double) -> Double {
        (self * fps).rounded() / fps
    }
}
