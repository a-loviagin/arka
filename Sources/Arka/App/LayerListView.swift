#if os(macOS)
import SwiftUI
import MotionKernel

/// Layer list (editor-ui.md §4), grouped by frame. Each frame (composition) is a section: the header
/// activates that frame on click and carries a delete affordance (every frame but the main one);
/// under it sit that frame's layers in top-of-stack-first order with type icon, name, and a
/// visibility toggle. Selecting a layer also activates its frame. Drag-to-reorder is enabled only
/// within the active frame and emits `ReorderLayer` with a fractional `SortKey` minted between the
/// new neighbors. The bottom bar adds a frame.
struct LayerListView: View {
    let model: DocumentModel

    private func layersTopFirst(_ comp: Composition) -> [Layer] {
        comp.layersInRenderOrder.reversed()
    }

    var body: some View {
        List(selection: Binding(get: { model.selection },
                                set: { newSel in
                                    // Selecting a layer in another frame switches the active frame
                                    // to its owner (clears `newSel`), so activate first then re-apply.
                                    if let id = newSel.first,
                                       let owner = model.frames.first(where: { $0.layer(id) != nil }),
                                       owner.id != model.activeCompId {
                                        model.setActiveFrame(owner.id)
                                    }
                                    model.selection = newSel
                                })) {
            ForEach(model.frames, id: \.id) { frame in
                Section {
                    let layers = layersTopFirst(frame)
                    ForEach(layers, id: \.id) { layer in
                        row(layer).tag(layer.id)
                    }
                    .onMove { source, destination in
                        if frame.id == model.activeCompId { move(frame, from: source, to: destination) }
                    }
                } header: {
                    frameHeader(frame)
                }
            }
        }
        .listStyle(.sidebar) // macOS List supports onMove drag-reorder natively
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    let s = model.mainComp?.size ?? Vec2(1920, 1080)
                    model.addFrame(width: s.x, height: s.y)
                } label: {
                    Label("Frame", systemImage: "plus.rectangle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func frameHeader(_ frame: Composition) -> some View {
        let isActive = frame.id == model.activeCompId
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 10))
            Text(frame.name.isEmpty ? "Frame" : frame.name)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            Text("\(Int(frame.size.x))×\(Int(frame.size.y))")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
            if frame.id != model.document.mainCompositionId {
                Button {
                    model.removeFrame(frame.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .contentShape(Rectangle())
        .onTapGesture { model.setActiveFrame(frame.id) }
    }

    private func row(_ layer: Layer) -> some View {
        HStack(spacing: 6) {
            Button {
                model.setVisible(layer.id, !layer.visible)
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.visible ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: icon(for: layer.content)).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(layer.name.isEmpty ? "Layer" : layer.name)
                .font(.system(size: 12))
                .foregroundStyle(layer.visible ? Color.primary : Color.secondary)
            Spacer()
        }
    }

    private func move(_ frame: Composition, from source: IndexSet, to destination: Int) {
        var display = layersTopFirst(frame)
        guard let movedIndex = source.first else { return }
        let movedId = display[movedIndex].id
        display.move(fromOffsets: source, toOffset: destination)
        // Render order is bottom→top (ascending sortKey) = reverse of the displayed order.
        let render = Array(display.reversed())
        guard let idx = render.firstIndex(where: { $0.id == movedId }) else { return }
        let lower = idx > 0 ? render[idx - 1].sortKey : nil
        let upper = idx < render.count - 1 ? render[idx + 1].sortKey : nil
        model.setSortKey(movedId, SortKey.between(lower, upper))
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
