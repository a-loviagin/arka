import Foundation

/// Result of a Lottie export: the JSON document plus a compatibility lint — exactly what won't
/// survive, per layer (export-and-format.md §4). Designers forgive missing features, not silent
/// corruption, so the caller surfaces `warnings` before/with the export.
public struct LottieExportResult: Sendable {
    public let json: Data
    public let warnings: [String]
}

/// Translates a composition to a Lottie (bodymovin) JSON document — a document-to-document
/// translator, not a render path (export-and-format.md §4). The schema sits adjacent to Lottie's
/// model, so Tier-1 maps directly: transform + opacity keyframes with cubic-bezier easing, and
/// parametric rect/ellipse shapes with fill/stroke/corner-radius.
///
/// v1 scope: composition metadata, shape (rect/ellipse) and null/group layers, full animated
/// transforms with bezier easing, layer parenting. Animated shape *geometry*, springs, and
/// text/image/video/precomp layers are flagged in `warnings` and exported best-effort (geometry at
/// t=0; springs as eased segments; unsupported layers as positioned nulls) so the file is always
/// valid and never silently wrong.
public enum LottieExporter {
    public static let version = "5.7.0"

    public static func export(_ document: MotionDocument, compId: EntityID) throws -> LottieExportResult {
        guard let comp = document.composition(compId) else {
            throw CommandError.compositionNotFound(compId)
        }
        var warnings: [String] = []
        let fps = comp.fps

        // Lottie draws array-order top-first; our render order is bottom→top, so reverse.
        let ordered = Array(comp.layersInRenderOrder.reversed())
        var indByID: [EntityID: Int] = [:]
        for (i, layer) in ordered.enumerated() { indByID[layer.id] = i + 1 }

        var layers: [JSONValue] = []
        for layer in ordered {
            layers.append(buildLayer(layer, comp: comp, fps: fps, indByID: indByID, warnings: &warnings))
        }

        let root: JSONValue = .object([
            "v": .string(version),
            "fr": .number(fps),
            "ip": .number(0),
            "op": .number((comp.duration * fps).rounded()),
            "w": .number(comp.size.x),
            "h": .number(comp.size.y),
            "nm": .string(comp.name),
            "ddd": .int(0),
            "assets": .array([]),
            "layers": .array(layers),
        ])
        return LottieExportResult(json: try root.data(), warnings: warnings)
    }

    // MARK: Layer

    private static func buildLayer(_ layer: Layer, comp: Composition, fps: Double,
                                   indByID: [EntityID: Int], warnings: inout [String]) -> JSONValue {
        var obj: [String: JSONValue] = [
            "nm": .string(layer.name.isEmpty ? "\(layer.id)" : layer.name),
            "ind": .int(indByID[layer.id] ?? 1),
            "ip": .number(0),
            "op": .number((comp.duration * fps).rounded()),
            "st": .number(0),
            "sr": .number(1),
            "ddd": .int(0),
            "ks": transform(layer, fps: fps, warnings: &warnings),
        ]
        if let pid = layer.parentId, let parentInd = indByID[pid] {
            obj["parent"] = .int(parentInd)
        }

        switch layer.content {
        case .shape(let s):
            obj["ty"] = .int(4) // shape layer
            obj["shapes"] = .array([shapeGroup(s, fps: fps, name: layer.name, warnings: &warnings)])
        case .group, .null:
            obj["ty"] = .int(3) // null — keeps parenting rigs intact
        case .text:
            obj["ty"] = .int(3)
            warnings.append("Layer “\(layer.name)” (text) isn’t exported to Lottie yet — placed as an empty null.")
        case .image:
            obj["ty"] = .int(3)
            warnings.append("Layer “\(layer.name)” (image) isn’t exported to Lottie yet — placed as an empty null.")
        case .precomp:
            obj["ty"] = .int(3)
            warnings.append("Layer “\(layer.name)” (precomp) isn’t exported to Lottie yet — placed as an empty null.")
        case .video:
            obj["ty"] = .int(3)
            warnings.append("Layer “\(layer.name)” (video) is unsupported in Lottie — excluded (empty null).")
        }

        if !layer.effects.isEmpty {
            let kinds = layer.effects.map(\.type).joined(separator: ", ")
            warnings.append("Layer “\(layer.name)” effects (\(kinds)) have no portable Lottie equivalent — dropped.")
        }
        return .object(obj)
    }

