#if os(macOS)
import SwiftUI
import AppKit
import MotionKernel

/// Selection gizmo geometry for the selected layer at the playhead, in both comp and view space.
private struct GizmoGeo {
    var cornersComp: [Vec2]
    var cornersView: [CGPoint]
    var rotateView: CGPoint
    var anchorView: CGPoint
    var pivotComp: Vec2     // anchor point in comp space (scale/rotate center)
    var world: Affine2D
    var size: Vec2
    var scale: Vec2
    var rotation: Double
}

/// The canvas surface: the Metal preview plus a selection + transform-gizmo overlay (editor-ui.md
/// §2). A press routes by what it lands on — a corner handle scales (uniform, about the anchor), the
/// rotate handle rotates, the layer body moves, empty space deselects. Each gesture is one
/// transaction (one ⌘Z) and auto-keyframes when the property's track is already animated.
struct CanvasArea: View {
    let model: DocumentModel

    private enum Mode { case none, move, scale, rotate, anchor, marquee }
    @State private var began = false
    @State private var mode: Mode = .none
    @State private var txn: TransactionID?
    @State private var pivot: Vec2 = .zero
    @State private var startComp: Vec2 = .zero
    @State private var startScale: Vec2 = .one
    @State private var startRotation: Double = 0
    @State private var startDist: Double = 1
    @State private var startAngle: Double = 0
    @State private var startPositions: [EntityID: Vec2] = [:]
    @State private var primaryId: EntityID?
    @State private var startWorld: Affine2D = .identity
    @State private var startSize: Vec2 = .one
    @State private var axisX: Vec2 = Vec2(1, 0)
    @State private var axisY: Vec2 = Vec2(0, 1)
    @State private var cornerOffX: Double = 1
    @State private var cornerOffY: Double = 1
    @State private var candidatesX: [Double] = []
    @State private var candidatesY: [Double] = []
    @State private var boxOffX: [Double] = []
    @State private var boxOffY: [Double] = []
    @State private var snapGuides: [SnapGuide] = []
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let viewport = self.viewport(for: geo.size)
            ZStack {
                MetalCanvasView(model: model)
                overlay(viewport: viewport, viewSize: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(viewport))
            .overlay(alignment: .topLeading) { toolbar }
        }
        .background(Color.black)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("cursorarrow", .select)
            toolButton("rectangle", .rect)
            toolButton("circle", .ellipse)
            toolButton("character", .text)
            toolButton("scope", .anchor)
        }
        .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
    }
    private func toolButton(_ icon: String, _ tool: DocumentModel.Tool) -> some View {
        Button { model.tool = tool } label: {
            Image(systemName: icon)
                .foregroundStyle(model.tool == tool ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 18)
        }.buttonStyle(.plain)
    }

    // MARK: Overlay

    @ViewBuilder
    private func overlay(viewport: Viewport, viewSize: CGSize) -> some View {
        ZStack {
            // Multi-selection: light box per layer. Single: full gizmo with handles.
            if model.selection.count > 1 {
                ForEach(selectionPolys(viewport), id: \.0) { _, pts in
                    Path { p in p.move(to: pts[0]); for c in pts.dropFirst() { p.addLine(to: c) }; p.closeSubpath() }
                        .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                }
            } else {
                SelectionOverlay(geo: gizmo(viewport))
            }
            // Snap guides.
            ForEach(Array(snapGuides.enumerated()), id: \.offset) { _, g in
                guideLine(g, viewport: viewport, viewSize: viewSize)
            }
            // Marquee rectangle.
            if let a = marqueeStart, let b = marqueeCurrent {
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                Rectangle().fill(Color.accentColor.opacity(0.1))
                    .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
        }
        .allowsHitTesting(false)
    }

    private func guideLine(_ g: SnapGuide, viewport: Viewport, viewSize: CGSize) -> some View {
        let p = viewport.toView(Vec2(g.position, g.position))
        return Path { path in
            if g.axis == .vertical {
                path.move(to: CGPoint(x: p.x, y: 0)); path.addLine(to: CGPoint(x: p.x, y: viewSize.height))
            } else {
                path.move(to: CGPoint(x: 0, y: p.y)); path.addLine(to: CGPoint(x: viewSize.width, y: p.y))
            }
        }.stroke(Color.red.opacity(0.8), lineWidth: 1)
    }

    private func viewport(for size: CGSize) -> Viewport {
        let comp = model.mainComp?.size ?? Vec2(1920, 1080)
        return Viewport(compSize: comp, viewSize: Vec2(size.width, size.height))
    }

    // MARK: Gesture

    private func dragGesture(_ viewport: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !began { began = true; beginGesture(value, viewport) }
                let cur = viewport.toComp(Vec2(value.location.x, value.location.y))
                switch mode {
                case .move: dragMove(cur, viewport: viewport)
                case .scale: dragScale(cur)
                case .rotate: dragRotate(cur)
                case .anchor: dragAnchor(cur)
                case .marquee: marqueeCurrent = CGPoint(x: value.location.x, y: value.location.y)
                case .none: break
                }
            }
            .onEnded { _ in
                if mode == .marquee { finishMarquee(viewport) }
                if let txn { model.store.commit(txn) }
                txn = nil; mode = .none; began = false; snapGuides = []
                marqueeStart = nil; marqueeCurrent = nil
            }
    }

    private func beginGesture(_ value: DragGesture.Value, _ viewport: Viewport) {
        guard let comp = model.mainComp else { return }
        let sp = value.startLocation
        let pressComp = viewport.toComp(Vec2(sp.x, sp.y))
        let t = model.playback.currentTime

        // Creation tools: click to place a layer at the press point, then revert to select.
        switch model.tool {
        case .rect: model.createLayer(.rect, at: pressComp); model.tool = .select; mode = .none; return
        case .ellipse: model.createLayer(.ellipse, at: pressComp); model.tool = .select; mode = .none; return
        case .text: model.createLayer(.text, at: pressComp); model.tool = .select; mode = .none; return
        case .select, .anchor: break
        }

        // Anchor tool: drag the selected layer's anchor.
        if model.tool == .anchor, let g = gizmo(viewport), let sel = model.selection.first,
           let layer = model.layer(sel) {
            mode = .anchor; startWorld = g.world; startSize = g.size
            txn = model.store.begin("Anchor \(layer.name)")
            return
        }

        // Select tool — gizmo handles first (single selection).
        if model.tool == .select, let g = gizmo(viewport), let sel = model.selection.first,
           let layer = model.layer(sel) {
            if let ci = g.cornersView.firstIndex(where: { hypot($0.x - sp.x, $0.y - sp.y) < 11 }) {
                mode = .scale; pivot = g.pivotComp; startScale = g.scale
                axisX = unit(Vec2(g.world.a, g.world.b)); axisY = unit(Vec2(g.world.c, g.world.d))
                cornerOffX = dot(g.cornersComp[ci] - g.pivotComp, axisX)
                cornerOffY = dot(g.cornersComp[ci] - g.pivotComp, axisY)
                startDist = max((g.cornersComp[ci] - g.pivotComp).length, 1e-3)
                txn = model.store.begin("Scale \(layer.name)")
                return
            }
            if hypot(g.rotateView.x - sp.x, g.rotateView.y - sp.y) < 14 {
                mode = .rotate; pivot = g.pivotComp; startRotation = g.rotation
                startAngle = angle(pressComp - g.pivotComp)
                txn = model.store.begin("Rotate \(layer.name)")
                return
            }
        }

        // Body hit-test → select + move; empty → marquee.
        let hit = HitTester.topLayer(in: model.document, compId: comp.id, at: t, compPoint: pressComp)
        let shift = NSEvent.modifierFlags.contains(.shift)
        if let hit {
            if shift {
                if model.selection.contains(hit) { model.selection.remove(hit) }
                else { model.selection.insert(hit) }
                mode = .none // shift-click toggles selection only
                return
            }
            if !model.selection.contains(hit) { model.selection = [hit] }
            primaryId = hit
            startComp = pressComp
            startPositions = [:]
            for id in model.selection { if let l = model.layer(id) { startPositions[id] = l.transform.position.resolve(at: t) } }
            computeSnapData(comp: comp, t: t)
            mode = .move
            txn = model.store.begin("Move")
        } else {
            mode = .marquee
            marqueeStart = CGPoint(x: sp.x, y: sp.y); marqueeCurrent = marqueeStart
        }
    }

    private func dragMove(_ cur: Vec2, viewport: Viewport) {
        guard let txn, let primaryId, let pStart = startPositions[primaryId] else { return }
        let rawPrimary = pStart + (cur - startComp)
        var snapped = rawPrimary
        if !NSEvent.modifierFlags.contains(.command) {
            let out = CanvasSnapper.snap(position: rawPrimary, boxOffsetsX: boxOffX, boxOffsetsY: boxOffY,
                                         candidatesX: candidatesX, candidatesY: candidatesY,
                                         threshold: 6 / max(viewport.scale, 1e-6))
            snapped = out.position; snapGuides = out.guides
        } else { snapGuides = [] }
        let delta = snapped - pStart
        for (id, start) in startPositions { model.setPosition(id, to: start + delta, within: txn) }
    }

    private func dragScale(_ cur: Vec2) {
        guard let txn, let sel = model.selection.first else { return }
        let v = cur - pivot
        let newScale: Vec2
        if NSEvent.modifierFlags.contains(.shift) {
            let f = max(v.length / startDist, 0.01)
            newScale = Vec2(startScale.x * f, startScale.y * f)
        } else {
            let fx = cornerOffX != 0 ? dot(v, axisX) / cornerOffX : 1
            let fy = cornerOffY != 0 ? dot(v, axisY) / cornerOffY : 1
            newScale = Vec2(startScale.x * max(fx, 0.01), startScale.y * max(fy, 0.01))
        }
        model.setScale(sel, to: newScale, within: txn)
    }

    private func dragRotate(_ cur: Vec2) {
        guard let txn, let sel = model.selection.first else { return }
        let delta = (angle(cur - pivot) - startAngle) * 180 / .pi
        model.setRotation(sel, to: startRotation + delta, within: txn)
    }

    private func dragAnchor(_ cur: Vec2) {
        guard let txn, let sel = model.selection.first, let inv = startWorld.inverted() else { return }
        let local = inv.apply(to: cur)
        let anchorN = Vec2(startSize.x > 0 ? local.x / startSize.x : 0.5,
                           startSize.y > 0 ? local.y / startSize.y : 0.5)
        model.setAnchor(sel, anchor: anchorN, position: cur, within: txn)
    }

    private func finishMarquee(_ viewport: Viewport) {
        guard let a = marqueeStart, let b = marqueeCurrent, let comp = model.mainComp else { return }
        let p0 = viewport.toComp(Vec2(min(a.x, b.x), min(a.y, b.y)))
        let p1 = viewport.toComp(Vec2(max(a.x, b.x), max(a.y, b.y)))
        let evaluated = SceneEvaluator(document: model.document)
            .evaluate(compId: comp.id, at: model.playback.currentTime)
        var hits = Set<EntityID>()
        for ev in evaluated where ev.active && ev.size.x > 0 {
            let box = ev.boundingBox
            if !(box.max.x < p0.x || box.min.x > p1.x || box.max.y < p0.y || box.min.y > p1.y) {
                hits.insert(ev.layerId)
            }
        }
        model.selection = NSEvent.modifierFlags.contains(.shift) ? model.selection.union(hits) : hits
    }

    // MARK: Snap candidates

    private func computeSnapData(comp: Composition, t: TimeInterval) {
        candidatesX = [0, comp.size.x / 2, comp.size.x]
        candidatesY = [0, comp.size.y / 2, comp.size.y]
        let evaluated = SceneEvaluator(document: model.document).evaluate(compId: comp.id, at: t)
        for ev in evaluated where ev.size.x > 0 && !model.selection.contains(ev.layerId) {
            let b = ev.boundingBox
            candidatesX += [b.min.x, (b.min.x + b.max.x) / 2, b.max.x]
            candidatesY += [b.min.y, (b.min.y + b.max.y) / 2, b.max.y]
        }
        if let primaryId, let pev = evaluated.first(where: { $0.layerId == primaryId }),
           let pos = startPositions[primaryId] {
            let b = pev.boundingBox
            boxOffX = [b.min.x - pos.x, (b.min.x + b.max.x) / 2 - pos.x, b.max.x - pos.x]
            boxOffY = [b.min.y - pos.y, (b.min.y + b.max.y) / 2 - pos.y, b.max.y - pos.y]
        } else { boxOffX = [0]; boxOffY = [0] }
    }

    // MARK: Geometry

    private func angle(_ v: Vec2) -> Double { atan2(v.y, v.x) }
    private func dot(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.x + a.y * b.y }
    private func unit(_ v: Vec2) -> Vec2 { let l = max(v.length, 1e-9); return Vec2(v.x / l, v.y / l) }

    /// Screen-space polygons for every selected layer's bounds.
    private func selectionPolys(_ viewport: Viewport) -> [(String, [CGPoint])] {
        guard let comp = model.mainComp else { return [] }
        let evaluated = SceneEvaluator(document: model.document)
            .evaluate(compId: comp.id, at: model.playback.currentTime)
        return evaluated.compactMap { ev in
            guard model.selection.contains(ev.layerId), ev.size.x > 0, ev.size.y > 0 else { return nil }
            let local = [Vec2(0, 0), Vec2(ev.size.x, 0), Vec2(ev.size.x, ev.size.y), Vec2(0, ev.size.y)]
            let pts = local.map { let v = viewport.toView(ev.world.apply(to: $0)); return CGPoint(x: v.x, y: v.y) }
            return (ev.layerId.rawValue, pts)
        }
    }

    /// Gizmo geometry for the single selected layer at the playhead.
    private func gizmo(_ viewport: Viewport) -> GizmoGeo? {
        guard model.selection.count == 1, let sel = model.selection.first, let comp = model.mainComp,
              let layer = model.layer(sel) else { return nil }
        let t = model.playback.currentTime
        let evaluated = SceneEvaluator(document: model.document).evaluate(compId: comp.id, at: t)
        guard let ev = evaluated.first(where: { $0.layerId == sel }), ev.size.x > 0, ev.size.y > 0
        else { return nil }

        let anchorN = layer.transform.anchor.resolve(at: t)
        let pivotComp = ev.world.apply(to: Vec2(anchorN.x * ev.size.x, anchorN.y * ev.size.y))
        let localCorners = [Vec2(0, 0), Vec2(ev.size.x, 0), Vec2(ev.size.x, ev.size.y), Vec2(0, ev.size.y)]
        let cornersComp = localCorners.map { ev.world.apply(to: $0) }
        let cornersView = cornersComp.map { let v = viewport.toView($0); return CGPoint(x: v.x, y: v.y) }
        let anchorView = { let v = viewport.toView(pivotComp); return CGPoint(x: v.x, y: v.y) }()

        let topCenterV = CGPoint(x: (cornersView[0].x + cornersView[1].x) / 2,
                                 y: (cornersView[0].y + cornersView[1].y) / 2)
        let boxCenterV = CGPoint(x: cornersView.map(\.x).reduce(0, +) / 4,
                                 y: cornersView.map(\.y).reduce(0, +) / 4)
        let dx = topCenterV.x - boxCenterV.x, dy = topCenterV.y - boxCenterV.y
        let len = max(hypot(dx, dy), 1e-3)
        let rotateView = CGPoint(x: topCenterV.x + dx / len * 28, y: topCenterV.y + dy / len * 28)

        return GizmoGeo(cornersComp: cornersComp, cornersView: cornersView, rotateView: rotateView,
                        anchorView: anchorView, pivotComp: pivotComp, world: ev.world, size: ev.size,
                        scale: layer.transform.scale.resolve(at: t),
                        rotation: layer.transform.rotation.resolve(at: t))
    }
}

