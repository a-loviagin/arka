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
/// model, so Tier-1 maps directly.
///
/// Covered: composition metadata; shape (rect/ellipse) layers with fill/stroke/corner-radius; vector
/// paths + trim; null/group, image, text, and precomp layers; full animated transforms with bezier
/// easing; layer parenting; springs sampled to dense keyframes. Animated shape *geometry* and
/// gradients are exported best-effort (t=0 / flat) and flagged, so the file is always valid.
public enum LottieExporter {
    public static let version = "5.7.0"

    /// `assetData` maps an asset's `path` to its bytes (the app's content store) so image layers can
    /// embed a self-contained data URI. Absent bytes → the image layer is a warned placeholder.
    public static func export(_ document: MotionDocument, compId: EntityID,
                              assetData: [String: Data] = [:]) throws -> LottieExportResult {
        guard let comp = document.composition(compId) else {
            throw CommandError.compositionNotFound(compId)
        }
        let b = Builder(document: document, assetData: assetData)
        let layers = b.compLayers(comp, visiting: [])
        var root: [String: JSONValue] = [
            "v": .string(version),
            "fr": .number(comp.fps),
            "ip": .number(0),
            "op": .number((comp.duration * comp.fps).rounded()),
            "w": .number(comp.size.x),
            "h": .number(comp.size.y),
            "nm": .string(comp.name),
            "ddd": .int(0),
            "assets": .array(b.assets),
            "layers": .array(layers),
        ]
        if !b.fonts.isEmpty { root["fonts"] = .object(["list": .array(b.fonts)]) }
        return LottieExportResult(json: try JSONValue.object(root).data(), warnings: b.warnings)
    }
}

/// Accumulates the cross-cutting export state — warnings, precomp/image `assets`, and the `fonts`
/// list — across the (recursive) layer walk.
private final class Builder {
    let document: MotionDocument
    let assetData: [String: Data]
    var warnings: [String] = []
    var assets: [JSONValue] = []
    var fonts: [JSONValue] = []
    private var seenComps: Set<EntityID> = []
    private var seenImages: Set<String> = []
    private var fontNames: Set<String> = []

    init(document: MotionDocument, assetData: [String: Data]) {
        self.document = document
        self.assetData = assetData
    }

    /// Build one composition's Lottie layers (top-first; our render order is bottom→top).
    func compLayers(_ comp: Composition, visiting: Set<EntityID>) -> [JSONValue] {
        let ordered = Array(comp.layersInRenderOrder.reversed())
        var indByID: [EntityID: Int] = [:]
        for (i, layer) in ordered.enumerated() { indByID[layer.id] = i + 1 }
        return ordered.map { layer($0, comp: comp, indByID: indByID, visiting: visiting) }
    }

    // MARK: Layer

    private func layer(_ layer: Layer, comp: Composition, indByID: [EntityID: Int],
                       visiting: Set<EntityID>) -> JSONValue {
        let fps = comp.fps
        let op = (comp.duration * fps).rounded()
        var obj: [String: JSONValue] = [
            "nm": .string(layer.name.isEmpty ? "\(layer.id)" : layer.name),
            "ind": .int(indByID[layer.id] ?? 1),
            "ip": .number(0), "op": .number(op), "st": .number(0), "sr": .number(1), "ddd": .int(0),
            "ks": transform(layer, fps: fps),
        ]
        if let pid = layer.parentId, let parentInd = indByID[pid] { obj["parent"] = .int(parentInd) }

        switch layer.content {
        case .shape(let s):
            obj["ty"] = .int(4)
            obj["shapes"] = .array([shapeGroup(s, fps: fps, name: layer.name)])
        case .group, .null:
            obj["ty"] = .int(3)
        case .image(let img):
            obj["ty"] = .int(2)
            obj["refId"] = .string(imageAsset(img.assetId, name: layer.name))
        case .precomp(let pc):
            obj["ty"] = .int(0)
            let (refId, w, h) = precompAsset(pc.compositionId, name: layer.name, visiting: visiting)
            obj["refId"] = .string(refId)
            obj["w"] = .number(w); obj["h"] = .number(h)
        case .text(let tc):
            obj["ty"] = .int(5)
            obj["t"] = textDocument(tc, name: layer.name)
        case .video:
            obj["ty"] = .int(3)
            warnings.append("Layer “\(layer.name)” (video) is unsupported in Lottie — excluded (empty null).")
        }
        if !layer.effects.isEmpty {
            warnings.append("Layer “\(layer.name)” effects (\(layer.effects.map(\.type).joined(separator: ", "))) have no portable Lottie equivalent — dropped.")
        }
        return .object(obj)
    }

