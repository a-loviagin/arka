#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import MotionKernel
import MotionRender

/// The rendered export formats (export-and-format.md §1). Lottie is a separate translator (its own
/// menu item), not part of this sheet.
enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4, proRes, gif, webP, pngSequence
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: "MP4"
        case .proRes: "ProRes"
        case .gif: "GIF"
        case .webP: "WebP"
        case .pngSequence: "PNG Seq"
        }
    }
    var blurb: String {
        switch self {
        case .mp4: "H.264 video — universal."
        case .proRes: "ProRes 4444 with alpha — editorial / compositing."
        case .gif: "Looping GIF — chat & docs."
        case .webP: "Animated WebP — smaller & better than GIF, works most places."
        case .pngSequence: "Numbered PNG frames — further processing."
        }
    }
    var allowsTransparency: Bool { self == .proRes || self == .pngSequence || self == .webP }
    var fpsCap: Double? { self == .gif ? 50 : nil }
    var suggestedName: String { self == .pngSequence ? "arka-frames" : "arka.\(rawValue == "proRes" ? "mov" : (self == .mp4 ? "mp4" : rawValue))" }
    var contentTypes: [UTType] {
        switch self {
        case .mp4: [.mpeg4Movie]
        case .proRes: [.quickTimeMovie]
        case .gif: [.gif]
        case .webP: [.webP]
        case .pngSequence: []
        }
    }
    /// Coarse bytes-per-pixel-per-frame factor for the live size estimate (order-of-magnitude only).
    var bppFactor: Double {
        switch self {
        case .mp4: 0.10
        case .proRes: 1.6
        case .gif: 0.45
        case .webP: 0.12
        case .pngSequence: 2.2
        }
    }
}

struct ExportSettings {
    var format: ExportFormat = .mp4
    var fps: Double = 30
    var scale: Double = 1.0
    var transparent: Bool = false
}

/// Preset-first export sheet (export-and-format.md §3): pick a format, tune the few settings that
/// matter, see a live size estimate, export. The actual job (save panel + off-main render) is run by
/// the closure the AppDelegate installs on the model.
struct ExportSheet: View {
    let model: DocumentModel
    @State private var s = ExportSettings()

    private var comp: Composition? { model.mainComp }
    private var formats: [ExportFormat] {
        ExportFormat.allCases.filter { $0 != .webP || WebPExporter.isAvailable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title3).bold()

            Picker("Format", selection: $s.format) {
                ForEach(formats) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(s.format.blurb).font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Scale").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $s.scale) {
                        Text("25%").tag(0.25); Text("50%").tag(0.5)
                        Text("100%").tag(1.0); Text("200%").tag(2.0)
                    }.labelsHidden().frame(width: 90)
                    Text(dimensionsLabel).font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("FPS").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("", value: $s.fps, format: .number).frame(width: 56)
                        Stepper("", value: $s.fps, in: 1...(s.format.fpsCap ?? 120), step: 1).labelsHidden()
                    }
                    if let cap = s.format.fpsCap { Text("max \(Int(cap))").font(.caption).foregroundStyle(.tertiary) }
                }
                if s.format.allowsTransparency {
                    GridRow {
                        Text("Background").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                        Toggle("Transparent", isOn: $s.transparent)
                    }
                }
            }

            HStack {
                Text("≈ \(sizeEstimate)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(frameCount) frames · \(String(format: "%.1f", duration))s")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.exportSheetVisible = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    var settings = s
                    if let cap = s.format.fpsCap { settings.fps = min(settings.fps, cap) }
                    model.exportSheetVisible = false
                    model.runExport?(settings)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { if s.fps == 30, let f = comp?.fps { s.fps = f } }
    }

    private var duration: Double { comp?.duration ?? 0 }
    private var frameCount: Int { max(Int((duration * effectiveFps).rounded()), 1) }
    private var effectiveFps: Double { min(s.fps, s.format.fpsCap ?? s.fps) }
    private var pixelW: Int { Int((comp?.size.x ?? 0) * s.scale) }
    private var pixelH: Int { Int((comp?.size.y ?? 0) * s.scale) }
    private var dimensionsLabel: String { "\(pixelW)×\(pixelH) px" }

    private var sizeEstimate: String {
        let bytes = Double(pixelW * pixelH) * Double(frameCount) * s.format.bppFactor
        if bytes > 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        return String(format: "%.0f KB", max(bytes / 1000, 1))
    }
}
#endif
