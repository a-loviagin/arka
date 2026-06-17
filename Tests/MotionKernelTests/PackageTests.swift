import XCTest
@testable import MotionKernel

final class PackageTests: XCTestCase {
    private func tempPackageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("arka_pkg_\(UInt32.random(in: 0 ..< .max)).motion")
    }

    func testContentHashIsDeterministicAndDistinct() {
        let a = Data("hello world".utf8)
        let b = Data("hello worlD".utf8)
        XCTAssertEqual(ContentHash.hex(a), ContentHash.hex(a), "same bytes → same hash")
        XCTAssertNotEqual(ContentHash.hex(a), ContentHash.hex(b), "different bytes → different hash")
        XCTAssertEqual(ContentHash.hex(a).count, 32, "128-bit hex digest")
    }

    func testContentAddressedAssetPath() {
        let data = Data([1, 2, 3, 4])
        let asset = Asset.contentAddressed(id: "a", type: .image, data: data, ext: ".png",
                                           pixelSize: Vec2(2, 2))
        XCTAssertTrue(asset.path.hasPrefix("assets/"))
        XCTAssertTrue(asset.path.hasSuffix(".png"))
        XCTAssertEqual(asset.path, "assets/\(ContentHash.hex(data)).png")
    }

    func testPackageRoundTrip() throws {
        let bytes = Data("fake-png-bytes".utf8)
        let asset = Asset.contentAddressed(id: "asset_1", type: .image, data: bytes, ext: "png",
                                           pixelSize: Vec2(4, 4))
        var doc = Fixtures.sampleDocument()
        doc.assets = [asset]

        let url = tempPackageURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try MotionPackage.write(doc, to: url, assetData: [asset.path: bytes],
                                thumbnailPNG: Data("thumb".utf8))

        // Files laid out as specified.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("document.json").path))
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent(asset.path).path))
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("thumbnail.png").path))

        // Round-trips equal (same schema version → no migration).
        let loaded = try MotionPackage.read(at: url)
        XCTAssertEqual(loaded, doc)
        XCTAssertTrue(MotionPackage.missingAssets(in: url, for: loaded).isEmpty)
        XCTAssertEqual(MotionPackage.assetData(in: url, for: loaded)[asset.path], bytes)
    }

    func testMissingAssetBytesThrows() {
        var doc = Fixtures.sampleDocument()
        doc.assets = [Asset(id: "a", type: .image, path: "assets/x.png")]
        let url = tempPackageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try MotionPackage.write(doc, to: url)) { error in
            guard case MotionPackage.PackageError.missingAssetBytes = error else {
                return XCTFail("expected missingAssetBytes, got \(error)")
            }
        }
    }

    func testWriteOverwritesExistingPackage() throws {
        let url = tempPackageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try MotionPackage.write(Fixtures.sampleDocument(), to: url)
        // Second write with a different doc replaces cleanly.
        var doc2 = Fixtures.sampleDocument()
        doc2.meta.title = "Renamed"
        try MotionPackage.write(doc2, to: url)
        XCTAssertEqual(try MotionPackage.read(at: url).meta.title, "Renamed")
    }

    func testMigrationRunsOnOpen() throws {
        // A hand-written v0.1.0 document with omitted-default fields opens cleanly.
        let json = """
        { "schemaVersion": "0.1.0", "id": "doc_x", "mainCompositionId": "comp_main",
          "compositions": [ { "id": "comp_main", "size": [800, 600], "fps": 30, "duration": 2,
            "layers": [ { "id": "l1", "sortKey": "a0",
              "content": { "type": "shape", "geometry": "rect" } } ] } ] }
        """.data(using: .utf8)!
        let url = tempPackageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try json.write(to: url.appendingPathComponent("document.json"))

        let doc = try MotionPackage.read(at: url)
        XCTAssertEqual(doc.mainComposition?.size, Vec2(800, 600))
        XCTAssertEqual(doc.mainComposition?.layers.first?.id, "l1")
    }

    func testFutureMajorVersionRejected() throws {
        let json = """
        { "schemaVersion": "2.0.0", "id": "d", "mainCompositionId": "c",
          "compositions": [ { "id": "c" } ] }
        """.data(using: .utf8)!
        let url = tempPackageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try json.write(to: url.appendingPathComponent("document.json"))
        XCTAssertThrowsError(try MotionPackage.read(at: url))
    }
}
