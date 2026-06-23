import Foundation
import MotionKernel

/// The client→server payload (ai-pipeline.md §1): the prompt plus enough context (a summarized
/// document digest, the selection, prior turns) for the model to produce an edit.
public struct GenerationRequest: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case create, edit }

    public var prompt: String
    public var mode: Mode
    public var digest: DocumentDigest
    /// Current playhead time — new animation typically starts here.
    public var playhead: TimeInterval
    /// Prior prompts in this thread (the conversation is the workflow, §7).
    public var history: [String]
    /// Set by the repair loop: the specific machine-readable error from the previous attempt.
    public var repairFeedback: String?
    /// A rendered canvas snapshot at the playhead (JPEG), for `edit` mode — the model grounds spatial
    /// language ("under the logo") far better with pixels than coordinates (§2).
    public var snapshot: Data?
    /// Cached analyses for the document's assets (§3), sent as text alongside the digest.
    public var assets: [AssetAnalysis]

    public init(prompt: String, mode: Mode, digest: DocumentDigest, playhead: TimeInterval = 0,
                history: [String] = [], repairFeedback: String? = nil,
                snapshot: Data? = nil, assets: [AssetAnalysis] = []) {
        self.prompt = prompt
        self.mode = mode
        self.digest = digest
        self.playhead = playhead
        self.history = history
        self.repairFeedback = repairFeedback
        self.snapshot = snapshot
        self.assets = assets
    }
}

/// The model's structured output (ai-pipeline.md §4): a brief plan, an undo label, and a command
/// list (base commands + the `ApplyPattern`/`Stagger` macros, which expand client-side).
public struct GenerationResult: Codable, Sendable {
    public var plan: String
    public var label: String
    public var commands: [AnyCommand]

    public init(plan: String, label: String, commands: [AnyCommand]) {
        self.plan = plan
        self.label = label
        self.commands = commands
    }
}
