#if os(macOS)
import Foundation

/// Dominant-color extraction for asset analysis (ai-pipeline.md §3) — the deterministic CV half of
/// "what is this image", reusing the OKLab median-cut quantizer. Returns #RRGGBB hex, most-prominent
/// first-ish (median-cut buckets).
public enum ImagePalette {
    public static func hexColors(of image: PixelImage, maxColors: Int = 5) -> [String] {
        let pal = GIFQuantizer.palette(from: [image], maxColors: maxColors)
        return pal.rgb.map {
            String(format: "#%02X%02X%02X",
                   Int(min(max($0.r, 0), 255)), Int(min(max($0.g, 0), 255)), Int(min(max($0.b, 0), 255)))
        }
    }

    /// Load image bytes (PNG/JPEG/…) and extract its palette — convenience for an imported asset.
    public static func hexColors(ofImageData data: Data, maxColors: Int = 5) -> [String] {
        guard let img = PixelImage.load(pngData: data) else { return [] }
        return hexColors(of: img, maxColors: maxColors)
    }
}
#endif
