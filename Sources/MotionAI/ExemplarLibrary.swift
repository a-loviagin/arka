import Foundation
import MotionKernel

/// One few-shot exemplar (ai-pipeline.md §6.4): a natural-language intent paired with the command
/// list a motion designer would author for it. Exemplars carry *taste* — more than any doctrine
/// paragraph — and are versioned like code. The layer ids are illustrative; the model maps them to
/// the ids in the live document digest.
///
/// This is how the tool "learns from examples" without fine-tuning: exemplars are data the model
/// reads at generation time, and because the output is a command list (the human write path), the
/// generated project is fully editable by construction.
public struct Exemplar: Sendable, Codable, Equatable {
    public var id: String
    public var intent: String
    public var tags: [String]
    public var commands: [AnyCommand]

    public init(id: String, intent: String, tags: [String], commands: [AnyCommand]) {
        self.id = id; self.intent = intent; self.tags = tags; self.commands = commands
    }
}

/// A retrievable set of exemplars. `retrieve` ranks by token/tag overlap with the prompt and returns
/// the most relevant few to inject as few-shot examples — keyword scoring for v1; an embedding
/// retriever can drop in behind the same interface later.
public struct ExemplarLibrary: Sendable {
    public var exemplars: [Exemplar]
    public init(_ exemplars: [Exemplar]) { self.exemplars = exemplars }

    public func retrieve(for prompt: String, k: Int = 4) -> [Exemplar] {
        let q = Self.tokens(prompt)
        guard !q.isEmpty else { return [] }
        let scored = exemplars.map { ex -> (Exemplar, Int) in
            let intentTokens = Self.tokens(ex.intent)
            let tagTokens = Set(ex.tags.map { $0.lowercased() })
            // Tags weigh double — they're the curated index terms.
            let score = q.intersection(intentTokens).count + 2 * q.intersection(tagTokens).count
            return (ex, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(k).map(\.0)
    }

    private static let stop: Set<String> = ["the", "a", "an", "it", "to", "and", "of", "with", "in",
                                            "on", "make", "my", "this", "that", "them", "is", "for"]
    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(stop)
    }

    // MARK: Built-in starter set (authored taste; expand / replace with mined exemplars over time)

    private static func params(_ d: Double, _ c: MotionCharacter, distance: Double? = nil) -> PatternParams {
        PatternParams(at: 0, duration: d, character: c, distance: distance)
    }

    public static let builtin = ExemplarLibrary([
        Exemplar(id: "ex_fade_logo", intent: "fade the logo in", tags: ["fade", "in", "logo", "entrance"],
                 commands: [.applyPattern(layerId: "logo", pattern: .fadeIn, params: params(0.5, .snappy))]),
        Exemplar(id: "ex_pop_title", intent: "make the title pop in with a bounce",
                 tags: ["pop", "bounce", "bouncy", "title", "entrance"],
                 commands: [.applyPattern(layerId: "title", pattern: .popIn, params: params(0.6, .bouncy))]),
        Exemplar(id: "ex_stagger_cards", intent: "slide the cards up one after another",
                 tags: ["slide", "up", "stagger", "cards", "list", "sequence"],
                 commands: [.stagger(layerIds: ["card1", "card2", "card3"], pattern: .slideInUp,
                                     params: params(0.5, .snappy, distance: 60), gap: 0.08)]),
        Exemplar(id: "ex_reveal_headline", intent: "gently reveal the headline",
                 tags: ["reveal", "scale", "gentle", "smooth", "headline", "entrance"],
                 commands: [.applyPattern(layerId: "headline", pattern: .scaleReveal, params: params(0.7, .gentle))]),
        Exemplar(id: "ex_pulse_button", intent: "add a subtle looping pulse to the button",
                 tags: ["pulse", "loop", "subtle", "button", "emphasis"],
                 commands: [.applyPattern(layerId: "button", pattern: .pulse, params: params(0.8, .gentle))]),
        Exemplar(id: "ex_exit_fade", intent: "make it exit by fading out",
                 tags: ["exit", "fade", "out", "leave"],
                 commands: [.applyPattern(layerId: "logo", pattern: .fadeOut, params: params(0.4, .snappy))]),
    ])
}
