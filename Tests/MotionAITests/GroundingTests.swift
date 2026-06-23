import XCTest
@testable import MotionAI
import MotionKernel

/// Canvas-snapshot grounding (§2) + asset analysis (§3) plumbing — request shape only, no network.
final class GroundingTests: XCTestCase {
    private func digest() -> DocumentDigest {
        DocumentDigest.summarize(
            MotionDocument(id: "d",
                           compositions: [Composition(id: "c", size: Vec2(100, 100), fps: 60, duration: 2,
                                                       layers: [Layer(id: "logo", name: "Logo", sortKey: "a0",
                                                                      content: .shape(ShapeContent(geometry: .rect)))])],
                           mainCompositionId: "c"),
            compId: "c")!
    }

    func testSnapshotBecomesAnImageBlockInEditMode() {
        let client = AnthropicClient(config: .init(apiKey: "test"))
        let snap = Data([0xFF, 0xD8, 0xAA]) // pretend JPEG
        let req = GenerationRequest(prompt: "move it under the logo", mode: .edit, digest: digest(), snapshot: snap)
        let body = client.requestBody(for: req)
        let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        XCTAssertNotNil(content, "with a snapshot, content is a block array")
        let image = content?.first { ($0["type"] as? String) == "image" }
        let data = (image?["source"] as? [String: Any])?["data"] as? String
        XCTAssertEqual(data, snap.base64EncodedString())
    }

    func testNoSnapshotKeepsContentAPlainString() {
        let client = AnthropicClient(config: .init(apiKey: "test"))
        let req = GenerationRequest(prompt: "fade in", mode: .edit, digest: digest())
        let content = (client.requestBody(for: req)["messages"] as? [[String: Any]])?.first?["content"]
        XCTAssertTrue(content is String, "no snapshot → plain text content")
    }

    func testAssetAnalysisTravelsInTheUserMessage() {
        let asset = AssetAnalysis(assetId: "logo_png", palette: ["#5B8CFF", "#FFFFFF"],
                                  subject: "blue rocket logo", width: 512, height: 512)
        let req = GenerationRequest(prompt: "use brand colors", mode: .create, digest: digest(), assets: [asset])
        let msg = SystemPrompt.userMessage(for: req)
        XCTAssertTrue(msg.contains("ASSETS"))
        XCTAssertTrue(msg.contains("#5B8CFF"))
        XCTAssertTrue(msg.contains("blue rocket logo"))
    }

    func testRequestRoundTripsWithSnapshotAndAssets() throws {
        let req = GenerationRequest(prompt: "p", mode: .edit, digest: digest(),
                                    snapshot: Data([1, 2, 3]),
                                    assets: [AssetAnalysis(assetId: "a", palette: ["#000000"], width: 10, height: 10)])
        let back = try JSONDecoder().decode(GenerationRequest.self, from: JSONEncoder().encode(req))
        XCTAssertEqual(back.snapshot, Data([1, 2, 3]))
        XCTAssertEqual(back.assets.first?.assetId, "a")
    }
}
