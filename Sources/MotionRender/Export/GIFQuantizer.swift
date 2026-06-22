#if os(macOS)
import Foundation

/// GIF colour craft (export-and-format.md §1): a single stable 256-colour palette built across the
/// exported frames by **median-cut in OKLab** (perceptually uniform — buckets split where the eye
/// sees difference), then per-pixel mapping through a 15-bit nearest-colour LUT with low-amplitude
/// **ordered (Bayer) dithering** to break up banding without the motion shimmer heavy
/// Floyd-Steinberg causes. One shared palette avoids the per-frame palette flicker of naive adaptive
/// quantization.
enum GIFQuantizer {
    struct Palette {
        var rgb: [(r: Float, g: Float, b: Float)]   // 0…255
        var lab: [(L: Float, a: Float, b: Float)]
    }

    // MARK: OKLab

    private static func toLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    /// sRGB bytes → OKLab.
    static func oklab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let lr = toLinear(r / 255), lg = toLinear(g / 255), lb = toLinear(b / 255)
        let l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
        let m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
        let s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb
        let l_ = cbrtf(l), m_ = cbrtf(m), s_ = cbrtf(s)
        return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    // MARK: Palette (median cut)

    private struct Sample { var r: Float; var g: Float; var b: Float; var L: Float; var A: Float; var B: Float }

    static func palette(from frames: [PixelImage], maxColors: Int = 256) -> Palette {
        // Sample up to ~16k pixels across all frames (stride chosen from the total pixel budget).
        let totalPixels = frames.reduce(0) { $0 + $1.width * $1.height }
        let stride = max(totalPixels / 16_384, 1)
        var samples: [Sample] = []
        var counter = 0
        for f in frames {
            let px = f.bgra
            var i = 0
            while i < px.count {
                if counter % stride == 0 {
                    let b = Float(px[i]), g = Float(px[i + 1]), r = Float(px[i + 2])
                    let lab = oklab(r, g, b)
                    samples.append(Sample(r: r, g: g, b: b, L: lab.0, A: lab.1, B: lab.2))
                }
                counter += 1; i += 4
            }
        }
        guard !samples.isEmpty else { return Palette(rgb: [(0, 0, 0)], lab: [oklabTuple(0, 0, 0)]) }

        // Median-cut: repeatedly split the box with the largest OKLab extent along its longest axis.
        var boxes: [[Sample]] = [samples]
        while boxes.count < maxColors {
            guard let (idx, axis, _) = widestBox(boxes) else { break }
            var box = boxes[idx]
            box.sort { axisValue($0, axis) < axisValue($1, axis) }
            let mid = box.count / 2
            guard mid > 0, mid < box.count else { break }
            boxes[idx] = Array(box[..<mid])
            boxes.append(Array(box[mid...]))
        }

        var rgb: [(Float, Float, Float)] = []
        var lab: [(Float, Float, Float)] = []
        for box in boxes where !box.isEmpty {
            let n = Float(box.count)
            let r = box.reduce(0) { $0 + $1.r } / n
            let g = box.reduce(0) { $0 + $1.g } / n
            let b = box.reduce(0) { $0 + $1.b } / n
            rgb.append((r, g, b)); lab.append(oklabTuple(r, g, b))
        }
        return Palette(rgb: rgb, lab: lab)
    }

    private static func oklabTuple(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let l = oklab(r, g, b); return (l.0, l.1, l.2)
    }
    private static func axisValue(_ s: Sample, _ axis: Int) -> Float { axis == 0 ? s.L : (axis == 1 ? s.A : s.B) }

    /// The box + axis with the greatest OKLab spread (so the next split removes the most visible error).
    private static func widestBox(_ boxes: [[Sample]]) -> (Int, Int, Float)? {
        var best: (Int, Int, Float)?
        for (i, box) in boxes.enumerated() where box.count > 1 {
            for axis in 0..<3 {
                var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                for s in box { let v = axisValue(s, axis); lo = min(lo, v); hi = max(hi, v) }
                let range = hi - lo
                if best == nil || range > best!.2 { best = (i, axis, range) }
            }
        }
        return best
    }

    // MARK: Nearest-colour LUT + ordered dither

    /// A 15-bit (5 bits/channel) RGB → palette-index table, so per-pixel mapping is O(1).
    static func lut(for palette: Palette) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 32_768)
        for key in 0..<32_768 {
            let r = Float((key >> 10) & 31) * 255 / 31
            let g = Float((key >> 5) & 31) * 255 / 31
            let b = Float(key & 31) * 255 / 31
            let lab = oklab(r, g, b)
            var bestI = 0, bestD = Float.greatestFiniteMagnitude
            for (i, p) in palette.lab.enumerated() {
                let dL = lab.0 - p.L, dA = lab.1 - p.a, dB = lab.2 - p.b
                let d = dL * dL + dA * dA + dB * dB
                if d < bestD { bestD = d; bestI = i }
            }
            table[key] = UInt8(bestI)
        }
        return table
    }

    /// Bayer 4×4 ordered-dither matrix, normalized to roughly [-0.5, 0.5].
    private static let bayer: [Float] = [
        0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5,
    ].map { $0 / 16 - 0.5 }

    /// Map an image to the palette through the LUT, with low ordered dithering. Output is opaque RGB
    /// containing only palette colours (ImageIO then preserves them as the GIF palette).
    static func mapped(_ image: PixelImage, palette: Palette, lut: [UInt8], dither: Float = 1.0) -> PixelImage {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let amp = 22 * dither // sRGB units of dither perturbation, tuned low
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let t = bayer[(y & 3) * 4 + (x & 3)] * amp
                func q(_ v: UInt8) -> Int { Int(min(max(Float(v) + t, 0), 255)) >> 3 } // 5-bit
                let key = (q(image.bgra[i + 2]) << 10) | (q(image.bgra[i + 1]) << 5) | q(image.bgra[i])
                let p = palette.rgb[Int(lut[key])]
                out[i] = UInt8(min(max(p.b, 0), 255))     // B
                out[i + 1] = UInt8(min(max(p.g, 0), 255)) // G
                out[i + 2] = UInt8(min(max(p.r, 0), 255)) // R
            }
        }
        return PixelImage(width: w, height: h, bgra: out)
    }
}
#endif