/// Draws the selection outline, corner handles (scale), and the rotate handle.
private struct SelectionOverlay: View {
    let geo: GizmoGeo?

    var body: some View {
        if let geo, geo.cornersView.count == 4 {
            let corners = geo.cornersView
            let topCenter = CGPoint(x: (corners[0].x + corners[1].x) / 2,
                                    y: (corners[0].y + corners[1].y) / 2)
            ZStack {
                Path { p in
                    p.move(to: corners[0])
                    for c in corners.dropFirst() { p.addLine(to: c) }
                    p.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 1.5)

                Path { p in p.move(to: topCenter); p.addLine(to: geo.rotateView) }
                    .stroke(Color.accentColor, lineWidth: 1)
                Circle().fill(Color.white).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
                    .position(geo.rotateView)

                ForEach(Array(corners.enumerated()), id: \.offset) { _, c in
                    Rectangle().fill(Color.white).frame(width: 8, height: 8)
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                        .position(c)
                }
                // Anchor point handle.
                Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 11, height: 11)
                    .background(Circle().fill(Color.accentColor.opacity(0.6)).frame(width: 7, height: 7))
                    .position(geo.anchorView)
            }
            .allowsHitTesting(false)
        }
    }
}

/// A minimal inspector: the selected layer's name/type plus a live opacity slider that writes
/// through commands (one transaction per drag). Reads resolved values at the playhead, so fields
/// reflect the animated value (editor-ui.md §4).
struct InspectorView: View {
    let model: DocumentModel
    @State private var opacityTxn: TransactionID?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            if let layer = model.selectedLayer {
                Text(layer.name.isEmpty ? "Layer" : layer.name)
                    .font(.headline)
                Text(layer.content.typeName.capitalized)
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider()

                let t = model.playback.currentTime
                let position = layer.transform.position.resolve(at: t)
                let scale = layer.transform.scale.resolve(at: t)
                let rotation = layer.transform.rotation.resolve(at: t)
                let id = layer.id

                HStack(spacing: 6) {
                    keyButton(id, .position)
                    ScrubbableField(title: "X", value: position.x, format: "%.0f", sensitivity: 1,
                        onBegin: { model.store.begin("Position X") },
                        onChange: { v, txn in model.setPosition(id, to: Vec2(v, livePosition(id).y), within: txn) },
                        onEnd: { model.store.commit($0) })
                    ScrubbableField(title: "Y", value: position.y, format: "%.0f", sensitivity: 1,
                        onBegin: { model.store.begin("Position Y") },
                        onChange: { v, txn in model.setPosition(id, to: Vec2(livePosition(id).x, v), within: txn) },
                        onEnd: { model.store.commit($0) })
                }
                ScrubbableField(title: "∠", value: rotation, format: "%.1f°", sensitivity: 0.5,
                    onBegin: { model.store.begin("Rotation") },
                    onChange: { v, txn in model.setRotation(id, to: v, within: txn) },
                    onEnd: { model.store.commit($0) })
                HStack(spacing: 6) {
                    ScrubbableField(title: "W", value: scale.x * 100, format: "%.0f%%", sensitivity: 0.5,
                        onBegin: { model.store.begin("Scale X") },
                        onChange: { v, txn in model.setScale(id, to: Vec2(v / 100, liveScale(id).y), within: txn) },
                        onEnd: { model.store.commit($0) })
                    ScrubbableField(title: "H", value: scale.y * 100, format: "%.0f%%", sensitivity: 0.5,
                        onBegin: { model.store.begin("Scale Y") },
                        onChange: { v, txn in model.setScale(id, to: Vec2(liveScale(id).x, v / 100), within: txn) },
                        onEnd: { model.store.commit($0) })
                }

                VStack(alignment: .leading, spacing: 4) {
                    let opacity = layer.transform.opacity.resolve(at: t)
                    HStack {
                        keyButton(layer.id, .opacity)
                        Text(String(format: "Opacity  %.0f%%", opacity * 100)).font(.caption)
                    }
                    Slider(value: Binding(
                        get: { layer.transform.opacity.resolve(at: model.playback.currentTime) },
                        set: { newValue in
                            if let txn = opacityTxn { model.setOpacity(layer.id, to: newValue, within: txn) }
                        }
                    ), in: 0...1, onEditingChanged: { editing in
                        if editing {
                            opacityTxn = model.store.begin("Opacity")
                        } else if let txn = opacityTxn {
                            model.store.commit(txn); opacityTxn = nil
                        }
                    })
                }
                Divider()
                PresetsView(model: model)
                Spacer(minLength: 0)
            } else {
                Text("No selection").foregroundStyle(.secondary)
                Text("Click a layer on the canvas.").font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(.bar)
    }

