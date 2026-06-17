#if os(macOS)
import SwiftUI
import MotionKernel

/// The canvas surface: the Metal preview plus a selection/drag overlay (editor-ui.md §2). Clicking
/// hit-tests the scene to select the topmost layer; dragging the body moves it, opening one
/// transaction on press and committing on release — so a move is a single ⌘Z step and auto-keyframes
/// when the position track is already animated.
struct CanvasArea: View {
    let model: DocumentModel

    @State private var gestureActive = false
    @State private var dragTxn: TransactionID?
    @State private var dragStartComp: Vec2 = .zero
    @State private var dragStartPos: Vec2 = .zero

    var body: some View {
        GeometryReader { geo in
            let viewport = self.viewport(for: geo.size)
            ZStack {
                MetalCanvasView(model: model)
                SelectionOverlay(corners: selectionCorners(viewport))
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
                guard let comp = model.mainComp else { return }
                if !gestureActive {
                    gestureActive = true
                    let press = viewport.toComp(Vec2(value.startLocation.x, value.startLocation.y))
                    let hit = HitTester.topLayer(in: model.document, compId: comp.id,
                                                 at: model.playback.currentTime, compPoint: press)
                    model.selection = hit.map { [$0] } ?? []
                    if let hit, let layer = model.layer(hit) {
                        dragStartComp = press
                        dragStartPos = layer.transform.position.resolve(at: model.playback.currentTime)
                        dragTxn = model.store.begin("Move \(layer.name)")
                    }
                }
                if let txn = dragTxn, let sel = model.selection.first {
                    let cur = viewport.toComp(Vec2(value.location.x, value.location.y))
                    model.setPosition(sel, to: dragStartPos + (cur - dragStartComp), within: txn)
                }
            }
            .onEnded { _ in
                if let txn = dragTxn { model.store.commit(txn); dragTxn = nil }
                gestureActive = false
            }
    }

    /// Screen-space corners of the selected layer's bounds at the playhead.
    private func selectionCorners(_ viewport: Viewport) -> [CGPoint]? {
        guard let sel = model.selection.first, let comp = model.mainComp else { return nil }
        let evaluated = SceneEvaluator(document: model.document)
            .evaluate(compId: comp.id, at: model.playback.currentTime)
        guard let ev = evaluated.first(where: { $0.layerId == sel }), ev.size.x > 0, ev.size.y > 0
        else { return nil }
        let local = [Vec2(0, 0), Vec2(ev.size.x, 0), Vec2(ev.size.x, ev.size.y), Vec2(0, ev.size.y)]
        return local.map {
            let v = viewport.toView(ev.world.apply(to: $0))
            return CGPoint(x: v.x, y: v.y)
        }
    }
}

/// Draws the selection outline + corner handles in screen space.
private struct SelectionOverlay: View {
    let corners: [CGPoint]?

    var body: some View {
        if let corners, corners.count == 4 {
            ZStack {
                Path { p in
                    p.move(to: corners[0])
                    for c in corners.dropFirst() { p.addLine(to: c) }
                    p.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                ForEach(Array(corners.enumerated()), id: \.offset) { _, c in
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
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
