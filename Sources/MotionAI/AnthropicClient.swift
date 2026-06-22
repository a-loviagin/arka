import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A live `MotionGenerator` backed by the Anthropic Messages API (ai-pipeline.md §2,3). It forces a
/// single `emit_motion` tool call so the model's output is a typed `GenerationResult` rather than
/// free text, then decodes the tool input through the same `AnyCommand` Codable the rest of the
/// kernel uses. The validate/repair loop lives in `GenerationPipeline`, which re-invokes this with
/// `repairFeedback` set; this type performs exactly one request per call.
///
/// Foundation-only and Linux-clean (raw `URLSession` — Swift has no first-party Anthropic SDK). The
/// server build links the same code; the macOS app uses it directly when `ANTHROPIC_API_KEY` is set.
public struct AnthropicClient: MotionGenerator {
    public struct Config: Sendable {
        public var apiKey: String
        public var model: String
        public var maxTokens: Int
        public var endpoint: URL
        public var anthropicVersion: String
        /// Few-shot exemplar library + how many to retrieve per request (ai-pipeline.md §6.4).
        public var exemplars: ExemplarLibrary
        public var exemplarCount: Int
        /// Distilled house style from the reference-clip library (§3), injected as prompt doctrine.
        public var taste: TasteProfile?

        public init(apiKey: String,
                    model: String = "claude-sonnet-4-6",
                    maxTokens: Int = 4096,
                    endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
                    anthropicVersion: String = "2023-06-01",
                    exemplars: ExemplarLibrary = .builtin,
                    exemplarCount: Int = 4,
                    taste: TasteProfile? = nil) {
            self.apiKey = apiKey
            self.model = model
            self.maxTokens = maxTokens
            self.endpoint = endpoint
            self.anthropicVersion = anthropicVersion
            self.exemplars = exemplars
            self.exemplarCount = exemplarCount
            self.taste = taste
        }
    }

    public let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Build a client from `ANTHROPIC_API_KEY`; nil (not an error) if the key is unset so callers can
    /// fall back to the `HeuristicGenerator`.
    public static func fromEnvironment(model: String = "claude-sonnet-4-6",
                                       session: URLSession = .shared) -> AnthropicClient? {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
              !key.isEmpty else { return nil }
        return AnthropicClient(config: Config(apiKey: key, model: model), session: session)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let body = requestBody(for: request)
        let data: Data
        do {
            data = try await send(body)
        } catch let e as GenerationError {
            throw e
        } catch {
            throw GenerationError.provider(error.localizedDescription)
        }
        return try Self.decodeResult(from: data)
    }

    // MARK: - Request

    /// The wire body: system prompt (cacheable prefix), the single user turn, and the forced tool.
    func requestBody(for request: GenerationRequest) -> [String: Any] {
        let exemplars = config.exemplars.retrieve(for: request.prompt, k: config.exemplarCount)
        return [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": SystemPrompt.text(exemplars: exemplars, taste: config.taste),
            "tool_choice": ["type": "tool", "name": Self.toolName],
            "tools": [Self.toolDefinition()],
            "messages": [
                ["role": "user", "content": SystemPrompt.userMessage(for: request)],
            ],
        ]
    }

    static let toolName = "emit_motion"

    /// The structured-output contract. `commands` items are permissive objects (each tagged by
    /// `type`); the precise per-command shape is specified in the system prompt's COMMAND FORMAT and
    /// enforced downstream by the kernel's validate/apply, which drives the repair loop.
    static func toolDefinition() -> [String: Any] { [
        "name": toolName,
        "description": "Emit the motion edit as a brief plan, an undo label, and a command list.",
        "input_schema": [
            "type": "object",
            "properties": [
                "plan": ["type": "string", "description": "One or two sentences on the approach."],
                "label": ["type": "string", "description": "Short undo-stack label, e.g. \"Pop In\"."],
                "commands": [
                    "type": "array",
                    "description": "Ordered commands; prefer ApplyPattern/Stagger macros.",
                    "items": [
                        "type": "object",
                        "properties": ["type": ["type": "string"]],
                        "required": ["type"],
                        "additionalProperties": true,
                    ],
                ],
            ],
            "required": ["plan", "label", "commands"],
            "additionalProperties": false,
        ],
    ] }

    private func send(_ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(config.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.data(for: req, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.provider("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GenerationError.provider("HTTP \(http.statusCode): \(Self.errorMessage(data))")
        }
        return data
    }

    // MARK: - Response

    /// Pull the `emit_motion` tool input out of the response and decode it as a `GenerationResult`.
    static func decodeResult(from data: Data) throws -> GenerationResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GenerationError.decoding("response was not a JSON object")
        }
        if let stop = root["stop_reason"] as? String, stop == "refusal" {
            throw GenerationError.provider("the model refused the request")
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw GenerationError.decoding("response had no content blocks")
        }
        guard let toolUse = content.first(where: {
            ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName
        }), let input = toolUse["input"] as? [String: Any] else {
            throw GenerationError.decoding("the model did not call \(toolName)")
        }
        let inputData = try JSONSerialization.data(withJSONObject: input)
        do {
            return try JSONDecoder().decode(GenerationResult.self, from: inputData)
        } catch {
            throw GenerationError.decoding("\(error)")
        }
    }

    /// Best-effort extraction of `error.message` from an Anthropic error body.
    static func errorMessage(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(decoding: data, as: UTF8.self)
        }
        return message
    }

    /// `URLSession.data(for:)` isn't uniformly available on Linux corelibs-foundation, so bridge the
    /// completion-handler API to async ourselves.
    private static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: GenerationError.provider("empty response"))
                }
            }
            task.resume()
        }
    }
}
