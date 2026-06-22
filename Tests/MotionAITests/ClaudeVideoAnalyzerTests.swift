import XCTest
@testable import MotionAI
import MotionKernel

/// The vision pass that lets the model see a clip (ai-pipeline.md §3). No network: we test the
/// multimodal request shape and the structured-output decode (incl. lenient fields).
final class ClaudeVideoAnalyzerTests: XCTestCase {
    private let analyzer = ClaudeVideoAnalyzer(config: .init(apiKey: "test"))

    func testRequestCarriesFrameImagesAndForcesTheTool() {
        let frames = [Data([1, 2, 3]), Data([4, 5, 6])]
        let body = analyzer.requestBody(frames: frames, fps: 12, hint: "brand intro")
        let messages = body["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        let images = content?.filter { ($0["type"] as? String) == "image" } ?? []
        XCTAssertEqual(images.count, 2, "one image block per frame")
        let first = images.first?["source"] as? [String: Any]
        XCTAssertEqual(first?["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(first?["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        // Forced structured-output tool.
        let choice = body["tool_choice"] as? [String: Any]
        XCTAssertEqual(choice?["name"] as? String, "emit_motion_analysis")
    }

    func testDecodesToolUseIntoAnalysis() throws {
        let response: [String: Any] = ["content": [[
            "type": "tool_use", "name": "emit_motion_analysis",
            "input": [
                "summary": "logo fades in, then a title pops",
                "palette": ["#112233"],
                "staggerGap": 0.1,
                "elements": [
                    ["role": "logo", "pattern": "fadeIn", "character": "gentle", "start": 0, "duration": 0.5, "count": 1],
                    ["role": "title", "pattern": "popIn"], // lenient: omits character/start/duration/count
                ],
            ],
        ]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        let a = try ClaudeVideoAnalyzer.decodeAnalysis(from: data)
        XCTAssertEqual(a.elements.count, 2)
        XCTAssertEqual(a.elements[0].pattern, .fadeIn)
        XCTAssertEqual(a.elements[1].pattern, .popIn)
        XCTAssertEqual(a.elements[1].character, .snappy, "defaulted")
        XCTAssertEqual(a.elements[1].duration, 0.5, accuracy: 1e-9, "defaulted")
        XCTAssertEqual(a.staggerGap, 0.1)

        // End-to-end: the seen clip becomes editable commands.
        let cmds = TasteSynthesizer.commands(from: a, layerIds: ["l1", "l2"])
        XCTAssertEqual(cmds.count, 2)
    }

    func testRejectsResponseWithoutToolCall() {
        let data = try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "no tool"]]])
        XCTAssertThrowsError(try ClaudeVideoAnalyzer.decodeAnalysis(from: data))
    }
}
