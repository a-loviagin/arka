#if os(macOS)
import Foundation
import Metal
import CoreText
import CoreGraphics
import simd
import MotionKernel

/// CoreText layout → positioned glyph quads against a shared atlas (render-engine.md §2).
/// "CoreText does layout (it must — ligatures, kerning, RTL are not territory to enter)."
///
/// Layout geometry is cached by (string, font, size, tracking, alignment); fill color is applied
/// at build time and never invalidates layout — animating color is free, animating tracking isn't.
public final class TextEngine {
    private let atlas: GlyphAtlas
    private var layoutCache: [LayoutKey: [GlyphQuad]] = [:]

    private struct LayoutKey: Hashable {
        let string: String
        let font: String
        let sizeBucket: Int
        let trackingBucket: Int
        let lineHeightBucket: Int
        let alignment: Int
    }

    public init?(device: MTLDevice) {
        guard let atlas = GlyphAtlas(device: device) else { return nil }
        self.atlas = atlas
    }

    func run(for text: TextContent, fontSize: Double, tracking: Double, lineHeight: Double,
             fill: SIMD4<Float>) -> GlyphRun? {
        let key = LayoutKey(string: text.string, font: text.fontFamily,
                            sizeBucket: Int((fontSize * 4).rounded()),
                            trackingBucket: Int((tracking * 4).rounded()),
                            lineHeightBucket: Int((lineHeight * 4).rounded()),
                            alignment: alignmentIndex(text.alignment))
        let glyphs = layoutCache[key] ?? layout(text, fontSize: fontSize, tracking: tracking, lineHeight: lineHeight)
        layoutCache[key] = glyphs
        guard !glyphs.isEmpty else { return nil }
        return GlyphRun(atlas: atlas.texture, fill: fill, glyphs: glyphs)
    }

    private func alignmentIndex(_ a: TextAlignment) -> Int {
        switch a { case .left: 0; case .center: 1; case .right: 2 }
    }

    /// Content size in points (line width × ascent+descent) — what the kernel uses to place the
    /// layer's anchor and to hit-test/gizmo text. Same CoreText path as layout, so measure and
    /// render agree.
    func measure(_ text: TextContent, fontSize: Double, tracking: Double, lineHeight: Double) -> Vec2 {
        guard !text.string.isEmpty else { return .zero }
        let baseFont = CTFontCreateWithName(text.fontFamily as CFString, CGFloat(fontSize), nil)
        let ascent = CTFontGetAscent(baseFont), descent = CTFontGetDescent(baseFont)
        let advance = lineHeight > 0 ? CGFloat(lineHeight) : ascent + descent + CTFontGetLeading(baseFont)
        let lines = text.string.components(separatedBy: "\n")
        let maxWidth = lines.reduce(CGFloat(0)) { w, s in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                .init(kCTFontAttributeName as String): baseFont,
                .init(kCTKernAttributeName as String): CGFloat(tracking),
            ]) as CFAttributedString)
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            return max(w, CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l)))
        }
        let height = CGFloat(max(lines.count - 1, 0)) * advance + ascent + descent
        return Vec2(Double(maxWidth), Double(height))
    }

    /// Multi-line layout. The string is split on "\n"; each line is laid out on its own baseline,
    /// `advance` apart (the given `lineHeight`, or the font's natural height when ≤ 0). Local origin
    /// is top-left ([0,width]×[0,height]) — centering/anchoring is the layer transform's job — so
    /// alignment positions each line horizontally within the block width.
    private func layout(_ text: TextContent, fontSize: Double, tracking: Double,
                        lineHeight: Double) -> [GlyphQuad] {
        let baseFont = CTFontCreateWithName(text.fontFamily as CFString, CGFloat(fontSize), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): baseFont,
            .init(kCTKernAttributeName as String): CGFloat(tracking),
        ]
        let ascent = CTFontGetAscent(baseFont)
        let advance = lineHeight > 0 ? CGFloat(lineHeight)
                                     : ascent + CTFontGetDescent(baseFont) + CTFontGetLeading(baseFont)

        let lines = text.string.components(separatedBy: "\n").map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes) as CFAttributedString)
        }
        let widths = lines.map { line -> CGFloat in
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            return CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        }
        let blockWidth = widths.max() ?? 0

        var quads: [GlyphQuad] = []
        for (i, line) in lines.enumerated() {
            let baselineY = Float(ascent + CGFloat(i) * advance)
            let startX: Float
            switch text.alignment {
            case .left: startX = 0
            case .center: startX = Float((blockWidth - widths[i]) / 2)
            case .right: startX = Float(blockWidth - widths[i])
            }
            appendGlyphs(of: line, baseFont: baseFont, fontSize: fontSize,
                         startX: startX, baselineY: baselineY, into: &quads)
        }
        return quads
    }

    private func appendGlyphs(of line: CTLine, baseFont: CTFont, fontSize: Double,
                              startX: Float, baselineY: Float, into quads: inout [GlyphQuad]) {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for ctRun in runs {
            let count = CTRunGetGlyphCount(ctRun)
            if count == 0 { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(ctRun, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(ctRun, CFRangeMake(0, count), &positions)

            let runFont = runFont(of: ctRun, fallback: baseFont)
            let fontName = (CTFontCopyPostScriptName(runFont) as String)

            for i in 0..<count {
                guard let info = atlas.glyph(glyphs[i], font: runFont,
                                             fontName: fontName, size: CGFloat(fontSize)) else { continue }
                if info.uvSize.x == 0 || info.uvSize.y == 0 { continue } // space/empty
                let penX = startX + Float(positions[i].x)
                quads.append(GlyphQuad(
                    localOrigin: SIMD2<Float>(penX + info.bboxMinX, baselineY - (info.bboxMinY + info.bboxH)),
                    localSize: SIMD2<Float>(info.bboxW, info.bboxH),
                    uvOrigin: info.uvOrigin,
                    uvSize: info.uvSize))
            }
        }
    }

    private func runFont(of run: CTRun, fallback: CTFont) -> CTFont {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        if let f = attrs[kCTFontAttributeName as String] {
            return (f as! CTFont)
        }
        return fallback
    }
}

/// Lets the kernel size text layers (hit-testing, gizmos, anchor placement) via the same CoreText
/// path that renders them — closing the "text has no intrinsic size" gap (SceneEvaluator).
extension TextEngine: TextMeasuring {
    public func measure(_ text: TextContent, at t: TimeInterval) -> Vec2 {
        measure(text, fontSize: text.fontSize.resolve(at: t), tracking: text.tracking?.resolve(at: t) ?? 0,
                lineHeight: text.lineHeight?.resolve(at: t) ?? 0)
    }
}
#endif
