#if os(macOS)
import SwiftUI
import MotionKernel

/// The creator's review inbox (multiplayer.md): comments viewers left on the shared playback. Click
/// one to jump the playhead to its time and surface its pin on the canvas.
struct ReviewPanel: View {
    let model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Review").font(.headline)
                Spacer()
                Button { Task { await model.fetchReviewComments() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh comments")
                Button { model.reviewPanelVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            if let url = model.lastShareURL {
                Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("Share the board or a frame to collect review comments.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.reviewComments.isEmpty {
                Text("No comments yet.").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.reviewComments) { c in row(c) }
                    }
                }.frame(maxHeight: 280)
            }
            if let status = model.shareStatus { Text(status).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(12)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }

    private func row(_ c: ReviewComment) -> some View {
        Button { model.goToComment(c) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(String(format: "%.2fs", c.time)).font(.caption.monospacedDigit()).foregroundStyle(.blue)
                    if c.pin != nil { Image(systemName: "mappin").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text(c.author).font(.caption2).foregroundStyle(.secondary)
                }
                Text(c.text).font(.caption).foregroundStyle(.primary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider(), alignment: .bottom)
    }
}
#endif
