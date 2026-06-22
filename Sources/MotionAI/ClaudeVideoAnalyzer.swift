import Foundation
import MotionKernel

/// The vision pass that lets the model actually *see* a reference clip (ai-pipeline.md §3): sampled
/// frames go to Claude as image blocks and come back as a structured `VideoMotionAnalysis` via a
/// forced tool. Claude's vision reads on-screen text natively, so this subsumes OCR — no separate
/// engine needed. Foundation-only: frames arrive as already-encoded image bytes (the sampler lives
/// in the render layer), so this stays Linux-clean.
public struct ClaudeVideoAnalyzer: VideoMotionAnalyzer {
    public struct Config: Sendable {
        public var apiKey: String
        public var model: String
        public var maxTokens: Int
        public var endpoint: URL
        public var anthropicVersion: String
        public var imageMediaType: String  // matches the sampler's encoding

        public init(apiKey: String, model: String = "claude-sonnet-4-6", maxTokens: Int = 2048,
                    endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
                    anthropicVersion: String = "2023-06-01", imageMediaType: String = "image/jpeg") {
            self.apiKey = apiKey; self.model = model; self.maxTokens = maxTokens
            self.endpoint = endpoint; self.anthropicVersion = anthropicVersion
            self.imageMediaType = imageMediaType
        }
    }

    public let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Build from `ANTHROPIC_API_KEY`; nil (not an error) if unset.
    public static func fromEnvironment(model: String = "claude-sonnet-4-6",
                                       session: URLSession = .shared) -> ClaudeVideoAnalyzer? {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else { return nil }
        return ClaudeVideoAnalyzer(config: Config(apiKey: key, model: model), session: session)
    }

    public func analyze(frames: [Data], fps: Double, hint: String?) async throws -> VideoMotionAnalysis {
        guard !frames.isEmpty else { throw GenerationError.provider("no frames to analyze") }
        let body = requestBody(frames: frames, fps: fps, hint: hint)
        let data = try await send(body)
        return try Self.decodeAnalysis(from: data)
    }

    static let toolName = "emit_motion_analysis"

    /// Multimodal body: a framing instruction, the sampled frames as image blocks (in order), and a
    /// forced structured-output tool whose schema mirrors `VideoMotionAnalysis`.
    func requestBody(frames: [Data], fps: Double, hint: String?) -> [String: Any] {
        var content: [[String: Any]] = [[
            "type": "text",
            "text": "These \(frames.count) frames are sampled in order at \(Int(fps)) fps from a "
                + "motion-design clip." + (hint.map { " Context: \($0)." } ?? "")
                + " Describe its motion as design elements (what enters, with which pattern + easing "
                + "character, when, and whether a group staggers), the dominant colors, and a one-line "
                + "summary. Map to the provided patterns/characters. Call \(Self.toolName).",
        ]]
        for frame in frames {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": config.imageMediaType,
                           "data": frame.base64EncodedString()],
            ])
        }
        return [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": SystemPrompt.videoAnalysis(),
            "tool_choice": ["type": "tool", "name": Self.toolName],
            "tools": [Self.toolDefinition()],
            "messages": [["role": "user", "content": content]],
        ]
    }

    static func toolDefinition() -> [String: Any] {
        let patterns = MotionPattern.allCases.map(\.rawValue)
        let characters = MotionCharacter.allCases.map(\.rawValue)
        return [
            "name": toolName,
            "description": "Emit the clip's motion as a structured analysis in the tool's vocabulary.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "One line: what moves and how."],
                    "palette": ["type": "array", "items": ["type": "string"],
                                "description": "Dominant colors as #RRGGBB."],
                    "staggerGap": ["type": "number", "description": "Seconds between grouped elements, if any."],
                    "elements": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "role": ["type": "string", "description": "e.g. title, logo, card, icon."],
                                "pattern": ["type": "string", "enum": patterns],
                                "character": ["type": "string", "enum": characters],
                                "start": ["type": "number", "description": "Entrance time, seconds."],
                                "duration": ["type": "number", "description": "Motion length, seconds."],
                                "count": ["type": "integer", "description": "Group size (1 if single)."],
                            ],
                            "required": ["role", "pattern"],
                            "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["summary", "elements"],
                "additionalProperties": false,
            ],
        ]
    }

    static func decodeAnalysis(from data: Data) throws -> VideoMotionAnalysis {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GenerationError.decoding("response was not a JSON object")
        }
        if (root["stop_reason"] as? String) == "refusal" {
            throw GenerationError.provider("the model refused the request")
        }
        guard let content = root["content"] as? [[String: Any]],
              let toolUse = content.first(where: {
                  ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName
              }), let input = toolUse["input"] as? [String: Any] else {
            throw GenerationError.decoding("the model did not call \(toolName)")
        }
        do {
            return try JSONDecoder().decode(VideoMotionAnalysis.self,
                                            from: JSONSerialization.data(withJSONObject: input))
        } catch {
            throw GenerationError.decoding("\(error)")
        }
    }

    private func send(_ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(config.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
            session.dataTask(with: req) { d, r, e in
                if let e { cont.resume(throwing: e) }
                else if let d, let r { cont.resume(returning: (d, r)) }
                else { cont.resume(throwing: GenerationError.provider("empty response")) }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw GenerationError.provider("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw GenerationError.provider("HTTP \(http.statusCode): \(AnthropicClient.errorMessage(data))")
        }
        return data
    }
}
