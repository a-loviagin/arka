#if os(macOS)
import SwiftUI
import MotionKernel

/// Selection gizmo geometry for the selected layer at the playhead, in both comp and view space.
private struct GizmoGeo {
    var cornersComp: [Vec2]
    var cornersView: [CGPoint]
    var rotateView: CGPoint
    var pivotComp: Vec2     // anchor point in comp space (scale/rotate center)
    var scale: Vec2
    var rotation: Double
}

/// The canvas surface: the Metal preview plus a selection + transform-gizmo overlay (editor-ui.md
/// §2). A press routes by what it lands on — a corner handle scales (uniform, about the anchor), the
/// rotate handle rotates, the layer body moves, empty space deselects. Each gesture is one
/// transaction (one ⌘Z) and auto-keyframes when the property's track is already animated.
struct CanvasArea: View {
    let model: DocumentModel

    private enum Mode { case none, move, scale, rotate }
    @State private var began = false
    @State private var mode: Mode = .none
    @State private var txn: TransactionID?
    @State private var pivot: Vec2 = .zero
    @State private var startComp: Vec2 = .zero
    @State private var startPos: Vec2 = .zero
    @State private var startScale: Vec2 = .one
    @State private var startRotation: Double = 0
    @State private var startDist: Double = 1
    @State private var startAngle: Double = 0

    var body: some View {
        GeometryReader { geo in
            let viewport = self.viewport(for: geo.size)
            ZStack {
                MetalCanvasView(model: model)
                SelectionOverlay(geo: gizmo(viewport))
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(viewport))
        }
        .background(Color.black)
    }

    private func viewport(for size: CGSize) -> Viewport {
        let comp = model.mainComp?.size ?? Vec2(1920, 1080)
        return Viewport(compSize: comp, viewSize: Vec2(size.width, size.height))
    }

    private func dragGesture(_ viewport: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !began { began = true; beginGesture(value, viewport) }
                guard let txn, let sel = model.selection.first else { return }
                let cur = viewport.toComp(Vec2(value.location.x, value.location.y))
                switch mode {
                case .move:
                    model.setPosition(sel, to: startPos + (cur - startComp), within: txn)
                case .scale:
                    let factor = max((cur - pivot).length / startDist, 0.01)
                    model.setScale(sel, to: Vec2(startScale.x * factor, startScale.y * factor), within: txn)
                case .rotate:
                    let delta = (angle(cur - pivot) - startAngle) * 180 / .pi
                    model.setRotation(sel, to: startRotation + delta, within: txn)
                case .none:
                    break
                }
            }
            .onEnded { _ in
                if let txn { model.store.commit(txn) }
                txn = nil; mode = .none; began = false
            }
    }

    private func beginGesture(_ value: DragGesture.Value, _ viewport: Viewport) {
        guard let comp = model.mainComp else { return }
        let sp = value.startLocation
        let pressComp = viewport.toComp(Vec2(sp.x, sp.y))

        // First: gizmo handles of the current selection.
        if let g = gizmo(viewport), let sel = model.selection.first, let layer = model.layer(sel) {
            if let ci = g.cornersView.firstIndex(where: { hypot($0.x - sp.x, $0.y - sp.y) < 11 }) {
                mode = .scale; pivot = g.pivotComp; startScale = g.scale
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

        // Otherwise: select the layer under the cursor and prepare to move it.
        let hit = HitTester.topLayer(in: model.document, compId: comp.id,
                                     at: model.playback.currentTime, compPoint: pressComp)
        model.selection = hit.map { [$0] } ?? []
        if let hit, let layer = model.layer(hit) {
            mode = .move
            startComp = pressComp
            startPos = layer.transform.position.resolve(at: model.playback.currentTime)
            txn = model.store.begin("Move \(layer.name)")
        }
    }

    private func angle(_ v: Vec2) -> Double { atan2(v.y, v.x) }

    /// Gizmo geometry for the selected layer at the playhead.
    private func gizmo(_ viewport: Viewport) -> GizmoGeo? {
        guard let sel = model.selection.first, let comp = model.mainComp,
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

        let topCenterV = midpoint(cornersView[0], cornersView[1])
        let boxCenterV = CGPoint(x: cornersView.map(\.x).reduce(0, +) / 4,
                                 y: cornersView.map(\.y).reduce(0, +) / 4)
        let dx = topCenterV.x - boxCenterV.x, dy = topCenterV.y - boxCenterV.y
        let len = max(hypot(dx, dy), 1e-3)
        let rotateView = CGPoint(x: topCenterV.x + dx / len * 28, y: topCenterV.y + dy / len * 28)

        return GizmoGeo(cornersComp: cornersComp, cornersView: cornersView, rotateView: rotateView,
                        pivotComp: pivotComp,
                        scale: layer.transform.scale.resolve(at: t),
                        rotation: layer.transform.rotation.resolve(at: t))
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
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
        VStack(alignment: .leading, spacing: 12) {
            if let layer = model.selectedLayer {
                Text(layer.name.isEmpty ? "Layer" : layer.name)
                    .font(.headline)
                Text(layer.content.typeName.capitalized)
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider()

                let t = model.playback.currentTime
                let position = layer.transform.position.resolve(at: t)
                HStack {
                    keyButton(layer.id, .position)
                    Text("Position").font(.caption)
                    Spacer()
                    Text(String(format: "%.0f, %.0f", position.x, position.y))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
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
                Spacer()
            } else {
                Text("No selection").foregroundStyle(.secondary)
                Text("Click a layer on the canvas.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.bar)
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
#endif
