#if os(macOS)
import SwiftUI
import MotionKernel

/// Layer list (editor-ui.md §4): the layers in top-of-stack-first order with type icon, name, and a
/// visibility toggle. Selection is synced with the canvas/timeline; drag-to-reorder emits
/// `ReorderLayer` with a fractional `SortKey` minted between the new neighbors (the UI thinks in
/// rows; conversion to sort keys happens here at the command boundary).
struct LayerListView: View {
    let model: DocumentModel

    private var layersTopFirst: [Layer] {
        (model.mainComp?.layersInRenderOrder ?? []).reversed()
    }

    var body: some View {
        List(selection: Binding(get: { model.selection },
                                set: { model.selection = $0 })) {
            ForEach(layersTopFirst, id: \.id) { layer in
                row(layer).tag(layer.id)
            }
            .onMove(perform: move)
        }
        .listStyle(.sidebar) // macOS List supports onMove drag-reorder natively
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

    private func move(from source: IndexSet, to destination: Int) {
        var display = layersTopFirst
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
