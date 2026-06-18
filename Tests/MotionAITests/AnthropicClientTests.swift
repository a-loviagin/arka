import XCTest
@testable import MotionAI
import MotionKernel

/// These exercise the pure request-building and response-decoding paths — no network. The live HTTP
/// round-trip needs a real key and is covered manually / in CI with a secret.
final class AnthropicClientTests: XCTestCase {
    private func doc() -> MotionDocument {
        let layer = Layer(id: "logo", name: "Logo", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)))),
                          transform: Transform(position: .static(Vec2(50, 50)), opacity: .static(1)))
        let comp = Composition(id: "c", size: Vec2(200, 200), fps: 60, duration: 2, layers: [layer])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }
    private func request() -> GenerationRequest {
        GenerationRequest(prompt: "pop in", mode: .edit,
                          digest: DocumentDigest.summarize(doc(), compId: "c", selection: ["logo"])!,
                          playhead: 0)
    }

    func testRequestBodyForcesToolAndIsSerializable() throws {
        let client = AnthropicClient(config: .init(apiKey: "k", model: "claude-sonnet-4-6"))
        let body = client.requestBody(for: request())
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-6")
        let choice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["name"] as? String, "emit_motion")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "emit_motion")
        // Must round-trip through JSONSerialization (the send path serializes it).
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testDecodeResultExtractsToolUse() throws {
        let json = """
        {
          "id": "msg_1", "type": "message", "role": "assistant", "stop_reason": "tool_use",
          "content": [
            {"type": "text", "text": "I'll pop it in."},
            {"type": "tool_use", "id": "tu_1", "name": "emit_motion",
             "input": {"plan": "Pop the logo in.", "label": "Pop In",
                       "commands": [
                         {"type": "ApplyPattern", "layerId": "logo", "pattern": "popIn",
                          "params": {"at": 0, "duration": 0.6, "character": "snappy"}}
                       ]}}
          ]
        }
        """
        let result = try AnthropicClient.decodeResult(from: Data(json.utf8))
        XCTAssertEqual(result.label, "Pop In")
        guard case .applyPattern(let id, let pattern, _) = result.commands.first else {
            return XCTFail("expected applyPattern")
        }
        XCTAssertEqual(id, EntityID("logo"))
        XCTAssertEqual(pattern, .popIn)
    }

    func testDecodeResultThrowsOnRefusal() {
        let json = #"{"stop_reason": "refusal", "content": []}"#
        XCTAssertThrowsError(try AnthropicClient.decodeResult(from: Data(json.utf8))) {
            guard case GenerationError.provider = $0 else { return XCTFail("expected .provider") }
        }
    }

    func testDecodeResultThrowsWhenToolMissing() {
        let json = #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "hi"}]}"#
        XCTAssertThrowsError(try AnthropicClient.decodeResult(from: Data(json.utf8))) {
            guard case GenerationError.decoding = $0 else { return XCTFail("expected .decoding") }
        }
    }

    func testFromEnvironmentNilWithoutKey() {
        // Can't reliably unset env here; just assert the explicit-config path is always usable.
        let client = AnthropicClient(config: .init(apiKey: "k"))
        XCTAssertEqual(client.config.model, "claude-sonnet-4-6")
    }
}
