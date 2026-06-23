#if os(macOS)
import Foundation
import MotionKernel
import MotionRender
import MotionAI

/// "Teach the style" ingestion (ai-pipeline.md §3). Dropped reference clips are analyzed once (vision
/// + frame sampling) into a `VideoMotionAnalysis` and stored as data — global, per-project, or a
/// one-shot reference for the next prompt. This is retrieval/conditioning, not model training: the
/// stored analyses are re-injected per request (few-shot exemplars + an aggregate profile), so
/// removing a clip removes its influence. Weights never change.
extension DocumentModel {
    // MARK: Persistence locations

    private static var tasteDir: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true).appending(path: "Arka/taste")
    }
    private var globalTasteURL: URL? { Self.tasteDir?.appending(path: "global.json") }
    private var projectTasteURL: URL? {
        Self.tasteDir?.appending(path: "project-\(document.id).json")
    }

    func loadTaste() {
        if let url = globalTasteURL { globalTaste = TasteStore.load(from: url) }
        if let url = projectTasteURL { projectTaste = TasteStore.load(from: url) }
    }

    private func saveTaste(_ scope: TasteScope) {
        switch scope {
        case .global: if let url = globalTasteURL { try? globalTaste.save(to: url) }
        case .project: if let url = projectTasteURL { try? projectTaste.save(to: url) }
        case .oneShot: break
        }
    }

    // MARK: Merged view used at generation time

    /// Built-in exemplars + everything ingested (global + project), as the retrieval library.
    func effectiveLibrary(extra: [Exemplar] = []) -> ExemplarLibrary {
        ExemplarLibrary(ExemplarLibrary.builtin.exemplars
                        + globalTaste.exemplars + projectTaste.exemplars + extra)
    }

    /// Aggregate house style across all ingested clips (global + project).
    func effectiveProfile() -> TasteProfile? {
        TasteProfile.from(globalTaste.analyses + projectTaste.analyses)
    }

    // MARK: Ingestion

    /// Sample + analyze a reference clip and route it to the chosen scope. Requires a vision-capable
    /// key for the analysis; surfaces a clear status otherwise. Runs off the prompt path.
    @MainActor
    func ingestClip(url: URL, scope: TasteScope) async {
        guard let analyzer = ClaudeVideoAnalyzer.fromEnvironment() else {
            tasteStatus = "Set ANTHROPIC_API_KEY to analyze reference clips."
            return
        }
        tasteStatus = "Analyzing \(url.lastPathComponent)…"
        do {
            let sampled = try await ClipFrameSampler.sample(url: url, count: 12)
            let analysis = try await analyzer.analyze(frames: sampled.frames, fps: sampled.fps,
                                                      hint: url.deletingPathExtension().lastPathComponent)
            let id = "clip_\(UInt32.random(in: 0 ..< .max))"
            switch scope {
            case .global: globalTaste.add(analysis, id: id); saveTaste(.global)
            case .project: projectTaste.add(analysis, id: id); saveTaste(.project)
            case .oneShot: pendingReference = analysis
            }
            tasteStatus = scope == .oneShot
                ? "Reference ready — it will guide your next prompt."
                : "Learned “\(analysis.summary)”."
        } catch {
            tasteStatus = "Couldn’t analyze that clip: \(error.localizedDescription)"
        }
    }

    func removeTaste(id: String, scope: TasteScope) {
        switch scope {
        case .global: globalTaste.removeExemplar(id: id); saveTaste(.global)
        case .project: projectTaste.removeExemplar(id: id); saveTaste(.project)
        case .oneShot: pendingReference = nil
        }
    }
}
#endif
