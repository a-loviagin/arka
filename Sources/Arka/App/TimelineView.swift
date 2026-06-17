#if os(macOS)
import SwiftUI
import AppKit
import MotionKernel

/// The timeline dope-sheet (editor-ui.md §3): a scrubbable ruler/playhead, a row per layer with
/// sub-rows for each animated property, and keyframe diamonds you can drag to retime. Retiming is a
/// `MoveKeyframes` command in one transaction (one ⌘Z step); drags snap to frame boundaries unless
/// ⌘ is held. v1 is SwiftUI (the spec's tiled-CoreGraphics view is a later performance upgrade).
struct TimelineView: View {
    let model: DocumentModel

    private let leftWidth: CGFloat = 170
    private let rowHeight: CGFloat = 20

    @State private var dragPath: String?
    @State private var dragOriginT: Double = 0
    @State private var dragLastT: Double = 0
    @State private var dragTxn: TransactionID?

    var body: some View {
        GeometryReader { geo in
            let trackWidth = max(geo.size.width - leftWidth, 1)
            let duration = max(model.mainComp?.duration ?? 5, 0.001)
            let fps = model.mainComp?.fps ?? 60

            VStack(spacing: 0) {
                ruler(trackWidth: trackWidth, duration: duration)
                Divider()
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(layersTopFirst, id: \.id) { layer in
                            layerHeader(layer)
                            ForEach(TimelineDigest.tracks(for: layer), id: \.path) { track in
                                propertyRow(track, trackWidth: trackWidth, duration: duration, fps: fps)
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) { playhead(trackWidth: trackWidth, duration: duration) }
        }
        .frame(height: 200)
        .background(.bar)
    }

    private var layersTopFirst: [Layer] {
        (model.mainComp?.layersInRenderOrder ?? []).reversed()
    }

    // MARK: Ruler + playhead

    private func ruler(trackWidth: CGFloat, duration: Double) -> some View {
        HStack(spacing: 0) {
            Text("Timeline").font(.caption).foregroundStyle(.secondary)
                .frame(width: leftWidth, alignment: .leading).padding(.leading, 8)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.08))
                ForEach(tickTimes(duration: duration), id: \.self) { t in
                    let xpos = CGFloat(t / duration) * trackWidth
                    Path { p in p.move(to: CGPoint(x: xpos, y: 14)); p.addLine(to: CGPoint(x: xpos, y: 22)) }
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    Text(String(format: "%.1fs", t)).font(.system(size: 9)).foregroundStyle(.secondary)
                        .position(x: xpos + 12, y: 8)
                }
            }
            .frame(width: trackWidth, height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.playback.seek(to: clampTime(Double(value.location.x / trackWidth) * duration, duration))
            })
        }
        .frame(height: 22)
    }

    private func playhead(trackWidth: CGFloat, duration: Double) -> some View {
        let x = leftWidth + CGFloat(model.playback.currentTime / duration) * trackWidth
        return Rectangle().fill(Color.red).frame(width: 1)
            .offset(x: x)
            .allowsHitTesting(false)
    }

    // MARK: Rows

    private func layerHeader(_ layer: Layer) -> some View {
        let selected = model.selection.contains(layer.id)
        return HStack(spacing: 6) {
            Image(systemName: icon(for: layer.content)).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(layer.name.isEmpty ? "Layer" : layer.name).font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [layer.id] }
    }

    private func propertyRow(_ track: PropertyTrack, trackWidth: CGFloat, duration: Double, fps: Double) -> some View {
        HStack(spacing: 0) {
            Text(track.label).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: leftWidth, alignment: .leading).padding(.leading, 24)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.05))
                ForEach(track.times.indices, id: \.self) { i in
                    diamond(path: track.path, t: track.times[i],
                            trackWidth: trackWidth, duration: duration, fps: fps)
                }
            }
            .frame(width: trackWidth, height: rowHeight)
        }
        .frame(height: rowHeight)
    }

    private func diamond(path: String, t: Double, trackWidth: CGFloat, duration: Double, fps: Double) -> some View {
        let x = CGFloat(t / duration) * trackWidth
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .offset(x: x - 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle().size(width: 14, height: rowHeight).offset(x: x - 7))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragTxn == nil {
                        // Select the owning layer and open the retime transaction.
                        model.selection = [EntityID(String(path.split(separator: "/").first ?? ""))]
                        dragPath = path; dragOriginT = t; dragLastT = t
                        dragTxn = model.store.begin("Move Keyframe")
                    }
                    guard let txn = dragTxn else { return }
                    let deltaT = Double(value.translation.width / trackWidth) * duration
                    let snapped = snap(dragOriginT + deltaT, fps: fps, duration: duration)
                    if abs(snapped - dragLastT) > 1e-6 {
                        try? model.store.perform(
                            .moveKeyframes(moves: [.init(path: path, oldT: dragLastT, newT: snapped)]),
                            in: txn)
                        dragLastT = snapped
                    }
                }
                .onEnded { _ in
                    if let txn = dragTxn { model.store.commit(txn); dragTxn = nil; dragPath = nil }
                })
    }

    // MARK: Helpers

    private func snap(_ t: Double, fps: Double, duration: Double) -> Double {
        let free = NSEvent.modifierFlags.contains(.command)
        let snapped = free ? t : (t * fps).rounded() / fps
        return clampTime(snapped, duration)
    }
    private func clampTime(_ t: Double, _ duration: Double) -> Double { min(max(t, 0), duration) }

    private func tickTimes(duration: Double) -> [Double] {
        let target = 6.0
        let raw = duration / target
        let step = [0.1, 0.25, 0.5, 1, 2, 5].first(where: { $0 >= raw }) ?? 5
        return stride(from: 0, through: duration, by: step).map { $0 }
    }

    private func icon(for content: LayerContent) -> String {
        switch content {
        case .shape: "square.on.circle"
        case .text: "textformat"
        case .image: "photo"
        case .video: "film"
        case .precomp: "rectangle.stack"
        case .group, .null: "folder"
        }
    }
}
#endif
