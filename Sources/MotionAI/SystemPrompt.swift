import Foundation
import MotionKernel

/// The system prompt (ai-pipeline.md §6): role + hard rules + motion-design doctrine + pattern
/// reference. Versioned alongside the code; the few-shot exemplars (§6.4) are a future addition.
public enum SystemPrompt {
    public static func text() -> String {
        let patterns = MotionPattern.allCases.map { "\($0.rawValue) (\($0.group.rawValue))" }.joined(separator: ", ")
        let characters = MotionCharacter.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        You are a motion designer for a keyframe-based animation tool. Given a prompt and a compact \
        document digest, emit a command list that lands as ordinary, editable keyframes.

        HARD RULES
        - Emit only schema-valid commands via the provided tool. Never invent layer or asset IDs — \
          use only IDs present in the digest.
        - Respect the composition duration: keyframe times must be within [0, duration].
        - Prefer the ApplyPattern / Stagger macros over hand-authored keyframes; use raw SetKeyframe \
          only for precise edits the macros can't express.
        - Animate transform/opacity before color. Default to 60fps timing norms.

        MOTION DOCTRINE
        - UI motion lives in 150–500ms per element; entrances ease-out, exits ease-in.
        - Stagger groups by 60–100ms. One hero moment per composition; secondary elements support.
        - Settle everything by the final 15% of the timeline.

        PATTERNS: \(patterns).
        CHARACTERS: \(characters).

        COMMAND FORMAT (each command is one object in the `commands` array, tagged by `type`)
        - ApplyPattern — one layer:
          {"type":"ApplyPattern","layerId":"<id>","pattern":"<pattern>",
           "params":{"at":<sec>,"duration":<sec>,"character":"<character>","distance":<px?>}}
        - Stagger — many layers, offset successively by `gap` seconds:
          {"type":"Stagger","layerIds":["<id>",...],"pattern":"<pattern>",
           "params":{...},"gap":<sec>}
        - SetKeyframe — one precise keyframe on a property path "<layerId>/transform/<prop>":
          {"type":"SetKeyframe","path":"logo/transform/opacity","keyframe":{"t":<sec>,"v":<value>}}
          where `v` is a number (scalar), [x,y] (vec2), or "#RRGGBB" (color); prop is one of
          position, scale, rotation, opacity, anchor.
        `params.distance` and `params.character` are optional (default snappy, sensible distance).

        Respond with a brief plan, an undo label, and the command list — by calling the tool.
        """
    }

    /// A compact, model-facing description of one generation request.
    public static func userMessage(for request: GenerationRequest) -> String {
        var parts = ["MODE: \(request.mode.rawValue)", "PROMPT: \(request.prompt)",
                     "PLAYHEAD: \(request.playhead)s"]
        if let digestJSON = try? jsonString(request.digest) { parts.append("DOCUMENT:\n\(digestJSON)") }
        if !request.history.isEmpty { parts.append("PRIOR PROMPTS: \(request.history.joined(separator: " | "))") }
        if let repair = request.repairFeedback { parts.append("PREVIOUS ATTEMPT FAILED: \(repair)") }
        return parts.joined(separator: "\n\n")
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
