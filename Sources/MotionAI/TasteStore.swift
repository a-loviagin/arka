import Foundation

/// A persisted collection of ingested reference-clip taste (ai-pipeline.md §3) — the data behind
/// "drop clips to teach the style." This is **not** model training: each clip is analyzed once into
/// a `VideoMotionAnalysis`, kept here as data, and re-injected per request (retrieved exemplars +
/// an aggregate profile). The model's weights never change; remove a clip and its influence is gone.
///
/// Scope is just *which store* a clip lands in — a global default and a per-project store, merged at
/// request time. Stores hold only the small analyses + synthesized exemplars (JSON), never the video
/// bytes.
public struct TasteStore: Codable, Sendable, Equatable {
    public var exemplars: [Exemplar]
    public var analyses: [VideoMotionAnalysis]

    public init(exemplars: [Exemplar] = [], analyses: [VideoMotionAnalysis] = []) {
        self.exemplars = exemplars
        self.analyses = analyses
    }

    public var isEmpty: Bool { exemplars.isEmpty && analyses.isEmpty }

    /// This store's exemplars as a retrieval library.
    public var exemplarLibrary: ExemplarLibrary { ExemplarLibrary(exemplars) }
    /// Aggregate taste profile across this store's analyses.
    public var profile: TasteProfile? { TasteProfile.from(analyses) }

    /// Add an analyzed clip: keep the analysis (for the aggregate profile) and a synthesized,
    /// retrievable exemplar (for few-shot). `id` should be stable/unique (the caller mints it).
    public mutating func add(_ analysis: VideoMotionAnalysis, id: String) {
        analyses.append(analysis)
        exemplars.append(TasteSynthesizer.exemplar(from: analysis, id: id))
    }

    public mutating func removeExemplar(id: String) {
        if let i = exemplars.firstIndex(where: { $0.id == id }) {
            exemplars.remove(at: i)
            if analyses.indices.contains(i) { analyses.remove(at: i) } // added in lockstep
        }
    }

    public func merged(with other: TasteStore) -> TasteStore {
        TasteStore(exemplars: exemplars + other.exemplars, analyses: analyses + other.analyses)
    }

    // MARK: Persistence (small JSON; the app picks the URL per scope)

    public static func load(from url: URL) -> TasteStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(TasteStore.self, from: data) else { return TasteStore() }
        return store
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url)
    }
}
