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
        let alignment: Int
    }

    public init?(device: MTLDevice) {
        guard let atlas = GlyphAtlas(device: device) else { return nil }
        self.atlas = atlas
    }

    func run(for text: TextContent, fontSize: Double, tracking: Double,
             fill: SIMD4<Float>) -> GlyphRun? {
        let key = LayoutKey(string: text.string, font: text.fontFamily,
                            sizeBucket: Int((fontSize * 4).rounded()),
                            trackingBucket: Int((tracking * 4).rounded()),
                            alignment: alignmentIndex(text.alignment))
        let glyphs = layoutCache[key] ?? layout(text, fontSize: fontSize, tracking: tracking)
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
    func measure(_ text: TextContent, fontSize: Double, tracking: Double) -> Vec2 {
        guard !text.string.isEmpty else { return .zero }
        let baseFont = CTFontCreateWithName(text.fontFamily as CFString, CGFloat(fontSize), nil)
        let attr = NSAttributedString(string: text.string, attributes: [
            .init(kCTFontAttributeName as String): baseFont,
            .init(kCTKernAttributeName as String): CGFloat(tracking),
        ])
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Vec2(Double(width), Double(ascent + descent))
    }

    private func layout(_ text: TextContent, fontSize: Double, tracking: Double) -> [GlyphQuad] {
        let baseFont = CTFontCreateWithName(text.fontFamily as CFString, CGFloat(fontSize), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): baseFont,
            .init(kCTKernAttributeName as String): CGFloat(tracking),
        ]
        let attr = NSAttributedString(string: text.string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let baselineY = Float(ascent)
        // Top-left local origin ([0,width]×[0,height]); centering/anchoring is the layer transform's
        // job (anchor × measured size), so text behaves like every other [0,size] layer for
        // hit-testing and gizmos. Single-line CTLine → horizontal alignment is identity here.
        let startX: Float = 0

        var quads: [GlyphQuad] = []
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
                let originX = penX + info.bboxMinX
                let originY = baselineY - (info.bboxMinY + info.bboxH)
                quads.append(GlyphQuad(
                    localOrigin: SIMD2<Float>(originX, originY),
                    localSize: SIMD2<Float>(info.bboxW, info.bboxH),
                    uvOrigin: info.uvOrigin,
                    uvSize: info.uvSize))
            }
        }
        return quads
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
        measure(text, fontSize: text.fontSize.resolve(at: t), tracking: text.tracking?.resolve(at: t) ?? 0)
    }
}
#endif