    // MARK: Transform (ks)

    private static func transform(_ layer: Layer, fps: Double, warnings: inout [String]) -> JSONValue {
        let t = layer.transform
        // Anchor: ours is normalized to layer bounds; Lottie's `a` is in layer-local points.
        let size = layerSize(layer)
        let anchorN = t.anchor.resolve(at: 0)
        if t.anchor.isAnimated {
            warnings.append("Layer “\(layer.name)” has an animated anchor — exported at its t=0 value.")
        }
        let anchorPt = Vec2(anchorN.x * size.x, anchorN.y * size.y)

        return .object([
            "a": staticArray([anchorPt.x, anchorPt.y]),
            "p": arrayProp(t.position, fps: fps, name: layer.name, label: "position",
                           warnings: &warnings) { [$0.x, $0.y] },
            "s": arrayProp(t.scale, fps: fps, name: layer.name, label: "scale",
                           warnings: &warnings) { [$0.x * 100, $0.y * 100] },
            "r": scalarProp(t.rotation, fps: fps, name: layer.name, label: "rotation",
                            warnings: &warnings) { $0 },
            "o": scalarProp(t.opacity, fps: fps, name: layer.name, label: "opacity",
                            warnings: &warnings) { $0 * 100 },
        ])
    }

    private static func layerSize(_ layer: Layer) -> Vec2 {
        if case .shape(let s) = layer.content { return s.size.resolve(at: 0) }
        return .zero
    }

    // MARK: Shapes

    private static func shapeGroup(_ s: ShapeContent, fps: Double, name: String,
                                   warnings: inout [String]) -> JSONValue {
        if s.size.isAnimated {
            warnings.append("Shape “\(name)” has an animated size — exported at its t=0 value.")
        }
        let size = s.size.resolve(at: 0)
        var items: [JSONValue] = []

        switch s.geometry {
        case .rect:
            let r = s.cornerRadius?.resolve(at: 0) ?? 0
            items.append(.object([
                "ty": .string("rc"),
                "p": staticArray([size.x / 2, size.y / 2]),
                "s": staticArray([size.x, size.y]),
                "r": .object(["a": .int(0), "k": .number(r)]),
            ]))
        case .ellipse:
            items.append(.object([
                "ty": .string("el"),
                "p": staticArray([size.x / 2, size.y / 2]),
                "s": staticArray([size.x, size.y]),
            ]))
        case .path:
            warnings.append("Shape “\(name)” is a vector path — path/trim Lottie export is a follow-up; emitted as an empty group.")
        }

        if let fill = s.fillColor, !(s.gradient != nil) {
            if fill.isAnimated { warnings.append("Shape “\(name)” fill color animation exported at t=0.") }
            items.append(fillItem(fill.resolve(at: 0)))
        }
        if s.gradient != nil {
            warnings.append("Shape “\(name)” gradient fill has no v1 Lottie mapping yet — using a flat fill.")
            items.append(fillItem(.init(r: 0.5, g: 0.5, b: 0.5, a: 1)))
        }
        if let stroke = s.strokeColor, let w = s.strokeWidth, w.resolve(at: 0) > 0.01 {
            items.append(strokeItem(stroke.resolve(at: 0), width: w.resolve(at: 0)))
        }
        items.append(identityGroupTransform())

        return .object(["ty": .string("gr"), "nm": .string(name), "it": .array(items)])
    }

    private static func fillItem(_ c: ColorValue) -> JSONValue {
        .object([
            "ty": .string("fl"),
            "c": .object(["a": .int(0), "k": JSONValue.nums([c.r, c.g, c.b])]),
            "o": .object(["a": .int(0), "k": .number(c.a * 100)]),
            "r": .int(1),
        ])
    }

