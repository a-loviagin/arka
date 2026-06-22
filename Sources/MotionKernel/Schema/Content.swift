import Foundation

/// Type-specific layer payload (motion-document-schema.md §3). Animatable sub-properties are
/// `AnimatableValue`s; structural fields (asset refs, font family) change only via commands.
public enum LayerContent: Codable, Sendable, Equatable {
    case shape(ShapeContent)
    case text(TextContent)
    case image(ImageContent)
    case video(VideoContent)
    case group           // children via parentId; nothing to store
    case null            // pure transform parent (rigs)
    case precomp(PrecompContent)

    public var typeName: String {
        switch self {
        case .shape: "shape"
        case .text: "text"
        case .image: "image"
        case .video: "video"
        case .group: "group"
        case .null: "null"
        case .precomp: "precomp"
        }
    }

    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable {
        case shape, text, image, video, group, null, precomp
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch kind {
        case .shape: self = .shape(try single.decode(ShapeContent.self))
        case .text: self = .text(try single.decode(TextContent.self))
        case .image: self = .image(try single.decode(ImageContent.self))
        case .video: self = .video(try single.decode(VideoContent.self))
        case .group: self = .group
        case .null: self = .null
        case .precomp: self = .precomp(try single.decode(PrecompContent.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var typeContainer = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shape(let v): try typeContainer.encode(Kind.shape, forKey: .type); try v.encode(to: encoder)
        case .text(let v): try typeContainer.encode(Kind.text, forKey: .type); try v.encode(to: encoder)
        case .image(let v): try typeContainer.encode(Kind.image, forKey: .type); try v.encode(to: encoder)
        case .video(let v): try typeContainer.encode(Kind.video, forKey: .type); try v.encode(to: encoder)
        case .group: try typeContainer.encode(Kind.group, forKey: .type)
        case .null: try typeContainer.encode(Kind.null, forKey: .type)
        case .precomp(let v): try typeContainer.encode(Kind.precomp, forKey: .type); try v.encode(to: encoder)
        }
    }
}

// MARK: - Shape

public enum ShapeGeometry: String, Codable, Sendable, Equatable {
    case rect, ellipse, path
}

/// A vector path (properties-and-commands.md §1, Tier 2): one or more subpaths of cubic-bezier
/// vertices in layer-local points (origin top-left, y-down). Each vertex carries optional in/out
/// tangent handles *relative to its point* — both zero means a corner (straight segments). Static
/// for v1 (structural); path morphing (animated vertices) is a later extension.
public struct PathData: Codable, Sendable, Equatable {
    public struct Vertex: Codable, Sendable, Equatable {
        public var point: Vec2
        public var inTangent: Vec2   // handle for the incoming segment, relative to `point`
        public var outTangent: Vec2  // handle for the outgoing segment, relative to `point`
        public init(point: Vec2, inTangent: Vec2 = .zero, outTangent: Vec2 = .zero) {
            self.point = point; self.inTangent = inTangent; self.outTangent = outTangent
        }
        private enum CodingKeys: String, CodingKey { case point, inTangent, outTangent }
        public init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            point = try c.decode(Vec2.self, forKey: .point)
            inTangent = try c.decodeIfPresent(Vec2.self, forKey: .inTangent) ?? .zero
            outTangent = try c.decodeIfPresent(Vec2.self, forKey: .outTangent) ?? .zero
        }
        public func encode(to e: any Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(point, forKey: .point)
            if inTangent != .zero { try c.encode(inTangent, forKey: .inTangent) }
            if outTangent != .zero { try c.encode(outTangent, forKey: .outTangent) }
        }
    }

    public struct Subpath: Codable, Sendable, Equatable {
        public var vertices: [Vertex]
        public var closed: Bool
        public init(vertices: [Vertex], closed: Bool = true) {
            self.vertices = vertices; self.closed = closed
        }
        private enum CodingKeys: String, CodingKey { case vertices, closed }
        public init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            vertices = try c.decode([Vertex].self, forKey: .vertices)
            closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? true
        }
        public func encode(to e: any Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(vertices, forKey: .vertices)
            if !closed { try c.encode(closed, forKey: .closed) }
        }
    }

