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

        // MARK: Playback-level review (multiplayer.md) — share + comment + web viewer.
        let shares = ShareStore()

        // Seed a built-in demo share so `/demo` opens a working review page with no setup.
        let demoID = await shares.create(ShareUpload(meta: DemoLottie.meta, lottieJSON: DemoLottie.json))
        router.get("/demo") { _, _ -> Response in
            var headers = HTTPFields(); headers[.location] = "/v/\(demoID)"
            return Response(status: .seeOther, headers: headers)
        }

        router.post("/share") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: 32 * 1024 * 1024)
            let upload: ShareUpload
            do { upload = try JSONDecoder().decode(ShareUpload.self, from: Data(buffer: buffer)) }
            catch { throw HTTPError(.badRequest, message: "invalid share body: \(error)") }
            let id = await shares.create(upload)
            return try jsonResponse(["id": id, "viewer": "/v/\(id)"], status: .ok)
        }
        router.get("/share/:id") { _, context -> Response in
            guard let id = context.parameters.get("id"), let meta = await shares.meta(id)
            else { throw HTTPError(.notFound) }
            return try jsonResponse(meta, status: .ok)
        }
        router.get("/share/:id/lottie") { _, context -> Response in
            guard let id = context.parameters.get("id"), let json = await shares.lottie(id)
            else { throw HTTPError(.notFound) }
            var headers = HTTPFields(); headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: json)))
        }
        router.get("/share/:id/comments") { _, context -> Response in
            guard let id = context.parameters.get("id"), await shares.meta(id) != nil
            else { throw HTTPError(.notFound) }
            return try jsonResponse(await shares.comments(id), status: .ok)
        }
        router.post("/share/:id/comments") { request, context -> Response in
            guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
            let buffer = try await request.body.collect(upTo: 256 * 1024)
            let draft = try JSONDecoder().decode(ReviewComment.self, from: Data(buffer: buffer))
            guard let saved = await shares.addComment(id, draft) else { throw HTTPError(.notFound) }
            return try jsonResponse(saved, status: .ok)
        }
        router.get("/v/:id") { _, context -> Response in
            guard let id = context.parameters.get("id"), await shares.meta(id) != nil
            else { throw HTTPError(.notFound) }
            var headers = HTTPFields(); headers[.contentType] = "text/html; charset=utf-8"
            return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: ReviewViewer.html)))
        }

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
        print("Demo review page: http://127.0.0.1:\(port)/demo")
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
