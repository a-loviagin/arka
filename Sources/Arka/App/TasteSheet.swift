#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MotionAI

/// "Teach the style" sheet (ai-pipeline.md §3): drop/add reference clips into a scope and see what
/// the tool has learned. This is library curation — references re-injected per request — not model
/// training; remove a clip and its influence is gone. Scope: a global default, this project, or a
/// one-shot reference for the next prompt only.
struct TasteSheet: View {
    let model: DocumentModel
    @State private var scope: DocumentModel.TasteScope = .project

    private var store: TasteStore {
        scope == .global ? model.globalTaste : model.projectTaste
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Teach Style from Reference Clips").font(.title3).bold()
            Text("Clips are analyzed into editable taste and re-used to guide future prompts. "
                 + "This isn’t training — remove a clip and its influence is gone.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Apply to", selection: $scope) {
                Text("This Project").tag(DocumentModel.TasteScope.project)
                Text("Global (all projects)").tag(DocumentModel.TasteScope.global)
                Text("Next prompt only").tag(DocumentModel.TasteScope.oneShot)
            }
            .pickerStyle(.segmented)

            if scope == .oneShot {
                Text(model.pendingReference == nil
                     ? "Add a clip to guide just your next prompt."
                     : "Reference ready: “\(model.pendingReference!.summary)”.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                learnedList
            }

            if let profile = model.effectiveProfile() {
                Text(profile.doctrine()).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.tasteStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Add Reference Clip…") { addClip() }
                Spacer()
                Button("Done") { model.tasteSheetVisible = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var learnedList: some View {
        if store.exemplars.isEmpty {
            Text("No reference clips yet.").font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        } else {
            List {
                ForEach(store.exemplars, id: \.id) { ex in
                    HStack {
                        Image(systemName: "film").foregroundStyle(.secondary)
                        Text(ex.intent).font(.system(size: 12)).lineLimit(2)
                        Spacer()
                        Button { model.removeTaste(id: ex.id, scope: scope) } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 160)
        }
    }

    private func addClip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie, .gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scope = scope
        Task { await model.ingestClip(url: url, scope: scope) }
    }
}
#endif
