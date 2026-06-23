import XCTest
@testable import MotionAI

/// Vision subject for image assets (ai-pipeline.md §3) — request shape + structured decode, no network.
final class ClaudeImageAnalyzerTests: XCTestCase {
    private let analyzer = ClaudeImageAnalyzer(config: .init(apiKey: "test"))

    func testRequestCarriesImageAndForcesTool() {
        let body = analyzer.requestBody(imageData: Data([1, 2, 3]), mediaType: "image/png")
        let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        let image = content?.first { ($0["type"] as? String) == "image" }
        XCTAssertEqual((image?["source"] as? [String: Any])?["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual((body["tool_choice"] as? [String: Any])?["name"] as? String, "describe_asset")
    }

    func testDecodesSubject() throws {
        let resp = try JSONSerialization.data(withJSONObject: ["content": [[
            "type": "tool_use", "name": "describe_asset", "input": ["subject": "a blue rocket logo"],
        ]]])
        XCTAssertEqual(try ClaudeImageAnalyzer.decodeSubject(from: resp), "a blue rocket logo")
    }

    func testRejectsMissingTool() {
        let resp = try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "hi"]]])
        XCTAssertThrowsError(try ClaudeImageAnalyzer.decodeSubject(from: resp))
    }
}
