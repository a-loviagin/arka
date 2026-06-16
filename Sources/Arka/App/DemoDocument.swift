#if os(macOS)
import Foundation
import CoreGraphics
import MotionKernel

/// A built-in demo composition so the canvas shows the engine working: staggered cards spring up,
/// a pill morphs its corner radius, a dot eases across, a headline slides in, and a procedurally
/// generated image scales in. All Tier-1 animation, expressed purely through the kernel's schema.
enum DemoDocument {
    static let logoAssetId: EntityID = "asset_logo"
    static let logoSize = Vec2(220, 220)

    /// A procedural gradient tile standing in for an imported asset, so the image render path is
    /// exercised without bundling a file.
    static func makeLogoImage() -> CGImage {
        let w = Int(logoSize.x), h = Int(logoSize.y)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1),
                      CGColor(red: 0.91, green: 0.36, blue: 0.96, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return ctx.makeImage()!
    }

    static func make() -> MotionDocument {
        let W = 1920.0, H = 1080.0
        var layers: [Layer] = []

        layers.append(Layer(
            id: "layer_bg", name: "Background", sortKey: "a0",
            content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(W, H)),
                                         fillColor: .static(ColorValue(hex: "#0E0E14")!))),
            transform: Transform(position: .static(.zero))
        ))

        // Three cards that spring up in a stagger.
        let cardColors = ["#5B8CFF", "#FF6B6B", "#36D399"]
        for i in 0..<3 {
            let x = 360.0 + Double(i) * 420.0
            let start = 0.2 + Double(i) * 0.12
            layers.append(Layer(
                id: EntityID("layer_card\(i)"), name: "Card \(i)", sortKey: SortKey("b\(i)"),
                content: .shape(ShapeContent(geometry: .rect, size: .static(Vec2(320, 420)),
                                             fillColor: .static(ColorValue(hex: cardColors[i])!),
                                             cornerRadius: .static(28))),
                transform: Transform(
                    anchor: .static(Vec2(0.5, 0.5)),
                    position: .animated([Track(keyframes: [
                        Keyframe(t: start, v: Vec2(x, H + 300), interp: .spring(.bouncy)),
                        Keyframe(t: start + 1.2, v: Vec2(x, 540)),
                    ])]),
                    opacity: .animated([Track(keyframes: [
                        Keyframe(t: start, v: 0.0, interp: .linear),
                        Keyframe(t: start + 0.25, v: 1.0),
                    ])])
                ),
                // Soft drop shadow grounds each card (multi-pass effect).
                effects: [Effect(id: EntityID("fx_card\(i)"), type: "shadow", params: [
                    "offset": .vec2(.static(Vec2(0, 18))),
                    "radius": .scalar(.static(28)),
                    "color": .color(.static(.black)),
                    "opacity": .scalar(.static(0.45)),
                ])]
            ))
        }

        // A pill that morphs corner radius and slides — the "rect → pill" workhorse.
        layers.append(Layer(
            id: "layer_pill", name: "Pill", sortKey: "c0",
            content: .shape(ShapeContent(
                geometry: .rect, size: .static(Vec2(420, 120)),
                fillColor: .static(ColorValue(hex: "#FFD166")!),
                cornerRadius: .animated([Track(keyframes: [
                    Keyframe(t: 1.0, v: 8.0, interp: .bezier),
                    Keyframe(t: 2.2, v: 60.0),
                ])]))),
            transform: Transform(
                anchor: .static(Vec2(0.5, 0.5)),
                position: .animated([Track(keyframes: [
                    Keyframe(t: 1.0, v: Vec2(960, 900), interp: .bezier,
                             easeOut: ControlPoint(0.2, 0)),
                    Keyframe(t: 2.2, v: Vec2(960, 860), easeIn: ControlPoint(0.4, 1)),
                ])])
            )
        ))

        // A dot easing across the top with a curved motion path (spatial tangents).
        layers.append(Layer(
            id: "layer_dot", name: "Dot", sortKey: "c1",
            content: .shape(ShapeContent(geometry: .ellipse, size: .static(Vec2(80, 80)),
                                         fillColor: .static(ColorValue(hex: "#E879F9")!))),
            transform: Transform(
                anchor: .static(Vec2(0.5, 0.5)),
                position: .animated([Track(keyframes: [
                    Keyframe(t: 0.0, v: Vec2(200, 160), interp: .bezier,
                             easeOut: ControlPoint(0.4, 0), spatialOut: Vec2(400, -120)),
                    Keyframe(t: 2.5, v: Vec2(1720, 160),
                             easeIn: ControlPoint(0.6, 1), spatialIn: Vec2(-400, -120)),
                ])])
            )
        ))

        // Headline text: fades + slides up, centered above the cards.
        layers.append(Layer(
            id: "layer_headline", name: "Headline", sortKey: "d0",
            content: .text(TextContent(string: "Ship it in motion",
                                       fontFamily: "Helvetica Neue Bold",
                                       fontSize: .static(120),
                                       tracking: .static(2),
                                       fillColor: .static(.white),
                                       alignment: .center)),
            transform: Transform(
                anchor: .static(Vec2(0.5, 0.5)),
                position: .animated([Track(keyframes: [
                    Keyframe(t: 0.6, v: Vec2(960, 240), interp: .bezier,
                             easeOut: ControlPoint(0.2, 0)),
                    Keyframe(t: 1.4, v: Vec2(960, 180), easeIn: ControlPoint(0.4, 1)),
                ])]),
                opacity: .animated([Track(keyframes: [
                    Keyframe(t: 0.6, v: 0.0, interp: .linear),
                    Keyframe(t: 1.2, v: 1.0),
                ])])
            )
        ))

        // A procedural image that scales in (spring), demonstrating the image render path.
        layers.append(Layer(
            id: "layer_logo_img", name: "Logo Image", sortKey: "c2",
            content: .image(ImageContent(assetId: logoAssetId)),
            transform: Transform(
                anchor: .static(Vec2(0.5, 0.5)),
                position: .static(Vec2(960, 620)),
                scale: .animated([Track(keyframes: [
                    Keyframe(t: 0.4, v: Vec2(0, 0), interp: .spring(.bouncy)),
                    Keyframe(t: 1.4, v: Vec2(1, 1)),
                ])])
            )
        ))

        let comp = Composition(id: "comp_main", name: "Demo", size: Vec2(W, H), fps: 60,
                               duration: 3.0, backgroundColor: ColorValue(hex: "#0E0E14")!,
                               layers: layers)
        let logo = Asset(id: logoAssetId, type: .image, path: "logo.png", pixelSize: logoSize)
        return MotionDocument(id: "doc_demo", meta: .init(title: "Arka Demo"),
                              assets: [logo],
                              compositions: [comp], mainCompositionId: "comp_main")
    }
}
#endif