    public var subpaths: [Subpath]
    public init(subpaths: [Subpath]) { self.subpaths = subpaths }

    /// Axis-aligned bounds of all vertex points (tangent overshoot ignored — close enough for
    /// hit-testing/selection). nil when empty.
    public var bounds: (min: Vec2, max: Vec2)? {
        let points = subpaths.flatMap { $0.vertices.map(\.point) }
        guard let first = points.first else { return nil }
        var lo = first, hi = first
        for p in points.dropFirst() {
            lo = Vec2(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y))
            hi = Vec2(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y))
        }
        return (lo, hi)
    }
}

// MARK: - Gradient fill

public enum GradientKind: String, Codable, Sendable, Equatable { case linear, radial }

/// One gradient stop: a color at a normalized position (0…1 along the gradient). Both animatable
/// (properties-and-commands.md §1, Tier 2).
public struct GradientStop: Codable, Sendable, Equatable {
    public var position: AnimatableValue<Double>
    public var color: AnimatableValue<ColorValue>
    public init(position: AnimatableValue<Double>, color: AnimatableValue<ColorValue>) {
        self.position = position; self.color = color
    }
}

/// A gradient shape fill. `start`/`end` are in layer-local points: for `.linear` they're the two
/// ends of the axis; for `.radial`, `start` is the center and `|end − start|` the radius. When a
/// `ShapeContent.gradient` is present it overrides `fillColor`.
public struct GradientFill: Codable, Sendable, Equatable {
    public var kind: GradientKind
    public var start: AnimatableValue<Vec2>
    public var end: AnimatableValue<Vec2>
    public var stops: [GradientStop]
    public init(kind: GradientKind = .linear, start: AnimatableValue<Vec2>,
                end: AnimatableValue<Vec2>, stops: [GradientStop]) {
        self.kind = kind; self.start = start; self.end = end; self.stops = stops
    }
}

public struct ShapeContent: Codable, Sendable, Equatable {
    public var geometry: ShapeGeometry
    /// Rect/ellipse size in points (distinct from `scale` — animating `size` keeps stroke width).
    public var size: AnimatableValue<Vec2>
    public var fillColor: AnimatableValue<ColorValue>?
    public var strokeColor: AnimatableValue<ColorValue>?
    public var strokeWidth: AnimatableValue<Double>?
    /// Scalar (uniform) corner radius for Tier 1. Per-corner vec4 is a Tier-2 extension.
    public var cornerRadius: AnimatableValue<Double>?
    /// Vector outline, used when `geometry == .path`. Ignored for rect/ellipse.
    public var path: PathData?
    /// Stroke trim (properties-and-commands.md §1, Tier 2): line-drawing animation. Fractions 0…1 of
    /// the path's arc length; `trimEnd` defaults to 1 (whole path) and `trimOffset` rotates the
    /// visible span (wrapping on closed paths). Applies to the stroke only.
    public var trimStart: AnimatableValue<Double>?
    public var trimEnd: AnimatableValue<Double>?
    public var trimOffset: AnimatableValue<Double>?
    /// Gradient fill; overrides `fillColor` when present (Tier 2).
    public var gradient: GradientFill?

    public init(geometry: ShapeGeometry,
                size: AnimatableValue<Vec2> = .static(Vec2(100, 100)),
                fillColor: AnimatableValue<ColorValue>? = .static(.black),
                strokeColor: AnimatableValue<ColorValue>? = nil,
                strokeWidth: AnimatableValue<Double>? = nil,
                cornerRadius: AnimatableValue<Double>? = nil,
                path: PathData? = nil,
                trimStart: AnimatableValue<Double>? = nil,
                trimEnd: AnimatableValue<Double>? = nil,
                trimOffset: AnimatableValue<Double>? = nil,
                gradient: GradientFill? = nil) {
        self.geometry = geometry
        self.size = size
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.path = path
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.trimOffset = trimOffset
        self.gradient = gradient
    }