    private func livePosition(_ id: EntityID) -> Vec2 {
        model.layer(id)?.transform.position.resolve(at: model.playback.currentTime) ?? .zero
    }
    private func liveScale(_ id: EntityID) -> Vec2 {
        model.layer(id)?.transform.scale.resolve(at: model.playback.currentTime) ?? .one
    }

    /// A keyframe toggle (diamond): filled when a keyframe sits at the playhead. Click to add/remove
    /// a keyframe for that property at the current time (editor-ui.md §2 "add keyframe" diamond).
    private func keyButton(_ layerId: EntityID, _ property: DocumentModel.KeyframeProperty) -> some View {
        let active = model.hasKeyframeAtPlayhead(layerId, property)
        return Button {
            model.toggleKeyframe(layerId, property)
        } label: {
            Image(systemName: active ? "diamond.fill" : "diamond")
                .font(.system(size: 10))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Toggle keyframe at playhead")
    }
}

/// A drag-to-change number field (the Figma/Blender gesture, editor-ui.md §4). Opens a transaction
/// on drag-start and commits on release — one ⌘Z per scrub. `sensitivity` is value units per point.
struct ScrubbableField: View {
    let title: String
    let value: Double
    let format: String
    let sensitivity: Double
    let onBegin: () -> TransactionID
    let onChange: (Double, TransactionID) -> Void
    let onEnd: (TransactionID) -> Void

