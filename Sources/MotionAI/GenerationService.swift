import Foundation
import MotionKernel

/// The full generate-an-edit operation in one place (ai-pipeline.md §5), independent of any
/// transport: build the digest from a document + selection + playhead, run the validate/repair
/// pipeline against that document, return the validated result. The app calls it in-process; the
/// server calls it behind an HTTP handler — same kernel, same `.motion` contract on both sides.
public struct GenerationService: Sendable {
    public let generator: any MotionGenerator
    public var maxRepairs: Int

    public init(generator: any MotionGenerator, maxRepairs: Int = 2) {
        self.generator = generator
        self.maxRepairs = maxRepairs
    }

    public func generate(document: MotionDocument, compId: EntityID, prompt: String,
                         selection: Set<EntityID> = [], playhead: TimeInterval = 0,
                         history: [String] = [],
                         mode: GenerationRequest.Mode = .edit,
                         snapshot: Data? = nil, assets: [AssetAnalysis] = []) async throws -> GenerationResult {
        guard let digest = DocumentDigest.summarize(document, compId: compId,
                                                    selection: selection, at: playhead) else {
            throw GenerationError.notConfigured("composition '\(compId)' not found")
        }
        let request = GenerationRequest(prompt: prompt, mode: mode, digest: digest,
                                        playhead: playhead, history: history,
                                        snapshot: snapshot, assets: assets)
        let pipeline = GenerationPipeline(generator: generator, maxRepairs: maxRepairs)
        return try await pipeline.generate(request, against: document)
    }
}

/// The server's request/response wire types (ai-pipeline.md §2). The client sends the full document
/// so the server is authoritative — it summarizes, generates, and validates against the same bytes.
public struct GenerateEndpointRequest: Codable, Sendable {
    public var document: MotionDocument
    public var compId: EntityID
    public var prompt: String
    public var selection: [EntityID]
    public var playhead: TimeInterval
    public var history: [String]
    public var mode: GenerationRequest.Mode

    public init(document: MotionDocument, compId: EntityID, prompt: String,
                selection: [EntityID] = [], playhead: TimeInterval = 0,
                history: [String] = [], mode: GenerationRequest.Mode = .edit) {
        self.document = document
        self.compId = compId
        self.prompt = prompt
        self.selection = selection
        self.playhead = playhead
        self.history = history
        self.mode = mode
    }
}

extension GenerationService {
    /// Convenience for the HTTP layer: run an endpoint request end to end.
    public func generate(_ request: GenerateEndpointRequest) async throws -> GenerationResult {
        try await generate(document: request.document, compId: request.compId, prompt: request.prompt,
                           selection: Set(request.selection), playhead: request.playhead,
                           history: request.history, mode: request.mode)
    }
}
