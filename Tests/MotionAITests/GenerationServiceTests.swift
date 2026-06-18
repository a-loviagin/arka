import XCTest
@testable import MotionAI
import MotionKernel

final class GenerationServiceTests: XCTestCase {
    private func doc() -> MotionDocument {
        let layer = Layer(id: "logo", name: "Logo", sortKey: "a0",
                          content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(100, 100)))),
                          transform: Transform(position: .static(Vec2(50, 50)), opacity: .static(1)))
        let comp = Composition(id: "c", size: Vec2(200, 200), fps: 60, duration: 2, layers: [layer])
        return MotionDocument(id: "d", compositions: [comp], mainCompositionId: "c")
    }

    func testServiceBuildsDigestAndValidates() async throws {
        let service = GenerationService(generator: HeuristicGenerator())
        let result = try await service.generate(document: doc(), compId: "c", prompt: "pop in bouncy",
                                                selection: ["logo"], playhead: 0)
        XCTAssertFalse(result.commands.isEmpty)
        guard case .applyPattern = result.commands.first else { return XCTFail("expected applyPattern") }
    }

    func testServiceThrowsForUnknownComp() async {
        let service = GenerationService(generator: HeuristicGenerator())
        do {
            _ = try await service.generate(document: doc(), compId: "nope", prompt: "x")
            XCTFail("should throw")
        } catch let e as GenerationError {
            guard case .notConfigured = e else { return XCTFail("expected .notConfigured") }
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testEndpointRequestRoundTripsThroughJSON() throws {
        let req = GenerateEndpointRequest(document: doc(), compId: "c", prompt: "pop in",
                                          selection: ["logo"], playhead: 0)
        let data = try JSONEncoder().encode(req)
        let back = try JSONDecoder().decode(GenerateEndpointRequest.self, from: data)
        XCTAssertEqual(back.prompt, "pop in")
        XCTAssertEqual(back.compId, "c")
        XCTAssertEqual(back.selection, ["logo"])

        // When asked, dump a correctly-encoded request body for the live server smoke test.
        if let path = ProcessInfo.processInfo.environment["ARKA_DUMP_REQ"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