    // MARK: Precomp & image assets

    private func precompAsset(_ compId: EntityID, name: String, visiting: Set<EntityID>) -> (String, Double, Double) {
        let refId = "comp_\(compId)"
        guard let sub = document.composition(compId) else {
            warnings.append("Layer “\(name)” references a missing composition — emitted as an empty precomp.")
            return (refId, 0, 0)
        }
        if visiting.contains(compId) {
            warnings.append("Layer “\(name)” forms a precomp cycle — not expanded.")
            return (refId, sub.size.x, sub.size.y)
        }
        if !seenComps.contains(compId) {
            seenComps.insert(compId)
            let layers = compLayers(sub, visiting: visiting.union([compId]))
            assets.append(.object(["id": .string(refId), "layers": .array(layers)]))
        }
        return (refId, sub.size.x, sub.size.y)
    }

    private func imageAsset(_ assetId: EntityID, name: String) -> String {
        let refId = "image_\(assetId)"
        guard !seenImages.contains(refId) else { return refId }
        seenImages.insert(refId)
        guard let asset = document.asset(assetId) else {
            warnings.append("Layer “\(name)” references a missing image asset.")
            return refId
        }
        let size = asset.pixelSize ?? Vec2(0, 0)
        var entry: [String: JSONValue] = ["id": .string(refId), "w": .number(size.x), "h": .number(size.y)]
        if let data = assetData[asset.path] {
            let mime = asset.path.lowercased().hasSuffix(".jpg") || asset.path.lowercased().hasSuffix(".jpeg")
                ? "image/jpeg" : "image/png"
            entry["u"] = .string("")
            entry["p"] = .string("data:\(mime);base64,\(data.base64EncodedString())")
            entry["e"] = .int(1) // embedded
        } else {
            entry["u"] = .string("images/")
            entry["p"] = .string((asset.path as NSString).lastPathComponent)
            entry["e"] = .int(0)
            warnings.append("Image “\(name)” bytes weren’t available — referenced externally (images/…), not embedded.")
        }
        assets.append(.object(entry))
        return refId
    }

    // MARK: Text

    private func textDocument(_ tc: TextContent, name: String) -> JSONValue {
        let fontName = tc.fontFamily.isEmpty ? "Helvetica" : tc.fontFamily
        if !fontNames.contains(fontName) {
            fontNames.insert(fontName)
            fonts.append(.object([
                "fName": .string(fontName), "fFamily": .string(fontName),
                "fStyle": .string("Regular"), "fWeight": .string(""), "ascent": .number(72),
            ]))
        }
        if tc.fontSize.isAnimated || tc.fillColor.isAnimated {
            warnings.append("Text “\(name)” has animated size/color — exported at its t=0 value (Lottie text animators are a follow-up).")
        }
        let c = tc.fillColor.resolve(at: 0)
        let just: Int = { switch tc.alignment { case .left: 0; case .right: 1; case .center: 2 } }()
        let doc: [String: JSONValue] = [
            "t": .string(tc.string),
            "f": .string(fontName),
            "s": .number(tc.fontSize.resolve(at: 0)),
            "fc": JSONValue.nums([c.r, c.g, c.b]),
            "j": .int(just),
            "tr": .number(tc.tracking?.resolve(at: 0) ?? 0),
            "lh": .number(tc.lineHeight?.resolve(at: 0) ?? tc.fontSize.resolve(at: 0) * 1.2),
            "ls": .number(0),
        ]
        return .object([
            "d": .object(["k": .array([.object(["s": .object(doc), "t": .number(0)])])]),
            "p": .object([:]), "m": .object([:]), "a": .array([]),
        ])
    }

    // MARK: Transform (ks)

