#if os(macOS)
import SwiftUI
import MotionKernel

/// The SwiftUI shell (editor-ui.md §1). v1 is the canvas + a transport bar; the inspector, layer
/// list, timeline, and AI panel are later surfaces that hang off the same `(document, state)` reads.
struct ContentView: View {
    let model: DocumentModel

    private var playback: PlaybackController { model.playback }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LayerListView(model: model)
                    .frame(width: 190)
                Divider()
                VStack(spacing: 0) {
                    CanvasArea(model: model)
                        .frame(minWidth: 420, minHeight: 270)
                    transportBar
                }
                Divider()
                InspectorView(model: model)
                    .frame(width: 240)
            }
            Divider()
            TimelineView(model: model)
        }
        .frame(minWidth: 1040, minHeight: 600)
        .overlay(alignment: .top) {
            if model.aiPanelVisible {
                AICommandPanel(model: model)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.aiPanelVisible)
        .sheet(isPresented: Binding(get: { model.exportSheetVisible },
                                    set: { model.exportSheetVisible = $0 })) {
            ExportSheet(model: model)
        }
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button(action: { playback.togglePlay() }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24)
            }
            .keyboardShortcut(.space, modifiers: [])

            Text(timeLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Slider(value: Binding(get: { playback.currentTime },
                                  set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.001))

            Toggle("Loop", isOn: Binding(get: { playback.loops },
                                         set: { playback.loops = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var timeLabel: String {
        let fps = model.document.mainComposition?.fps ?? 60
        let frame = Int((playback.currentTime * fps).rounded())
        return String(format: "%.2fs · f%d", playback.currentTime, frame)
    }
}

/// The ⌘K prompt bar (ai-pipeline.md §7): a natural-language prompt that generates and applies a
/// motion edit. Falls back to the offline heuristic generator when no API key is configured, so the
/// panel always works. Esc closes; Return submits.
struct AICommandPanel: View {
    let model: DocumentModel
    @State private var prompt = ""
    @FocusState private var focused: Bool

    private var isGenerating: Bool {
        if case .generating = model.aiState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                TextField("Describe the animation… (e.g. “pop the logo in, bouncy”)", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(submit)
                    .disabled(isGenerating)
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Generate", action: submit)
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack(spacing: 6) {
                let scope = model.selection.isEmpty ? "all layers" : "\(model.selection.count) selected"
                Text(model.aiUsesLiveModel ? "Claude · \(scope)" : "Offline · \(scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = model.aiState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(message)
                }
                Spacer()
                Button("Close") { model.aiPanelVisible = false }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(12)
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(radius: 18, y: 6)
        .onAppear { focused = true }
    }

    private func submit() {
        let text = prompt
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !isGenerating else { return }
        prompt = ""
        Task { await model.generate(prompt: text) }
    }
}
#endif
