#if os(macOS)
import Foundation
import MotionKernel

/// A built-in demo composition so the canvas shows the engine working: staggered cards spring up,
/// a pill morphs its corner radius, a dot eases across. All Tier-1 shape + transform animation,
/// expressed purely through the kernel's schema — no special-casing in the renderer.
enum DemoDocument {
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
                )
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

        let comp = Composition(id: "comp_main", name: "Demo", size: Vec2(W, H), fps: 60,
                               duration: 3.0, backgroundColor: ColorValue(hex: "#0E0E14")!,
                               layers: layers)
        return MotionDocument(id: "doc_demo", meta: .init(title: "Arka Demo"),
                              compositions: [comp], mainCompositionId: "comp_main")
    }
}
#endif