    private func transform(_ layer: Layer, fps: Double) -> JSONValue {
        let t = layer.transform
        let size = layerSize(layer)
        let anchorN = t.anchor.resolve(at: 0)
        if t.anchor.isAnimated {
            warnings.append("Layer “\(layer.name)” has an animated anchor — exported at its t=0 value.")
        }
        let anchorPt = Vec2(anchorN.x * size.x, anchorN.y * size.y)
        return .object([
            "a": staticArray([anchorPt.x, anchorPt.y]),
            "p": arrayProp(t.position, fps: fps, name: layer.name, label: "position") { [$0.x, $0.y] },
            "s": arrayProp(t.scale, fps: fps, name: layer.name, label: "scale") { [$0.x * 100, $0.y * 100] },
            "r": scalarProp(t.rotation, fps: fps, name: layer.name, label: "rotation") { $0 },
            "o": scalarProp(t.opacity, fps: fps, name: layer.name, label: "opacity") { $0 * 100 },
        ])
    }

    private func layerSize(_ layer: Layer) -> Vec2 {
        if case .shape(let s) = layer.content { return s.size.resolve(at: 0) }
        if case .image(let i) = layer.content { return document.asset(i.assetId)?.pixelSize ?? .zero }
        return .zero
    }

    // MARK: Shapes

