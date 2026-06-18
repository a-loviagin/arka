import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import MotionKernel
import MotionAI

/// The Arka backend (ai-pipeline.md §2): a thin Hummingbird HTTP layer over `GenerationService`. It
/// runs the same MotionKernel + MotionAI as the desktop app, so a generated edit is validated against
/// the identical document model the client uses — the `.motion` contract is one codebase.
///
/// Routes:
///   GET  /health   → "ok"
///   POST /generate → { document, compId, prompt, selection?, playhead?, history?, mode? }
///                    → GenerationResult { plan, label, commands }
///
/// Uses the live Anthropic client when `ANTHROPIC_API_KEY` is set, else the offline heuristic
/// generator. Listens on `PORT` (default 8080).
@main
struct ArkaServer {
    static func main() async throws {
        let generator: any MotionGenerator = AnthropicClient.fromEnvironment() ?? HeuristicGenerator()
        let service = GenerationService(generator: generator)
        let live = AnthropicClient.fromEnvironment() != nil

        let router = Router()
        router.get("/health") { _, _ in "ok" }

        router.post("/generate") { request, context -> Response in
            let buffer = try await request.body.collect(upTo: 8 * 1024 * 1024)
            let data = Data(buffer: buffer)
            let input: GenerateEndpointRequest
            do {
                input = try JSONDecoder().decode(GenerateEndpointRequest.self, from: data)
            } catch {
                throw HTTPError(.badRequest, message: "invalid request body: \(error)")
            }
            do {
                let result = try await service.generate(input)
                return try jsonResponse(result, status: .ok)
            } catch let error as GenerationError {
                // Validation/repair exhaustion and provider faults are the caller's to see.
                throw HTTPError(.unprocessableContent, message: error.description)
            }
        }

        let port = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init) ?? 8080
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port),
                                 serverName: "ArkaServer"))
        print("ArkaServer on http://127.0.0.1:\(port) — generator: \(live ? "Anthropic" : "heuristic (offline)")")
        try await app.runService()
    }

    /// Encode a Codable value as a JSON `Response`.
    private static func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers,
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}
