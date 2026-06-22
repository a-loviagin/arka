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
public struct RenderTreeBuilder {
    let document: MotionDocument
    var textEngine: TextEngine?
    weak var textures: (any TextureProvider)?
    var video: VideoFrameProvider?
    /// Base URL for resolving relative asset paths (a `.motion` package dir). nil → treat asset
    /// paths as absolute file paths.
    var assetBaseURL: URL?

    public init(document: MotionDocument, textEngine: TextEngine? = nil,
                textures: (any TextureProvider)? = nil,
                video: VideoFrameProvider? = nil, assetBaseURL: URL? = nil) {
        self.document = document
        self.textEngine = textEngine
        self.textures = textures
        self.video = video
        self.assetBaseURL = assetBaseURL
    }

    private func assetURL(_ asset: Asset) -> URL {
        assetBaseURL?.appending(path: asset.path) ?? URL(fileURLWithPath: asset.path)
    }

    private static let rootKey = EntityID("__root__")

    public func build(compId: EntityID, at t: TimeInterval) -> [RenderNode] {
        buildNodes(compId: compId, at: t, visiting: [])
    }

    /// Build the whole multi-frame board: every composition becomes a `Precomp` placed at its
    /// `boardPosition` (board space = comp units), each carrying its own opaque background so frames
    /// read as cards. The global playhead `t` evaluates every frame at the same time (each clamped
    /// to its own duration). Draw the result with `MetalRenderer.boardProjection` for pan/zoom.
    public func buildBoard(at t: TimeInterval) -> [RenderNode] {
        document.compositions.map { comp in
            let clamped = min(max(t, 0), comp.duration)
            let children = buildNodes(compId: comp.id, at: clamped, visiting: [])
            let size = SIMD2<Float>(Float(comp.size.x), Float(comp.size.y))
            // Opaque full-frame background (shape local space is top-left → identity world covers it).
            let bg = RenderItem(world: matrix_identity_float3x3, opacity: 1,
                                content: .shape(ResolvedShape(kind: .rect, size: size, cornerRadius: 0,
                                                              fill: SIMD4<Float>(comp.backgroundColor),
                                                              stroke: .zero, strokeWidth: 0)))
            return .precomp(Precomp(world: boardWorld(comp.boardPosition), opacity: 1, effects: [],
                                    compSize: size, children: [.leaf(bg)] + children))
        }
    }

    /// Column-major translate matching the shader's `clipFromLocal * float3(local, 1)` convention.
    private func boardWorld(_ p: Vec2) -> simd_float3x3 {
        simd_float3x3(SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                      SIMD3<Float>(Float(p.x), Float(p.y), 1))
    }

    /// Build one composition's RenderTree by descending the parent tree, recursing into precomp
    /// layers (cycle-guarded) and isolating faded/effected groups. `visiting` guards precomp cycles.
    private func buildNodes(compId: EntityID, at t: TimeInterval,
                            visiting: Set<EntityID>) -> [RenderNode] {
        guard let comp = document.composition(compId) else { return [] }
        let scene = SceneEvaluator(document: document, textMeasurer: textEngine)
        let evById = Dictionary(uniqueKeysWithValues:
            scene.evaluate(compId: compId, at: t).map { ($0.layerId, $0) })

        // Parent → children (sorted by sortKey). Roots are parented to a sentinel.
        var childrenOf: [EntityID: [Layer]] = [:]
        for layer in comp.layers {
            childrenOf[layer.parentId ?? Self.rootKey, default: []].append(layer)
        }
        for key in childrenOf.keys { childrenOf[key]?.sort { $0.sortKey < $1.sortKey } }

        return buildSubtree(childrenOf[Self.rootKey] ?? [], compId: compId, at: t,
                            visiting: visiting, evById: evById, childrenOf: childrenOf,
                            enclosingIso: 1)
    }

