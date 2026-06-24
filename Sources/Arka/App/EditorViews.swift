#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
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

    private enum Mode { case none, move, scale, rotate, anchor, marquee, create, pan, frameMove, frameResize }
    @State private var panAccum: CGSize = .zero
    @State private var magnifyLast: CGFloat = 1
    // Board frame manipulation (slice 3): a stable board viewport captured at gesture start (pan/zoom
    // don't change mid-drag) so board coords stay correct even while the frame itself moves.
    @State private var dragBV = Viewport(scale: 1, offset: .zero)
    @State private var frameDragId: EntityID?
    @State private var frameStartPos: Vec2 = .zero
    @State private var frameStartSize: Vec2 = .one
    @State private var frameStartBoard: Vec2 = .zero
    @State private var frameResizeCorner = 0 // 0=TL 1=TR 2=BL 3=BR
    @State private var renamingFrame: EntityID?
    @State private var began = false
    @State private var mode: Mode = .none
    @State private var txn: TransactionID?
    @State private var createId: EntityID?
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
                frameChrome(viewSize: geo.size)
                overlay(viewport: viewport, viewSize: geo.size)
                renameOverlay(viewSize: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(viewport))
            .simultaneousGesture(zoomGesture(viewSize: geo.size))
            .simultaneousGesture(renameTapGesture(viewSize: geo.size))
            .onDrop(of: [.svg, .image], isTargeted: nil) { providers, location in
                handleImageDrop(providers, at: location, viewport: viewport); return true
            }
            .overlay(alignment: .topLeading) { toolbar }
            .overlay(alignment: .bottomTrailing) { zoomControls(viewSize: geo.size) }
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

    /// Board → view mapping (points): `viewPoint = pan + boardPoint * zoom`. Falls back to a fitted
    /// transform when the board hasn't been laid out yet (so the very first frame is correct).
    private func boardViewport(for size: CGSize) -> Viewport {
        if model.boardZoom > 0 { return Viewport(scale: model.boardZoom, offset: model.boardPan) }
        let f = model.fittedBoard(viewSize: Vec2(size.width, size.height))
        return Viewport(scale: f.zoom, offset: f.pan)
    }

    /// View mapping for the *active frame's* comp space — its board position folded into the offset,
    /// so all the existing gizmo/selection/snapping math works unchanged under board pan/zoom.
    private func viewport(for size: CGSize) -> Viewport {
        let bv = boardViewport(for: size)
        let pos = model.mainComp?.boardPosition ?? .zero
        return Viewport(scale: bv.scale, offset: bv.toView(pos))
    }

    /// Reconstruct the board viewport from the active-frame viewport (same pan/zoom; just back out
    /// the active frame's board offset). Used inside the gesture, which only carries `viewport`.
    private func boardViewport(from active: Viewport) -> Viewport {
        let pos = model.mainComp?.boardPosition ?? .zero
        return Viewport(scale: active.scale, offset: active.offset - pos * active.scale)
    }

    private enum ChromeHit { case move(EntityID); case resize(EntityID, Int) }

    /// Hit-test the board chrome (select tool): a frame's title strip → move; the active frame's
    /// corner handles → resize. View-space, so tolerances are screen pixels.
    private func frameChromeHit(at sp: CGPoint, bv: Viewport) -> ChromeHit? {
        if let active = model.mainComp { // resize handles only on the focused frame
            let corners = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)]
            for (i, c) in corners.enumerated() {
                let p = bv.toView(active.boardPosition + Vec2(active.size.x * c.x, active.size.y * c.y))
                if hypot(p.x - sp.x, p.y - sp.y) < 12 { return .resize(active.id, i) }
            }
        }
        for f in model.frames.reversed() { // title strip just above each frame; topmost wins
            let tl = bv.toView(f.boardPosition)
            let w = f.size.x * bv.scale
            if sp.x >= tl.x - 4, sp.x <= tl.x + max(w, 80), sp.y >= tl.y - 20, sp.y <= tl.y + 2 {
                return .move(f.id)
            }
        }
        return nil
    }

    /// New (origin, size) for resizing `corner`, keeping the opposite corner anchored, min 16 units.
    private func resizedFrame(corner: Int, origin: Vec2, size: Vec2, to bp: Vec2) -> (Vec2, Vec2) {
        var x0 = origin.x, y0 = origin.y, x1 = origin.x + size.x, y1 = origin.y + size.y
        switch corner {
        case 0: x0 = bp.x; y0 = bp.y
        case 1: x1 = bp.x; y0 = bp.y
        case 2: x0 = bp.x; y1 = bp.y
        default: x1 = bp.x; y1 = bp.y
        }
        let minS = 16.0
        if x1 - x0 < minS { if corner == 0 || corner == 2 { x0 = x1 - minS } else { x1 = x0 + minS } }
        if y1 - y0 < minS { if corner == 0 || corner == 1 { y0 = y1 - minS } else { y1 = y0 + minS } }
        return (Vec2(x0, y0), Vec2(x1 - x0, y1 - y0))
    }

    // MARK: Board chrome (frame outlines + labels) and pan/zoom controls

    /// Outline + name label per frame, drawn over the rendered board, plus corner resize handles on
    /// the active frame. Non-interactive — move/resize/focus happen through the drag gesture; rename
    /// through the double-click gesture + `renameOverlay`.
    private func frameChrome(viewSize: CGSize) -> some View {
        let bv = boardViewport(for: viewSize)
        return ZStack {
        ForEach(model.frames, id: \.id) { frame in
            let isActive = frame.id == model.activeCompId
            let tl = bv.toView(frame.boardPosition)
            let w = frame.size.x * bv.scale, h = frame.size.y * bv.scale
            ZStack(alignment: .topLeading) {
                if renamingFrame != frame.id {
                    Text(frame.name.isEmpty ? "Frame" : frame.name)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        .fixedSize()
                        .position(x: tl.x + 1, y: tl.y - 12) // label sits just above the frame
                }
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isActive ? Color.accentColor : Color.white.opacity(0.18),
                            lineWidth: isActive ? 1.5 : 1)
                    .frame(width: max(w, 1), height: max(h, 1))
                    .position(x: tl.x + w / 2, y: tl.y + h / 2)
                if isActive {
                    ForEach(0..<4, id: \.self) { i in
                        let c = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)][i]
                        let p = bv.toView(frame.boardPosition + Vec2(frame.size.x * c.x, frame.size.y * c.y))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.accentColor, lineWidth: 1))
                            .frame(width: 8, height: 8)
                            .position(x: p.x, y: p.y)
                    }
                }
            }
        }
        // Review pin for the comment the creator is viewing (board-space → view).
        if let pin = model.activeReviewPin {
            let p = bv.toView(pin)
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22)).foregroundStyle(.orange)
                .shadow(radius: 2)
                .position(x: p.x, y: p.y - 9)
        }
        }
        .allowsHitTesting(false)
    }

    /// Inline editor shown over a frame's title while renaming (double-click a board label). Present
    /// only during rename, so it never competes with the move/pan drag gestures.
    @ViewBuilder
    private func renameOverlay(viewSize: CGSize) -> some View {
        if let id = renamingFrame, let frame = model.document.composition(id) {
            let bv = boardViewport(for: viewSize)
            let tl = bv.toView(frame.boardPosition)
            FrameNameField(initial: frame.name) { newName in
                model.renameFrame(id, to: newName); renamingFrame = nil
            } onCancel: { renamingFrame = nil }
            .frame(width: 160)
            .position(x: tl.x + 80, y: tl.y - 12)
        }
    }

    /// Double-click a frame's title strip to rename it (board side; the layers panel has its own).
    private func renameTapGesture(viewSize: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let bv = boardViewport(for: viewSize)
                for f in model.frames.reversed() {
                    let tl = bv.toView(f.boardPosition)
                    let w = f.size.x * bv.scale
                    if value.location.x >= tl.x - 4, value.location.x <= tl.x + max(w, 80),
                       value.location.y >= tl.y - 20, value.location.y <= tl.y + 2 {
                        model.setActiveFrame(f.id); renamingFrame = f.id; return
                    }
                }
            }
    }

    /// Drop image files/data from Finder/Desktop or other apps onto the canvas → an image layer at
    /// the drop point (mapped to the active frame's comp space).
    private func handleImageDrop(_ providers: [NSItemProvider], at location: CGPoint, viewport: Viewport) {
        let comp = viewport.toComp(Vec2(location.x, location.y))
        for p in providers {
            // SVG → editable vector layers; everything else raster → an image layer.
            if p.hasItemConformingToTypeIdentifier(UTType.svg.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.svg.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { model.importSVG(data: data, at: comp) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { model.importImage(data: data, at: comp) }
                }
            }
        }
    }

    private func zoomGesture(viewSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                let factor = magnifyLast > 0 ? Double(v / magnifyLast) : 1
                magnifyLast = v
                model.zoomBoard(by: factor, around: Vec2(viewSize.width / 2, viewSize.height / 2))
            }
            .onEnded { _ in magnifyLast = 1 }
    }

    @ViewBuilder
    private func zoomControls(viewSize: CGSize) -> some View {
        let center = Vec2(viewSize.width / 2, viewSize.height / 2)
        HStack(spacing: 2) {
            Button { model.zoomBoard(by: 1 / 1.2, around: center) } label: { Image(systemName: "minus") }
            Button { model.boardZoom = 0 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit board")
            Button { model.zoomBoard(by: 1.2, around: center) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
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
                case .create: dragCreate(cur)
                case .pan:
                    let d = Vec2(value.translation.width - panAccum.width,
                                 value.translation.height - panAccum.height)
                    model.panBoard(by: d); panAccum = value.translation
                case .frameMove:
                    if let id = frameDragId, let txn {
                        let bp = dragBV.toComp(Vec2(value.location.x, value.location.y))
                        model.setFramePosition(id, to: frameStartPos + (bp - frameStartBoard), within: txn)
                    }
                case .frameResize:
                    if let id = frameDragId, let txn {
                        let bp = dragBV.toComp(Vec2(value.location.x, value.location.y))
                        let (pos, size) = resizedFrame(corner: frameResizeCorner, origin: frameStartPos,
                                                       size: frameStartSize, to: bp)
                        model.setFrameSize(id, to: size, within: txn)
                        model.setFramePosition(id, to: pos, within: txn)
                    }
                case .none: break
                }
            }
            .onEnded { _ in
                if mode == .marquee { finishMarquee(viewport) }
                if mode == .create { model.tool = .select }
                if let txn { model.store.commit(txn) }
                txn = nil; mode = .none; began = false; snapGuides = []
                marqueeStart = nil; marqueeCurrent = nil; createId = nil; frameDragId = nil
            }
    }

    private func beginGesture(_ value: DragGesture.Value, _ viewport: Viewport) {
        guard let comp = model.mainComp else { return }
        let sp = value.startLocation
        let pressComp = viewport.toComp(Vec2(sp.x, sp.y))
        let t = model.playback.currentTime

        // Creation tools: text places at the click; rect/ellipse draw-to-size (default size on a
        // plain click). Tool reverts to select on mouse-up.
        switch model.tool {
        case .text:
            model.createLayer(.text, at: pressComp); model.tool = .select; mode = .none; return
        case .rect, .ellipse:
            let kind: DocumentModel.NewLayerKind = model.tool == .rect ? .rect : .ellipse
            if let created = model.beginCreateLayer(kind, at: pressComp) {
                createId = created.id; txn = created.txn; startComp = pressComp; mode = .create
            } else { mode = .none }
            return
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

        // Board chrome (select tool): grab a frame's title to move it, or a corner handle to resize.
        if model.tool == .select {
            let bv = boardViewport(from: viewport)
            if let chrome = frameChromeHit(at: sp, bv: bv) {
                dragBV = bv
                switch chrome {
                case .move(let id):
                    model.setActiveFrame(id); frameDragId = id
                    frameStartPos = model.document.composition(id)?.boardPosition ?? .zero
                    frameStartBoard = bv.toComp(Vec2(sp.x, sp.y))
                    mode = .frameMove; txn = model.store.begin("Move Frame")
                case .resize(let id, let cornerIdx):
                    model.setActiveFrame(id); frameDragId = id
                    if let f = model.document.composition(id) { frameStartPos = f.boardPosition; frameStartSize = f.size }
                    frameResizeCorner = cornerIdx
                    mode = .frameResize; txn = model.store.begin("Resize Frame")
                }
                return
            }
        }

        // Body hit-test → select + move; empty → marquee.
        let hit = HitTester.topLayer(in: model.document, compId: comp.id, at: t, compPoint: pressComp,
                                     textMeasurer: model.textEngine)
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
            // Empty press: inside the active frame → marquee; over another frame → focus it; on the
            // bare workspace → pan the board.
            let boardPt = pressComp + comp.boardPosition
            if let f = model.frame(atBoardPoint: boardPt) {
                if f != model.activeCompId { model.setActiveFrame(f); mode = .none }
                else { mode = .marquee; marqueeStart = CGPoint(x: sp.x, y: sp.y); marqueeCurrent = marqueeStart }
            } else {
                mode = .pan; panAccum = .zero
            }
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

    /// Draw-to-size: while dragging a freshly-created rect/ellipse, span press→cursor. Below a tiny
    /// threshold the layer keeps its default size (a plain click).
    private func dragCreate(_ cur: Vec2) {
        guard let txn, let id = createId else { return }
        if (cur - startComp).length > 4 {
            model.updateCreateRect(id, from: startComp, to: cur, within: txn)
        }
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
        let evaluated = SceneEvaluator(document: model.document, textMeasurer: model.textEngine)
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
        let evaluated = SceneEvaluator(document: model.document, textMeasurer: model.textEngine).evaluate(compId: comp.id, at: t)
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
        let evaluated = SceneEvaluator(document: model.document, textMeasurer: model.textEngine)
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
        let evaluated = SceneEvaluator(document: model.document, textMeasurer: model.textEngine).evaluate(compId: comp.id, at: t)
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
/// Type-aware property panel (editor-ui.md §4): common transform controls plus a section keyed to
/// the layer's content (shape fill/stroke/corner-radius/size, text size/tracking/fill, …). Every
/// field reads the resolved value at the playhead and writes through commands, auto-keyframing when
/// the track is animated; the diamond toggles a keyframe at the playhead.
struct InspectorView: View {
    let model: DocumentModel
    @State private var opacityTxn: TransactionID?

    private var t: TimeInterval { model.playback.currentTime }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let layer = model.selectedLayer {
                    NameEditor(model: model, id: layer.id, name: layer.name).id(layer.id)
                    Text(layer.content.typeName.capitalized)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Divider()

                    arrangeSection()
                    Divider()
                    transformSection(layer)

                    switch layer.content {
                    case .shape(let s): Divider(); shapeSection(layer.id, s)
                    case .text(let tc): Divider(); textSection(layer.id, tc)
                    case .image(let ic): Divider(); imageSection(layer.id, ic)
                    case .video:
                        Divider()
                        Text("Video editing (trim, replace) is coming.")
                            .font(.caption).foregroundStyle(.tertiary)
                    default: EmptyView()
                    }

                    Divider()
                    effectsSection(layer)

                    Divider()
                    PresetsView(model: model)
                    Spacer(minLength: 0)
                } else {
                    Text("No selection").foregroundStyle(.secondary)
                    Text("Pick a tool and click the canvas, or select a layer.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(.bar)
    }

    // MARK: Sections

    @ViewBuilder private func arrangeSection() -> some View {
        sectionLabel("Arrange")
        HStack(spacing: 2) {
            iconButton("align.horizontal.left", "Align left") { model.align(.left) }
            iconButton("align.horizontal.center", "Align center") { model.align(.hCenter) }
            iconButton("align.horizontal.right", "Align right") { model.align(.right) }
            Divider().frame(height: 16)
            iconButton("align.vertical.top", "Align top") { model.align(.top) }
            iconButton("align.vertical.center", "Align middle") { model.align(.vMiddle) }
            iconButton("align.vertical.bottom", "Align bottom") { model.align(.bottom) }
        }
        HStack(spacing: 2) {
            iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontal") { model.flip(horizontal: true) }
            iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertical") { model.flip(horizontal: false) }
            Divider().frame(height: 16)
            iconButton("square.3.layers.3d.top.filled", "Bring to front") { model.reorder(toFront: true) }
            iconButton("square.3.layers.3d.bottom.filled", "Send to back") { model.reorder(toFront: false) }
        }
    }

    private func iconButton(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).frame(width: 24, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }

    @ViewBuilder private func transformSection(_ layer: Layer) -> some View {
        let id = layer.id
        let position = layer.transform.position.resolve(at: t)
        let scale = layer.transform.scale.resolve(at: t)
        sectionLabel("Transform")
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
        ScrubbableField(title: "∠", value: layer.transform.rotation.resolve(at: t), format: "%.1f°", sensitivity: 0.5,
            onBegin: { model.store.begin("Rotation") },
            onChange: { v, txn in model.setRotation(id, to: v, within: txn) },
            onEnd: { model.store.commit($0) })
        HStack(spacing: 6) {
            ScrubbableField(title: "Scale W", value: scale.x * 100, format: "%.0f%%", sensitivity: 0.5,
                onBegin: { model.store.begin("Scale X") },
                onChange: { v, txn in model.setScale(id, to: Vec2(v / 100, liveScale(id).y), within: txn) },
                onEnd: { model.store.commit($0) })
            ScrubbableField(title: "H", value: scale.y * 100, format: "%.0f%%", sensitivity: 0.5,
                onBegin: { model.store.begin("Scale Y") },
                onChange: { v, txn in model.setScale(id, to: Vec2(liveScale(id).x, v / 100), within: txn) },
                onEnd: { model.store.commit($0) })
        }
        opacityRow(layer)
    }

    @ViewBuilder private func shapeSection(_ id: EntityID, _ s: ShapeContent) -> some View {
        sectionLabel("Shape")
        // Real dimensions (distinct from Scale — animating size keeps stroke width).
        let size = s.size.resolve(at: t)
        let sizePath = "\(id)/content/size"
        HStack(spacing: 6) {
            diamond(path: sizePath, isAnimated: s.size.isAnimated, times: keyTimes(s.size)) { .vec2(s.size.resolve(at: t)) }
            ScrubbableField(title: "W", value: size.x, format: "%.0f", sensitivity: 1,
                onBegin: { model.store.begin("Width") },
                onChange: { v, txn in model.setAnimatable(path: sizePath, value: .vec2(Vec2(max(v, 1), liveSize(id).y)), isAnimated: s.size.isAnimated, within: txn) },
                onEnd: { model.store.commit($0) })
            ScrubbableField(title: "H", value: size.y, format: "%.0f", sensitivity: 1,
                onBegin: { model.store.begin("Height") },
                onChange: { v, txn in model.setAnimatable(path: sizePath, value: .vec2(Vec2(liveSize(id).x, max(v, 1))), isAnimated: s.size.isAnimated, within: txn) },
                onEnd: { model.store.commit($0) })
        }
        if s.gradient == nil {
            colorRow("Fill", id, "content/fillColor", s.fillColor, defaultColor: .black)
        }
        gradientControls(id, s)
        colorRow("Stroke", id, "content/strokeColor", s.strokeColor, defaultColor: .clear)
        scalarRow("Stroke W", id, "content/strokeWidth", s.strokeWidth ?? .static(0), sensitivity: 0.5)
        if s.geometry == .rect {
            scalarRow("Radius", id, "content/cornerRadius", s.cornerRadius ?? .static(0), sensitivity: 0.5)
        }
        if s.geometry == .path {
            // Trim the stroke for line-drawing animations (fractions 0…1 of the path length).
            scalarRow("Trim Start", id, "content/trimStart", s.trimStart ?? .static(0), format: "%.2f", sensitivity: 0.01)
            scalarRow("Trim End", id, "content/trimEnd", s.trimEnd ?? .static(1), format: "%.2f", sensitivity: 0.01)
            scalarRow("Trim Offset", id, "content/trimOffset", s.trimOffset ?? .static(0), format: "%.2f", sensitivity: 0.01)
        }
    }

    /// Gradient fill: a toggle, and (when present) a linear/radial picker plus a color well per stop.
    /// Stop colors live in an array, so they write through `SetContent`, not the generic path system.
    @ViewBuilder private func gradientControls(_ id: EntityID, _ s: ShapeContent) -> some View {
        HStack(spacing: 6) {
            Text("Gradient").font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Button(s.gradient == nil ? "Add" : "Remove") { model.toggleGradient(id) }
                .font(.caption2).buttonStyle(.bordered)
            if let g = s.gradient {
                Picker("", selection: Binding(get: { g.kind },
                                              set: { model.setGradientKind(id, $0) })) {
                    Text("Linear").tag(GradientKind.linear)
                    Text("Radial").tag(GradientKind.radial)
                }.labelsHidden().frame(width: 90)
            }
            Spacer()
        }
        if let g = s.gradient {
            HStack(spacing: 6) {
                Text("Stops").font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                ForEach(Array(g.stops.enumerated()), id: \.offset) { idx, stop in
                    ColorPicker("", selection: Binding(
                        get: { stop.color.resolve(at: t).swiftUIColor },
                        set: { model.setGradientStopColor(id, stop: idx, color: ColorValue(swiftUI: $0)) }
                    ), supportsOpacity: true).labelsHidden()
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private func textSection(_ id: EntityID, _ tc: TextContent) -> some View {
        sectionLabel("Text")
        TextContentEditor(model: model, id: id, content: tc).id(id)
        scalarRow("Size", id, "content/fontSize", tc.fontSize, sensitivity: 0.5)
        scalarRow("Tracking", id, "content/tracking", tc.tracking ?? .static(0), format: "%.1f", sensitivity: 0.2)
        scalarRow("Line", id, "content/lineHeight", tc.lineHeight ?? .static(0), sensitivity: 0.5) // 0 = auto
        colorRow("Fill", id, "content/fillColor", tc.fillColor, defaultColor: .white)
    }

    @ViewBuilder private func imageSection(_ id: EntityID, _ ic: ImageContent) -> some View {
        sectionLabel("Image")
        Picker("Fit", selection: Binding(get: { ic.fit }, set: { model.setImageFit(id, $0) })) {
            Text("Fill").tag(FitMode.fill)
            Text("Fit").tag(FitMode.fit)
            Text("Stretch").tag(FitMode.stretch)
            Text("None").tag(FitMode.none)
        }.pickerStyle(.menu)
    }

    @ViewBuilder private func effectsSection(_ layer: Layer) -> some View {
        sectionLabel("Effects")
        ForEach(layer.effects, id: \.id) { fx in effectRow(layer.id, fx) }
        HStack(spacing: 6) {
            Button("+ Blur") { model.addBlur(to: layer.id) }.controlSize(.small)
            Button("+ Shadow") { model.addShadow(to: layer.id) }.controlSize(.small)
            Button("+ BG Blur") { model.addBackgroundBlur(to: layer.id) }.controlSize(.small)
            Button("+ Color") { model.addColorAdjust(to: layer.id) }.controlSize(.small)
            Spacer()
        }
    }

    @ViewBuilder private func effectRow(_ id: EntityID, _ fx: Effect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(fx.type.capitalized).font(.caption.weight(.medium))
                Spacer()
                Button { model.removeEffect(id, fx.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove effect")
            }
            let base = "effects/\(fx.id)/params"
            switch fx.type {
            case "blur", "backgroundBlur":
                if case .scalar(let r)? = fx.params["radius"] { scalarRow("Radius", id, "\(base)/radius", r, sensitivity: 0.5) }
            case "shadow":
                if case .scalar(let r)? = fx.params["radius"] { scalarRow("Radius", id, "\(base)/radius", r, sensitivity: 0.5) }
                if case .vec2(let o)? = fx.params["offset"] { vec2Row("X", "Y", id, "\(base)/offset", o) }
                if case .color(let c)? = fx.params["color"] { colorRow("Color", id, "\(base)/color", c, defaultColor: .black) }
                if case .scalar(let op)? = fx.params["opacity"] { scalarRow("Opacity", id, "\(base)/opacity", op, format: "%.2f", sensitivity: 0.01) }
            case "colorAdjust":
                if case .scalar(let v)? = fx.params["brightness"] { scalarRow("Bright", id, "\(base)/brightness", v, format: "%.2f", sensitivity: 0.01) }
                if case .scalar(let v)? = fx.params["contrast"] { scalarRow("Contrast", id, "\(base)/contrast", v, format: "%.2f", sensitivity: 0.01) }
                if case .scalar(let v)? = fx.params["saturation"] { scalarRow("Saturate", id, "\(base)/saturation", v, format: "%.2f", sensitivity: 0.01) }
                if case .scalar(let v)? = fx.params["hue"] { scalarRow("Hue", id, "\(base)/hue", v, format: "%.0f", sensitivity: 1) }
            default: EmptyView()
            }
        }
        .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    /// A diamond + two scrubbable fields bound to a vec2 `AnimatableValue` at `id/prop`.
    private func vec2Row(_ tX: String, _ tY: String, _ id: EntityID, _ prop: String,
                         _ av: AnimatableValue<Vec2>, sensitivity: Double = 1) -> some View {
        let path = "\(id)/\(prop)"
        let v = av.resolve(at: t)
        return HStack(spacing: 6) {
            diamond(path: path, isAnimated: av.isAnimated, times: keyTimes(av)) { .vec2(av.resolve(at: t)) }
            ScrubbableField(title: tX, value: v.x, format: "%.0f", sensitivity: sensitivity,
                onBegin: { model.store.begin(tX) },
                onChange: { nv, txn in model.setAnimatable(path: path, value: .vec2(Vec2(nv, av.resolve(at: t).y)), isAnimated: av.isAnimated, within: txn) },
                onEnd: { model.store.commit($0) })
            ScrubbableField(title: tY, value: v.y, format: "%.0f", sensitivity: sensitivity,
                onBegin: { model.store.begin(tY) },
                onChange: { nv, txn in model.setAnimatable(path: path, value: .vec2(Vec2(av.resolve(at: t).x, nv)), isAnimated: av.isAnimated, within: txn) },
                onEnd: { model.store.commit($0) })
        }
    }

    @ViewBuilder private func opacityRow(_ layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                keyButton(layer.id, .opacity)
                Text(String(format: "Opacity  %.0f%%", layer.transform.opacity.resolve(at: t) * 100)).font(.caption)
                Spacer()
                Picker("", selection: Binding(get: { layer.blendMode },
                                              set: { model.setBlendMode(layer.id, $0) })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.labelsHidden().frame(width: 104).help("Blend mode")
            }
            HStack {
                Text("Matte").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { layer.trackMatte },
                                              set: { model.setTrackMatte(layer.id, $0) })) {
                    Text("None").tag(TrackMatte?.none)
                    Text("Alpha").tag(TrackMatte?.some(.alpha))
                    Text("Alpha Inv").tag(TrackMatte?.some(.alphaInverted))
                    Text("Luma").tag(TrackMatte?.some(.luma))
                    Text("Luma Inv").tag(TrackMatte?.some(.lumaInverted))
                }.labelsHidden().frame(width: 104).help("Track matte — masked by the layer above")
            }
            Slider(value: Binding(
                get: { layer.transform.opacity.resolve(at: model.playback.currentTime) },
                set: { if let txn = opacityTxn { model.setOpacity(layer.id, to: $0, within: txn) } }
            ), in: 0...1, onEditingChanged: { editing in
                if editing { opacityTxn = model.store.begin("Opacity") }
                else if let txn = opacityTxn { model.store.commit(txn); opacityTxn = nil }
            })
        }
    }

    // MARK: Reusable rows

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// A diamond + scrubbable bound to a scalar `AnimatableValue` at `id/prop`.
    private func scalarRow(_ title: String, _ id: EntityID, _ prop: String, _ av: AnimatableValue<Double>,
                           format: String = "%.0f", sensitivity: Double = 1) -> some View {
        let path = "\(id)/\(prop)"
        return HStack(spacing: 6) {
            diamond(path: path, isAnimated: av.isAnimated, times: keyTimes(av)) { .scalar(av.resolve(at: t)) }
            ScrubbableField(title: title, value: av.resolve(at: t), format: format, sensitivity: sensitivity,
                onBegin: { model.store.begin(title) },
                onChange: { v, txn in model.setAnimatable(path: path, value: .scalar(v), isAnimated: av.isAnimated, within: txn) },
                onEnd: { model.store.commit($0) })
        }
    }

    /// A diamond + color well bound to a (possibly nil) color `AnimatableValue` at `id/prop`.
    private func colorRow(_ title: String, _ id: EntityID, _ prop: String,
                          _ av: AnimatableValue<ColorValue>?, defaultColor: ColorValue) -> some View {
        let path = "\(id)/\(prop)"
        let current = av?.resolve(at: t) ?? defaultColor
        let isAnimated = av?.isAnimated ?? false
        let times = av.map(keyTimes) ?? []
        return HStack(spacing: 6) {
            diamond(path: path, isAnimated: isAnimated, times: times) { .color(current) }
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { current.swiftUIColor },
                set: { model.setAnimatableOnce(path: path, value: .color(ColorValue(swiftUI: $0)),
                                                isAnimated: isAnimated, label: title) }
            ), supportsOpacity: true).labelsHidden()
            Spacer()
        }
    }

    private func diamond(path: String, isAnimated: Bool, times: [TimeInterval],
                         value: @escaping () -> AnyValue) -> some View {
        let tol = 0.5 / max(model.mainComp?.fps ?? 60, 1)
        let active = times.contains { abs($0 - t) <= tol }
        return Button { model.toggleKeyframe(path: path, value: value(), existingTimes: times) } label: {
            Image(systemName: active ? "diamond.fill" : "diamond")
                .font(.system(size: 10)).foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain).help("Toggle keyframe at playhead")
    }

    private func keyTimes<V>(_ av: AnimatableValue<V>) -> [TimeInterval] { TimelineDigest.keyframeTimes(of: av) }

    private func livePosition(_ id: EntityID) -> Vec2 {
        model.layer(id)?.transform.position.resolve(at: model.playback.currentTime) ?? .zero
    }
    private func liveScale(_ id: EntityID) -> Vec2 {
        model.layer(id)?.transform.scale.resolve(at: model.playback.currentTime) ?? .one
    }
    private func liveSize(_ id: EntityID) -> Vec2 {
        if case .shape(let s)? = model.layer(id)?.content { return s.size.resolve(at: model.playback.currentTime) }
        return .one
    }

    /// Keyframe toggle for the transform props that have a typed helper (position/opacity).
    private func keyButton(_ layerId: EntityID, _ property: DocumentModel.KeyframeProperty) -> some View {
        let active = model.hasKeyframeAtPlayhead(layerId, property)
        return Button { model.toggleKeyframe(layerId, property) } label: {
            Image(systemName: active ? "diamond.fill" : "diamond")
                .font(.system(size: 10)).foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain).help("Toggle keyframe at playhead")
    }
}

/// Editable layer name (commits one `SetLayerName` on Return). Local `@State` so typing has the
/// field's own undo; `.id(layer.id)` on the call site reseeds it when the selection changes.
private struct NameEditor: View {
    let model: DocumentModel
    let id: EntityID
    @State private var name: String
    init(model: DocumentModel, id: EntityID, name: String) {
        self.model = model; self.id = id; _name = State(initialValue: name)
    }
    var body: some View {
        TextField("Layer name", text: $name)
            .textFieldStyle(.plain).font(.headline)
            .onSubmit { model.renameLayer(id, to: name) }
    }
}

/// Inline frame-rename field (board overlay). Commits on Return, cancels on Escape, and auto-focuses
/// so the user can type immediately after the double-click.
struct FrameNameField: View {
    @State private var name: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    init(initial: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _name = State(initialValue: initial)
        self.onCommit = onCommit; self.onCancel = onCancel
    }

    var body: some View {
        TextField("Frame name", text: $name)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .focused($focused)
            .onSubmit { onCommit(name) }
            .onExitCommand { onCancel() }
            .onAppear { focused = true }
    }
}

/// Structural text editing — string, font family (commit on Return), and alignment (commit on
/// change) — each via one `SetContent` (editor-ui.md §4 / undo-system.md §7).
private struct TextContentEditor: View {
    let model: DocumentModel
    let id: EntityID
    let content: TextContent
    @State private var string: String
    @State private var family: String
    init(model: DocumentModel, id: EntityID, content: TextContent) {
        self.model = model; self.id = id; self.content = content
        _string = State(initialValue: content.string)
        _family = State(initialValue: content.fontFamily)
    }
    var body: some View {
        TextField("Text", text: $string).textFieldStyle(.roundedBorder)
            .onSubmit { model.editText(id) { $0.string = string } }
        TextField("Font", text: $family).textFieldStyle(.roundedBorder)
            .onSubmit { model.editText(id) { $0.fontFamily = family } }
        Picker("", selection: Binding(get: { content.alignment },
                                      set: { a in model.editText(id) { $0.alignment = a } })) {
            Image(systemName: "text.alignleft").tag(MotionKernel.TextAlignment.left)
            Image(systemName: "text.aligncenter").tag(MotionKernel.TextAlignment.center)
            Image(systemName: "text.alignright").tag(MotionKernel.TextAlignment.right)
        }.pickerStyle(.segmented).labelsHidden()
    }
}

/// SwiftUI ↔ kernel color bridging for the inspector color wells (sRGB, matching ColorValue storage).
extension ColorValue {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(swiftUI color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
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