    private func shapeGroup(_ s: ShapeContent, fps: Double, name: String) -> JSONValue {
        if s.size.isAnimated { warnings.append("Shape “\(name)” has an animated size — exported at its t=0 value.") }
        let size = s.size.resolve(at: 0)
        var items: [JSONValue] = []
        switch s.geometry {
        case .rect:
            let r = s.cornerRadius?.resolve(at: 0) ?? 0
            items.append(.object(["ty": .string("rc"), "p": staticArray([size.x / 2, size.y / 2]),
                                  "s": staticArray([size.x, size.y]), "r": .object(["a": .int(0), "k": .number(r)])]))
        case .ellipse:
            items.append(.object(["ty": .string("el"), "p": staticArray([size.x / 2, size.y / 2]),
                                  "s": staticArray([size.x, size.y])]))
        case .path:
            if let path = s.path {
                for sub in path.subpaths { items.append(pathShape(sub)) }
                if s.trimStart != nil || s.trimEnd != nil || s.trimOffset != nil {
                    items.append(trimItem(s, fps: fps, name: name))
                }
            }
        }
        if let fill = s.fillColor, s.gradient == nil {
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

    private func pathShape(_ sub: PathData.Subpath) -> JSONValue {
        let v = sub.vertices.map { JSONValue.nums([$0.point.x, $0.point.y]) }
        let i = sub.vertices.map { JSONValue.nums([$0.inTangent.x, $0.inTangent.y]) }
        let o = sub.vertices.map { JSONValue.nums([$0.outTangent.x, $0.outTangent.y]) }
        return .object(["ty": .string("sh"),
                        "ks": .object(["a": .int(0), "k": .object([
                            "c": .bool(sub.closed), "v": .array(v), "i": .array(i), "o": .array(o)])])])
    }

    private func trimItem(_ s: ShapeContent, fps: Double, name: String) -> JSONValue {
        .object(["ty": .string("tm"),
                 "s": scalarProp(s.trimStart ?? .static(0), fps: fps, name: name, label: "trim start") { $0 * 100 },
                 "e": scalarProp(s.trimEnd ?? .static(1), fps: fps, name: name, label: "trim end") { $0 * 100 },
                 "o": scalarProp(s.trimOffset ?? .static(0), fps: fps, name: name, label: "trim offset") { $0 * 360 },
                 "m": .int(1)])
    }

    private func fillItem(_ c: ColorValue) -> JSONValue {
        .object(["ty": .string("fl"), "c": .object(["a": .int(0), "k": JSONValue.nums([c.r, c.g, c.b])]),
                 "o": .object(["a": .int(0), "k": .number(c.a * 100)]), "r": .int(1)])
    }

    private func strokeItem(_ c: ColorValue, width: Double) -> JSONValue {
        .object(["ty": .string("st"), "c": .object(["a": .int(0), "k": JSONValue.nums([c.r, c.g, c.b])]),
                 "o": .object(["a": .int(0), "k": .number(c.a * 100)]),
                 "w": .object(["a": .int(0), "k": .number(width)]), "lc": .int(2), "lj": .int(2)])
    }

    private func identityGroupTransform() -> JSONValue {
        .object(["ty": .string("tr"), "a": staticArray([0, 0]), "p": staticArray([0, 0]),
                 "s": staticArray([100, 100]), "r": .object(["a": .int(0), "k": .number(0)]),
                 "o": .object(["a": .int(0), "k": .number(100)])])
    }

    // MARK: Property translation

    private func staticArray(_ v: [Double]) -> JSONValue { .object(["a": .int(0), "k": JSONValue.nums(v)]) }

    private func arrayProp(_ av: AnimatableValue<Vec2>, fps: Double, name: String, label: String,
                           map: (Vec2) -> [Double]) -> JSONValue {
        switch av {
        case .static(let v): return staticArray(map(v))
        case .animated(let tracks):
            guard let track = tracks.first else { return staticArray([0, 0]) }
            let ks = hasSpring(track) ? sampled(av, track, fps: fps, name: name, label: label, map: map)
                                      : keyframes(track, fps: fps, name: name, label: label, map: map)
            return .object(["a": .int(1), "k": .array(ks)])
        }
    }

    private func scalarProp(_ av: AnimatableValue<Double>, fps: Double, name: String, label: String,
                            map: (Double) -> Double) -> JSONValue {
        switch av {
        case .static(let v): return .object(["a": .int(0), "k": .number(map(v))])
        case .animated(let tracks):
            guard let track = tracks.first else { return .object(["a": .int(0), "k": .number(0)]) }
            let ks = hasSpring(track) ? sampled(av, track, fps: fps, name: name, label: label) { [map($0)] }
                                      : keyframes(track, fps: fps, name: name, label: label) { [map($0)] }
            return .object(["a": .int(1), "k": .array(ks)])
        }
    }

    private func hasSpring<V>(_ track: Track<V>) -> Bool {
        track.keyframes.contains { if case .spring = $0.interp { return true } else { return false } }
    }

    private func sampled<V: Componentwise>(_ av: AnimatableValue<V>, _ track: Track<V>, fps: Double,
                                           name: String, label: String, map: (V) -> [Double]) -> [JSONValue] {
        let kfs = track.keyframes
        guard let first = kfs.first, let last = kfs.last else { return [] }
        let f0 = Int((first.t * fps).rounded()), f1 = max(Int((last.t * fps).rounded()), f0 + 1)
        warnings.append("“\(name)” \(label) uses a spring — sampled to \(f1 - f0 + 1) keyframes at \(Int(fps))fps.")
        var out: [JSONValue] = []
        for f in f0...f1 {
            var k: [String: JSONValue] = ["t": .number(Double(f)), "s": JSONValue.nums(map(av.resolve(at: Double(f) / fps)))]
            if f < f1 { addHandles(&k, out: ControlPoint(0, 0), inn: ControlPoint(1, 1)) }
            out.append(.object(k))
        }
        return out
    }

    private func keyframes<V>(_ track: Track<V>, fps: Double, name: String, label: String,
                              map: (V) -> [Double]) -> [JSONValue] {
        let kfs = track.keyframes
        var out: [JSONValue] = []
        for i in kfs.indices {
            let kf = kfs[i]
            var k: [String: JSONValue] = ["t": .number((kf.t * fps).rounded()), "s": JSONValue.nums(map(kf.v))]
            if i < kfs.count - 1 {
                switch kf.interp {
                case .hold: k["h"] = .int(1)
                case .linear: addHandles(&k, out: ControlPoint(0, 0), inn: ControlPoint(1, 1))
                case .bezier:
                    addHandles(&k, out: kf.easeOut ?? ControlPoint(0.42, 0),
                               inn: kfs[i + 1].easeIn ?? ControlPoint(0.58, 1))
                case .spring: addHandles(&k, out: ControlPoint(0.3, 0), inn: ControlPoint(0.2, 1))
                }
            }
            out.append(.object(k))
        }
        return out
    }

    private func addHandles(_ k: inout [String: JSONValue], out: ControlPoint, inn: ControlPoint) {
        k["o"] = .object(["x": JSONValue.nums([out.x]), "y": JSONValue.nums([out.y])])
        k["i"] = .object(["x": JSONValue.nums([inn.x]), "y": JSONValue.nums([inn.y])])
    }
}