    /// Render-ordered nodes for a set of sibling layers. `enclosingIso` is the absolute opacity of
    /// the nearest enclosing isolation group (1 at the top); a node's render opacity is its absolute
    /// opacity divided by it, so an isolation group applies its fade once at composite time.
    private func buildSubtree(_ layers: [Layer], compId: EntityID, at t: TimeInterval,
                              visiting: Set<EntityID>, evById: [EntityID: EvaluatedLayer],
                              childrenOf: [EntityID: [Layer]], enclosingIso: Double) -> [RenderNode] {
        var nodes: [RenderNode] = []
        for layer in layers {
            guard let ev = evById[layer.id], ev.active, ev.opacity > 0.001 else { continue }
            let world = simd_float3x3(ev.world)
            let rel = Float(ev.opacity / max(enclosingIso, 1e-6))
            let effects = resolveEffects(layer.effects, at: t)

            switch layer.content {
            case .shape(let shape):
                if shape.geometry == .path {
                    guard let p = shape.path else { continue }
                    var meshes: [PathMesh] = []
                    if let fc = shape.fillColor?.resolve(at: t), fc.a > 0.001,
                       let fillMesh = PathTessellator.mesh(p, fill: SIMD4<Float>(fc)) {
                        meshes.append(fillMesh)
                    }
                    if let sc = shape.strokeColor?.resolve(at: t),
                       let sw = shape.strokeWidth?.resolve(at: t), sw > 0.01,
                       let strokeMesh = PathStroker.mesh(p, width: Float(sw), color: SIMD4<Float>(sc)) {
                        meshes.append(strokeMesh) // drawn above the fill
                    }
                    guard !meshes.isEmpty else { continue }
                    nodes.append(.leaf(RenderItem(world: world, opacity: rel,
                                                  content: .path(meshes), effects: effects, blendMode: layer.blendMode)))
                } else {
                    guard let resolved = resolveShape(shape, at: t) else { continue }
                    nodes.append(.leaf(RenderItem(world: world, opacity: rel,
                                                  content: .shape(resolved), effects: effects, blendMode: layer.blendMode)))
                }
            case .text(let text):
                guard let engine = textEngine else { continue }
                let fontSize = text.fontSize.resolve(at: t)
                let tracking = text.tracking?.resolve(at: t) ?? 0
                let lineHeight = text.lineHeight?.resolve(at: t) ?? 0
                let fill = SIMD4<Float>(text.fillColor.resolve(at: t))
                guard let run = engine.run(for: text, fontSize: fontSize, tracking: tracking,
                                           lineHeight: lineHeight, fill: fill) else { continue }
                nodes.append(.leaf(RenderItem(world: world, opacity: rel,
                                              content: .glyphRun(run), effects: effects, blendMode: layer.blendMode)))
            case .image(let image):
                guard let texture = textures?.texture(forAssetId: image.assetId) else { continue }
                let size = document.asset(image.assetId)?.pixelSize ?? Vec2(Double(texture.width),
                                                                            Double(texture.height))
                nodes.append(.leaf(RenderItem(world: world, opacity: rel,
                                              content: .image(ImageQuad(
                                                texture: texture,
                                                size: SIMD2<Float>(Float(size.x), Float(size.y)))),
                                              effects: effects, blendMode: layer.blendMode)))
            case .precomp(let pre):
                guard !visiting.contains(compId),
                      let sub = document.composition(pre.compositionId) else { continue }
                let children = buildNodes(compId: pre.compositionId, at: t,
                                          visiting: visiting.union([compId]))
                nodes.append(.precomp(Precomp(
                    world: world, opacity: rel, effects: effects,
                    compSize: SIMD2<Float>(Float(sub.size.x), Float(sub.size.y)),
                    children: children)))
            case .video(let v):
                guard let provider = video, let asset = document.asset(v.assetId) else { continue }
                let url = assetURL(asset)
                guard let texture = provider.texture(for: v, asset: asset, assetURL: url, at: t) else { continue }
                let size = asset.pixelSize ?? provider.pixelSize(for: asset, assetURL: url)
                    ?? Vec2(Double(texture.width), Double(texture.height))
                nodes.append(.leaf(RenderItem(world: world, opacity: rel,
                                              content: .image(ImageQuad(
                                                texture: texture,
                                                size: SIMD2<Float>(Float(size.x), Float(size.y)))),
                                              effects: effects, blendMode: layer.blendMode)))
            case .group, .null:
                let kids = childrenOf[layer.id] ?? []
                guard !kids.isEmpty else { continue }
                let ownOpacity = layer.transform.opacity.resolve(at: t)
                let isolate = ownOpacity < 0.999 || !effects.isEmpty
                if isolate {
                    // Children render at opacity relative to this group; the fade applies once here.
                    let childNodes = buildSubtree(kids, compId: compId, at: t, visiting: visiting,
                                                  evById: evById, childrenOf: childrenOf,
                                                  enclosingIso: ev.opacity)
                    if !childNodes.isEmpty {
                        nodes.append(.group(GroupNode(opacity: rel, effects: effects,
                                                      children: childNodes, blendMode: layer.blendMode)))
                    }
                } else {
                    // Transparent passthrough: children render inline at this level.
                    nodes.append(contentsOf: buildSubtree(kids, compId: compId, at: t, visiting: visiting,
                                                          evById: evById, childrenOf: childrenOf,
                                                          enclosingIso: enclosingIso))
                }
            }
        }
        return nodes
    }

    private func resolveEffects(_ effects: [Effect], at t: TimeInterval) -> [ResolvedEffect] {
        effects.compactMap { fx -> ResolvedEffect? in
            guard fx.enabled else { return nil }
            switch fx.type {
            case "blur":
                let r = scalar(fx, "radius", at: t) ?? 0
                return r > 0.01 ? .blur(radius: Float(r)) : nil
            case "shadow":
                let off = vec2(fx, "offset", at: t) ?? Vec2(0, 6)
                let r = scalar(fx, "radius", at: t) ?? 8
                let c = color(fx, "color", at: t) ?? .black
                let op = scalar(fx, "opacity", at: t) ?? 0.5
                return .shadow(offset: SIMD2<Float>(Float(off.x), Float(off.y)),
                               radius: Float(r), color: SIMD4<Float>(c), opacity: Float(op))
            case "backgroundBlur":
                let r = scalar(fx, "radius", at: t) ?? 8
                return r > 0.01 ? .backgroundBlur(radius: Float(r)) : nil
            default:
                return nil // unknown effect types are skipped (forward-compatible)
            }
        }
    }

    private func scalar(_ fx: Effect, _ key: String, at t: TimeInterval) -> Double? {
        if case .scalar(let v)? = fx.params[key] { return v.resolve(at: t) }
        return nil
    }
    private func vec2(_ fx: Effect, _ key: String, at t: TimeInterval) -> Vec2? {
        if case .vec2(let v)? = fx.params[key] { return v.resolve(at: t) }
        return nil
    }
    private func color(_ fx: Effect, _ key: String, at t: TimeInterval) -> ColorValue? {
        if case .color(let v)? = fx.params[key] { return v.resolve(at: t) }
        return nil
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
