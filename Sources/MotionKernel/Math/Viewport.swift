import Foundation

/// Aspect-fit mapping between composition space and a view rectangle (both y-down, top-left
/// origin). The editor uses it to convert pointer/screen points to comp coordinates and to place
/// selection overlays — the same fit the renderer applies, expressed in points. Pure math, so it's
/// testable and shared rather than duplicated per surface.
public struct Viewport: Sendable, Equatable {
    public let compSize: Vec2
    public let viewSize: Vec2

    public init(compSize: Vec2, viewSize: Vec2) {
        self.compSize = compSize
        self.viewSize = viewSize
    }

    /// Uniform scale that fits the comp inside the view.
    public var scale: Double {
        let cw = max(compSize.x, 1), ch = max(compSize.y, 1)
        return min(viewSize.x / cw, viewSize.y / ch)
    }

    /// Top-left of the centered, fitted comp rectangle within the view.
    public var offset: Vec2 {
        Vec2((viewSize.x - compSize.x * scale) / 2, (viewSize.y - compSize.y * scale) / 2)
    }

    public func toView(_ compPoint: Vec2) -> Vec2 {
        Vec2(offset.x + compPoint.x * scale, offset.y + compPoint.y * scale)
    }

    public func toComp(_ viewPoint: Vec2) -> Vec2 {
        let s = scale
        guard s > 0 else { return .zero }
        return Vec2((viewPoint.x - offset.x) / s, (viewPoint.y - offset.y) / s)
    }
}
