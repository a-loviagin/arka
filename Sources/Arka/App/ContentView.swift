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
                VStack(spacing: 0) {
                    CanvasArea(model: model)
                        .frame(minWidth: 480, minHeight: 270)
                    transportBar
                }
                Divider()
                InspectorView(model: model)
                    .frame(width: 240)
            }
            Divider()
            TimelineView(model: model)
        }
        .frame(minWidth: 860, minHeight: 600)
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
#endif
