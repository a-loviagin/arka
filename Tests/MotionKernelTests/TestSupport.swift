import Foundation
@testable import MotionKernel

/// Deterministic PRNG (SplitMix64) so fuzz failures reproduce exactly in CI.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    /// A small document with one comp and a handful of Tier-1 layers covering scalar/vec2/color
    /// properties and a parent chain.
    static func sampleDocument() -> MotionDocument {
        let bg = Layer(
            id: "layer_bg", name: "Background", sortKey: "a0",
            content: .shape(ShapeContent(geometry: .rect,
                                         size: .static(Vec2(1920, 1080)),
                                         fillColor: .static(ColorValue(hex: "#101018")!))),
            transform: Transform(position: .static(Vec2(960, 540)))
        )
        let logo = Layer(
            id: "layer_logo", name: "Logo", sortKey: "a1",
            content: .shape(ShapeContent(geometry: .ellipse,
                                         size: .static(Vec2(200, 200)),
                                         fillColor: .static(ColorValue(hex: "#3366FF")!))),
            transform: Transform(
                position: .animated([Track(keyframes: [
                    Keyframe(t: 0.0, v: Vec2(960, 1200), interp: .bezier, easeOut: ControlPoint(0.2, 0)),
                    Keyframe(t: 0.8, v: Vec2(960, 540), interp: .bezier, easeIn: ControlPoint(0.4, 1)),
                ])]),
                opacity: .animated([Track(keyframes: [
                    Keyframe(t: 0.0, v: 0.0, interp: .linear),
                    Keyframe(t: 0.4, v: 1.0),
                ])])
            )
        )
        let label = Layer(
            id: "layer_label", name: "Label", sortKey: "a2",
            content: .text(TextContent(string: "Ship faster", fontSize: .static(64))),
            parentId: "layer_logo",
            transform: Transform(position: .static(Vec2(0, 160)))
        )
        let comp = Composition(id: "comp_main", size: Vec2(1920, 1080), fps: 60,
                               duration: 5.0, backgroundColor: .white,
                               layers: [bg, logo, label])
        return MotionDocument(id: "doc_test",
                              compositions: [comp], mainCompositionId: "comp_main")
    }

    /// Animatable (path, kind) pairs for a layer — drives the fuzz generator's valid commands.
    static func animatablePaths(for layer: Layer) -> [(String, AnyValue)] {
        var out: [(String, AnyValue)] = [
            ("\(layer.id)/transform/position", .vec2(Vec2(100, 100))),
            ("\(layer.id)/transform/scale", .vec2(Vec2(1.5, 1.5))),
            ("\(layer.id)/transform/rotation", .scalar(45)),
            ("\(layer.id)/transform/opacity", .scalar(0.5)),
        ]
        switch layer.content {
        case .shape:
            out.append(("\(layer.id)/content/size", .vec2(Vec2(300, 120))))
            out.append(("\(layer.id)/content/fillColor", .color(ColorValue(hex: "#FF8800")!)))
            out.append(("\(layer.id)/content/cornerRadius", .scalar(24)))
        case .text:
            out.append(("\(layer.id)/content/fontSize", .scalar(72)))
            out.append(("\(layer.id)/content/fillColor", .color(ColorValue(hex: "#222222")!)))
        default:
            break
        }
        return out
    }

    /// A canonical JSON encoder for byte-identical round-trip comparisons.
    static func canonicalEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension MotionDocument {
    /// Canonical serialized form for byte-identical undo comparisons.
    func canonicalData() throws -> Data {
        try Fixtures.canonicalEncoder().encode(self)
    }
}
