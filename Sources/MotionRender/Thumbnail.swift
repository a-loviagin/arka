#if os(macOS)
import Foundation
import simd
import MotionKernel

/// Package thumbnail generation (export-and-format.md §5): a PNG of the frame at **25% of the
/// duration** (rarely blank, usually representative), fit within `maxDimension`. Regenerated on save.
public enum Thumbnail {
    public static func png(document: MotionDocument, compId: EntityID, renderer: MetalRenderer,
                           textEngine: TextEngine? = nil, textures: (any TextureProvider)? = nil,
                           maxDimension: Int = 512) -> Data? {
        guard let comp = document.composition(compId) else { return nil }
        let cw = max(comp.size.x, 1), ch = max(comp.size.y, 1)
        let scale = min(Double(maxDimension) / cw, Double(maxDimension) / ch, 1)
        let pixelSize = (width: max(Int((cw * scale).rounded()), 1),
                         height: max(Int((ch * scale).rounded()), 1))

        let t = comp.duration * 0.25
        let nodes = RenderTreeBuilder(document: document, textEngine: textEngine, textures: textures)
            .build(compId: compId, at: t)
        let bg = comp.backgroundColor
        let image = renderer.renderToImage(
            nodes: nodes,
            compSize: SIMD2<Float>(Float(comp.size.x), Float(comp.size.y)),
            pixelSize: pixelSize,
            clear: SIMD4<Double>(bg.r, bg.g, bg.b, 1)) // opaque thumbnail
        return image?.pngData()
    }
}
#endif
