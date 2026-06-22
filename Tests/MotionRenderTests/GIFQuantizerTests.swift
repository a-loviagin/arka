#if os(macOS)
import XCTest
@testable import MotionRender

/// OKLab median-cut palette + nearest-colour LUT (export-and-format.md §1 GIF craft).
final class GIFQuantizerTests: XCTestCase {
    /// BGRA image from a list of (r,g,b) pixels in a single row.
    private func image(_ pixels: [(UInt8, UInt8, UInt8)]) -> PixelImage {
        var bgra: [UInt8] = []
        for (r, g, b) in pixels { bgra += [b, g, r, 255] }
        return PixelImage(width: pixels.count, height: 1, bgra: bgra)
    }

    func testPaletteCapturesDistinctColorsAndMapsExactly() {
        let img = image([(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)])
        let pal = GIFQuantizer.palette(from: [img], maxColors: 256)
        XCTAssertEqual(pal.rgb.count, 4, "four distinct colours → four palette entries")

        // With dither off, each pixel maps back to its own colour (palette is exact).
        let lut = GIFQuantizer.lut(for: pal)
        let out = GIFQuantizer.mapped(img, palette: pal, lut: lut, dither: 0)
        for x in 0..<4 {
            let i = img.pixel(x, 0), o = out.pixel(x, 0)
            XCTAssertEqual(Int(o.r), Int(i.r), accuracy: 10)
            XCTAssertEqual(Int(o.g), Int(i.g), accuracy: 10)
            XCTAssertEqual(Int(o.b), Int(i.b), accuracy: 10)
        }
    }

    func testPaletteIsCappedByMaxColors() {
        // A 64-colour ramp quantized to 8 entries.
        var pixels: [(UInt8, UInt8, UInt8)] = []
        for i in 0..<64 { pixels.append((UInt8(i * 4), UInt8(255 - i * 4), 128)) }
        let pal = GIFQuantizer.palette(from: [image(pixels)], maxColors: 8)
        XCTAssertLessThanOrEqual(pal.rgb.count, 8)
        XCTAssertGreaterThan(pal.rgb.count, 1)
    }

    func testOKLabLightnessOrdering() {
        XCTAssertLessThan(GIFQuantizer.oklab(0, 0, 0).0, GIFQuantizer.oklab(128, 128, 128).0)
        XCTAssertLessThan(GIFQuantizer.oklab(128, 128, 128).0, GIFQuantizer.oklab(255, 255, 255).0)
    }
}
#endif
