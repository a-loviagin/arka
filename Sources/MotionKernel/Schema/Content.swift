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

public struct ShapeContent: Codable, Sendable, Equatable {
    public var geometry: ShapeGeometry
    /// Rect/ellipse size in points (distinct from `scale` — animating `size` keeps stroke width).
    public var size: AnimatableValue<Vec2>
    public var fillColor: AnimatableValue<ColorValue>?
    public var strokeColor: AnimatableValue<ColorValue>?
    public var strokeWidth: AnimatableValue<Double>?
    /// Scalar (uniform) corner radius for Tier 1. Per-corner vec4 is a Tier-2 extension.
    public var cornerRadius: AnimatableValue<Double>?

    public init(geometry: ShapeGeometry,
                size: AnimatableValue<Vec2> = .static(Vec2(100, 100)),
                fillColor: AnimatableValue<ColorValue>? = .static(.black),
                strokeColor: AnimatableValue<ColorValue>? = nil,
                strokeWidth: AnimatableValue<Double>? = nil,
                cornerRadius: AnimatableValue<Double>? = nil) {
        self.geometry = geometry
        self.size = size
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
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

    public init(string: String,
                fontFamily: String = "Helvetica",
                fontSize: AnimatableValue<Double> = .static(48),
                tracking: AnimatableValue<Double>? = nil,
                fillColor: AnimatableValue<ColorValue> = .static(.black),
                alignment: TextAlignment = .left) {
        self.string = string
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.tracking = tracking
        self.fillColor = fillColor
        self.alignment = alignment
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