    private static func strokeItem(_ c: ColorValue, width: Double) -> JSONValue {
        .object([
            "ty": .string("st"),
            "c": .object(["a": .int(0), "k": JSONValue.nums([c.r, c.g, c.b])]),
            "o": .object(["a": .int(0), "k": .number(c.a * 100)]),
            "w": .object(["a": .int(0), "k": .number(width)]),
            "lc": .int(2), "lj": .int(2),
        ])
    }

    private static func identityGroupTransform() -> JSONValue {
        .object([
            "ty": .string("tr"),
            "a": staticArray([0, 0]), "p": staticArray([0, 0]),
            "s": staticArray([100, 100]),
            "r": .object(["a": .int(0), "k": .number(0)]),
            "o": .object(["a": .int(0), "k": .number(100)]),
        ])
    }

    // MARK: Property translation

    private static func staticArray(_ v: [Double]) -> JSONValue {
        .object(["a": .int(0), "k": JSONValue.nums(v)])
    }

    /// Multi-dimensional animatable (position, scale) → Lottie `{a,k}` with bezier-eased keyframes.
    private static func arrayProp(_ av: AnimatableValue<Vec2>, fps: Double, name: String, label: String,
                                  warnings: inout [String], map: (Vec2) -> [Double]) -> JSONValue {
        switch av {
        case .static(let v): return staticArray(map(v))
        case .animated(let tracks):
            guard let track = tracks.first else { return staticArray([0, 0]) }
            return .object(["a": .int(1),
                            "k": .array(keyframes(track, fps: fps, name: name, label: label,
                                                  warnings: &warnings, map: map))])
        }
    }

    /// Scalar animatable (rotation, opacity) → Lottie `{a,k}`. Static `k` is a bare number.
    private static func scalarProp(_ av: AnimatableValue<Double>, fps: Double, name: String, label: String,
                                   warnings: inout [String], map: (Double) -> Double) -> JSONValue {
        switch av {
        case .static(let v): return .object(["a": .int(0), "k": .number(map(v))])
        case .animated(let tracks):
            guard let track = tracks.first else { return .object(["a": .int(0), "k": .number(0)]) }
            return .object(["a": .int(1),
                            "k": .array(keyframes(track, fps: fps, name: name, label: label,
                                                  warnings: &warnings) { [map($0)] })])
        }
    }

    /// Build Lottie keyframes from a track. Each keyframe i (except the last) carries the segment's
    /// out (`o`) / in (`i`) bezier handles to keyframe i+1; hold → `h:1`; springs are warned and
    /// emitted as eased segments (dense sampling is a follow-up).
    private static func keyframes<V>(_ track: Track<V>, fps: Double, name: String, label: String,
                                     warnings: inout [String], map: (V) -> [Double]) -> [JSONValue] {
        let kfs = track.keyframes
        var out: [JSONValue] = []
        var warnedSpring = false
        for i in kfs.indices {
            let kf = kfs[i]
            var k: [String: JSONValue] = [
                "t": .number((kf.t * fps).rounded()),
                "s": JSONValue.nums(map(kf.v)),
            ]
            if i < kfs.count - 1 {
                switch kf.interp {
                case .hold:
                    k["h"] = .int(1)
                case .linear:
                    addHandles(&k, out: ControlPoint(0, 0), inn: ControlPoint(1, 1))
                case .bezier:
                    addHandles(&k, out: kf.easeOut ?? ControlPoint(0.42, 0),
                               inn: kfs[i + 1].easeIn ?? ControlPoint(0.58, 1))
                case .spring:
                    if !warnedSpring {
                        warnings.append("“\(name)” \(label) uses a spring — exported as an eased segment (spring sampling is a follow-up).")
                        warnedSpring = true
                    }
                    addHandles(&k, out: ControlPoint(0.3, 0), inn: ControlPoint(0.2, 1))
                }
            }
            out.append(.object(k))
        }
        return out
    }

    private static func addHandles(_ k: inout [String: JSONValue], out: ControlPoint, inn: ControlPoint) {
        k["o"] = .object(["x": JSONValue.nums([out.x]), "y": JSONValue.nums([out.y])])
        k["i"] = .object(["x": JSONValue.nums([inn.x]), "y": JSONValue.nums([inn.y])])
    }
}
