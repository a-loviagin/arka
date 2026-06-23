#if os(macOS)
import XCTest
@testable import MotionRender

/// Asset-analysis palette extraction + JPEG snapshot encoding (ai-pipeline.md §2/§3).
final class ImagePaletteTests: XCTestCase {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 8, h: Int = 8) -> PixelImage {
        var bgra: [UInt8] = []
        for _ in 0..<(w * h) { bgra += [b, g, r, 255] }
        return PixelImage(width: w, height: h, bgra: bgra)
    }

    func testPaletteOfSolidImageIsThatColor() {
        let hex = ImagePalette.hexColors(of: solid(0x5B, 0x8C, 0xFF), maxColors: 4)
        XCTAssertEqual(hex.first, "#5B8CFF")
    }

    func testJPEGSnapshotHasMarker() throws {
        let data = try XCTUnwrap(solid(10, 20, 30).jpegData(quality: 0.6))
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]), "JPEG SOI marker")
    }
}
#endif