    // Omitted = default (schema §1): only `geometry` is required; size/fill default, the rest nil.
    private enum CodingKeys: String, CodingKey {
        case geometry, size, fillColor, strokeColor, strokeWidth, cornerRadius, path
        case trimStart, trimEnd, trimOffset, gradient
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        geometry = try c.decode(ShapeGeometry.self, forKey: .geometry)
        size = try c.decodeIfPresent(AnimatableValue<Vec2>.self, forKey: .size) ?? .static(Vec2(100, 100))
        fillColor = try c.decodeIfPresent(AnimatableValue<ColorValue>.self, forKey: .fillColor) ?? .static(.black)
        strokeColor = try c.decodeIfPresent(AnimatableValue<ColorValue>.self, forKey: .strokeColor)
        strokeWidth = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .strokeWidth)
        cornerRadius = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .cornerRadius)
        path = try c.decodeIfPresent(PathData.self, forKey: .path)
        trimStart = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .trimStart)
        trimEnd = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .trimEnd)
        trimOffset = try c.decodeIfPresent(AnimatableValue<Double>.self, forKey: .trimOffset)
        gradient = try c.decodeIfPresent(GradientFill.self, forKey: .gradient)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(geometry, forKey: .geometry)
        try c.encode(size, forKey: .size)
        try c.encodeIfPresent(fillColor, forKey: .fillColor)
        try c.encodeIfPresent(strokeColor, forKey: .strokeColor)
        try c.encodeIfPresent(strokeWidth, forKey: .strokeWidth)
        try c.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(trimStart, forKey: .trimStart)
        try c.encodeIfPresent(trimEnd, forKey: .trimEnd)
        try c.encodeIfPresent(trimOffset, forKey: .trimOffset)
        try c.encodeIfPresent(gradient, forKey: .gradient)
    }
}

// MARK: - Text

public enum TextAlignment: String, Codable, Sendable, Equatable {
    case left, center, right
}

public struct TextContent: Codable, Sendable, Equatable {
    public var string: String
    public var fontFamily: String
    public var fontSize: AnimatableValue<Double>
    public var tracking: AnimatableValue<Double>?
    public var fillColor: AnimatableValue<ColorValue>
    public var alignment: TextAlignment
    /// Line advance in points for multi-line text (the string may contain "\n"). nil / ≤ 0 means the
    /// font's natural line height (ascent + descent + leading).
    public var lineHeight: AnimatableValue<Double>?

    public init(string: String,
                fontFamily: String = "Helvetica",
                fontSize: AnimatableValue<Double> = .static(48),
                tracking: AnimatableValue<Double>? = nil,
                fillColor: AnimatableValue<ColorValue> = .static(.black),
                alignment: TextAlignment = .left,
                lineHeight: AnimatableValue<Double>? = nil) {
        self.string = string
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.tracking = tracking
        self.fillColor = fillColor
        self.alignment = alignment
        self.lineHeight = lineHeight
    }
}

// MARK: - Image / Video

public enum FitMode: String, Codable, Sendable, Equatable {
    case fill, fit, stretch, none
}

public struct ImageContent: Codable, Sendable, Equatable {
    public var assetId: EntityID
    public var fit: FitMode
    public init(assetId: EntityID, fit: FitMode = .fit) {
        self.assetId = assetId
        self.fit = fit
    }
}

public struct VideoContent: Codable, Sendable, Equatable {
    public var assetId: EntityID
    public var trimStart: TimeInterval
    public var trimEnd: TimeInterval?
    public var speed: Double
    public init(assetId: EntityID, trimStart: TimeInterval = 0,
                trimEnd: TimeInterval? = nil, speed: Double = 1) {
        self.assetId = assetId
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.speed = speed
    }
}

// MARK: - Precomp

public struct PrecompContent: Codable, Sendable, Equatable {
    public var compositionId: EntityID
    public init(compositionId: EntityID) {
        self.compositionId = compositionId
    }
}
