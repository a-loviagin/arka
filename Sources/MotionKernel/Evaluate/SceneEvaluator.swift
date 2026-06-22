import Foundation

/// A layer with its `AnimatableValue`s resolved at a specific time and its world transform
/// composed down the parent chain. This is the kernel-side precursor to the engine's RenderTree
/// (render-engine.md §1): the app maps these into `RenderItem`s with GPU content. The kernel
/// owns the deterministic geometry/opacity; Metal content (glyph runs, textures) is app-side.
public struct EvaluatedLayer: Sendable, Equatable {
    public let layerId: EntityID
    public let world: Affine2D
    /// Opacity pre-multiplied down the parent chain (0…1).
    public let opacity: Double
    /// visible AND within [inPoint, outPoint) at this time.
    public let active: Bool
    /// Layer size in points where known (shapes, images, precomps); `.zero` for text (needs
    /// CoreText layout, which is app-side).
    public let size: Vec2
}

/// Measures a text layer's content size in points. The kernel can't lay out text (no CoreText —
/// platform-strategy.md §2), so the app/render side supplies this; without it text reports `.zero`.
public protocol TextMeasuring {
    func measure(_ text: TextContent, at t: TimeInterval) -> Vec2
}

/// Evaluates a whole composition at one time into a flat, render-ordered array — one O(n) sweep
/// with a memoized world-matrix pass, no recursion blow-ups (render-engine.md §1).
public struct SceneEvaluator {
    public let document: MotionDocument
    /// Optional text sizer (app-side, CoreText-backed). nil → text layers have `.zero` size.
    public let textMeasurer: (any TextMeasuring)?

    public init(document: MotionDocument, textMeasurer: (any TextMeasuring)? = nil) {
        self.document = document
        self.textMeasurer = textMeasurer
    }

    /// Resolve every layer of `compId` at comp-time `t`, in render order (bottom → top).
    public func evaluate(compId: EntityID, at t: TimeInterval) -> [EvaluatedLayer] {
        guard let comp = document.composition(compId) else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

        var worldCache: [EntityID: (Affine2D, Double)] = [:]

        func world(of layer: Layer, visiting: Set<EntityID>) -> (Affine2D, Double) {
            if let cached = worldCache[layer.id] { return cached }
            let (local, localOpacity) = localTransform(of: layer, at: t)
            let result: (Affine2D, Double)
            if let parentId = layer.parentId,
               let parent = byId[parentId],
               !visiting.contains(parentId) { // cycle guard (should be impossible post-validation)
                let (pw, po) = world(of: parent, visiting: visiting.union([layer.id]))
                result = (local.concatenating(pw), localOpacity * po)
            } else {
                result = (local, localOpacity)
            }
            worldCache[layer.id] = result
            return result
        }

        return comp.layersInRenderOrder.map { layer in
            let (w, op) = world(of: layer, visiting: [layer.id])
            let active = layer.visible && t >= layer.inPoint && t < layer.outPoint
            return EvaluatedLayer(layerId: layer.id, world: w, opacity: op,
                                  active: active, size: layerSize(of: layer, at: t))
        }
    }

    /// Local transform matrix + own opacity (not yet multiplied by parents).
    ///
    /// Composition order (AE/Lottie convention): translate anchor to origin → scale → rotate →
    /// translate to position. Anchor is normalized; converted to pixels via the layer's size.
    public func localTransform(of layer: Layer, at t: TimeInterval) -> (Affine2D, Double) {
        let tr = layer.transform
        let position = tr.position.resolve(at: t)
        let scale = tr.scale.resolve(at: t)
        let rotation = tr.rotation.resolve(at: t)
        let opacity = tr.opacity.resolve(at: t)
        let anchorN = tr.anchor.resolve(at: t)
        let size = layerSize(of: layer, at: t)
        let anchorPx = Vec2(anchorN.x * size.x, anchorN.y * size.y)

        let m = Affine2D.translation(anchorPx * -1)
            .concatenating(.scale(scale))
            .concatenating(.rotation(degrees: rotation))
            .concatenating(.translation(position))
        return (m, min(max(opacity, 0), 1))
    }

    /// Layer size in points where the kernel can know it.
    public func layerSize(of layer: Layer, at t: TimeInterval) -> Vec2 {
        switch layer.content {
        case .shape(let s):
            if s.geometry == .path, let b = s.path?.bounds {
                return Vec2(b.max.x - b.min.x, b.max.y - b.min.y)
            }
            return s.size.resolve(at: t)
        case .image(let i):
            return document.asset(i.assetId)?.pixelSize ?? .zero
        case .video(let v):
            return document.asset(v.assetId)?.pixelSize ?? .zero
        case .precomp(let p):
            return document.composition(p.compositionId)?.size ?? .zero
        case .text(let txt):
            return textMeasurer?.measure(txt, at: t) ?? .zero // CoreText layout is app-side
        case .group, .null:
            return .zero // group/null have no intrinsic size
        }
    }
}
