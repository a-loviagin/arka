import Foundation

/// Produces a one-line `subject` description for an imported image asset (ai-pipeline.md §3) via a
/// Claude vision call — the semantic half of asset analysis (palette + dimensions are deterministic
/// CV). Run once on import and cached; the description travels as text in every request so the model
/// can reason about brand assets ("animate the rocket logo") without re-seeing pixels.
public protocol ImageSubjectAnalyzer: Sendable {
    func subject(of imageData: Data, mediaType: String) async throws -> String
}

public struct ClaudeImageAnalyzer: ImageSubjectAnalyzer {
    public struct Config: Sendable {
        public var apiKey: String
        public var model: String
        public var maxTokens: Int
        public var endpoint: URL
        public var anthropicVersion: String
        public init(apiKey: String, model: String = "claude-sonnet-4-6", maxTokens: Int = 256,
                    endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
                    anthropicVersion: String = "2023-06-01") {
            self.apiKey = apiKey; self.model = model; self.maxTokens = maxTokens
            self.endpoint = endpoint; self.anthropicVersion = anthropicVersion
        }
    }

    public let config: Config
    private let session: URLSession
    public init(config: Config, session: URLSession = .shared) { self.config = config; self.session = session }

    public static func fromEnvironment(model: String = "claude-sonnet-4-6",
                                       session: URLSession = .shared) -> ClaudeImageAnalyzer? {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else { return nil }
        return ClaudeImageAnalyzer(config: Config(apiKey: key, model: model), session: session)
    }

    public func subject(of imageData: Data, mediaType: String = "image/png") async throws -> String {
        let body = requestBody(imageData: imageData, mediaType: mediaType)
        let data = try await send(body)
        return try Self.decodeSubject(from: data)
    }

    static let toolName = "describe_asset"

    func requestBody(imageData: Data, mediaType: String) -> [String: Any] {
        [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": "You label design assets in one short phrase for an animation tool. Describe the "
                + "subject and key visual traits (e.g. \"a blue rocket logo on a transparent background\"). "
                + "Call \(Self.toolName).",
            "tool_choice": ["type": "tool", "name": Self.toolName],
            "tools": [[
                "name": Self.toolName,
                "description": "Return a one-line description of the asset.",
                "input_schema": [
                    "type": "object",
                    "properties": ["subject": ["type": "string", "description": "One short phrase."]],
                    "required": ["subject"],
                    "additionalProperties": false,
                ],
            ]],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "Describe this asset."],
                ["type": "image", "source": ["type": "base64", "media_type": mediaType,
                                             "data": imageData.base64EncodedString()]],
            ]]],
        ]
    }

    static func decodeSubject(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]],
              let toolUse = content.first(where: {
                  ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName
              }), let input = toolUse["input"] as? [String: Any],
              let subject = input["subject"] as? String else {
            throw GenerationError.decoding("the model did not call \(toolName)")
        }
        return subject
    }

    private func send(_ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(config.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, URLResponse), Error>) in
            session.dataTask(with: req) { d, r, e in
                if let e { c.resume(throwing: e) } else if let d, let r { c.resume(returning: (d, r)) }
                else { c.resume(throwing: GenerationError.provider("empty response")) }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GenerationError.provider("HTTP \(AnthropicClient.errorMessage(data))")
        }
        return data
    }
}