    @State private var txn: TransactionID?
    @State private var startValue: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: format, value))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                if txn == nil { txn = onBegin(); startValue = value }
                if let txn { onChange(startValue + Double(v.translation.width) * sensitivity, txn) }
            }
            .onEnded { _ in if let txn { onEnd(txn) }; txn = nil })
    }
}

/// Motion presets panel (ai-pipeline.md §4 / §9 step 1, no AI): pick a character + duration, tap a
/// pattern to apply it to the selected layer(s) at the playhead. Each tap is one ⌘Z of plain
/// keyframes; multiple selected layers stagger.
struct PresetsView: View {
    let model: DocumentModel
    @State private var character: MotionCharacter = .snappy
    @State private var duration: Double = 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets").font(.headline)
            Picker("", selection: $character) {
                ForEach(MotionCharacter.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 6) {
                Text("Duration").font(.caption).foregroundStyle(.secondary)
                Slider(value: $duration, in: 0.1...2)
                Text(String(format: "%.1fs", duration)).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ForEach(MotionPattern.Group.allCases, id: \.self) { group in
                Text(group.rawValue.uppercased()).font(.caption2).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(MotionPattern.allCases.filter { $0.group == group }, id: \.self) { pattern in
                        Button(pattern.displayName) {
                            model.applyPattern(pattern, character: character, duration: duration)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.selection.isEmpty)
                    }
                }
            }
        }
    }
}
#endif
