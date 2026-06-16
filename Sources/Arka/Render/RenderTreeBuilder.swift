#if os(macOS)
import Foundation
import simd
import MotionKernel

/// Turns a (document, comp, time) into a flat RenderTree. Uses the kernel's pure evaluate stage
/// for transforms/opacity (`SceneEvaluator`) and the same `AnimatableValue.resolve` for content
/// style — so the renderer's input is fully deterministic and identical for preview and export.
///
/// v1 draws Tier-1 parametric shapes (rect/rounded-rect/ellipse). Text/image/video/precomp layers
/// are skipped until their render paths land (render-engine.md §8 step 4+).
struct RenderTreeBuilder {
    let document: MotionDocument

    func build(compId: EntityID, at t: TimeInterval) -> [RenderItem] {
        guard let comp = document.composition(compId) else { return [] }
        let scene = SceneEvaluator(document: document)
        let evaluated = scene.evaluate(compId: compId, at: t)
        let byId = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

        var items: [RenderItem] = []
        items.reserveCapacity(evaluated.count)

        for ev in evaluated where ev.active && ev.opacity > 0.001 {
            guard let layer = byId[ev.layerId] else { continue }
            guard case .shape(let shape) = layer.content else { continue }
            guard let resolved = resolveShape(shape, at: t) else { continue }
            items.append(RenderItem(world: simd_float3x3(ev.world),
                                    opacity: Float(ev.opacity),
                                    shape: resolved))
        }
        return items
    }

    private func resolveShape(_ shape: ShapeContent, at t: TimeInterval) -> ResolvedShape? {
        let kind: ShapeKind
        switch shape.geometry {
        case .rect: kind = .rect
        case .ellipse: kind = .ellipse
        case .path: return nil // tessellated-path rendering is a later step
        }
        let size = shape.size.resolve(at: t)
        let fill = shape.fillColor?.resolve(at: t) ?? .clear
        let stroke = shape.strokeColor?.resolve(at: t) ?? .clear
        let strokeWidth = shape.strokeWidth?.resolve(at: t) ?? 0
        let corner = shape.cornerRadius?.resolve(at: t) ?? 0
        return ResolvedShape(
            kind: kind,
            size: SIMD2<Float>(Float(size.x), Float(size.y)),
            cornerRadius: Float(corner),
            fill: SIMD4<Float>(fill),
            stroke: SIMD4<Float>(stroke),
            strokeWidth: Float(strokeWidth)
        )
    }
}
#endif
