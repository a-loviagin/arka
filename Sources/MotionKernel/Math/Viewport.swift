import Foundation

/// Linear mapping between a coordinate space (composition space, or the multi-frame *board* space)
/// and a view rectangle (both y-down, top-left origin). The editor uses it to convert pointer/screen
/// points to scene coordinates and to place selection overlays — the same fit the renderer applies,
/// expressed in points. Pure math, so it's testable and shared rather than duplicated per surface.
///
/// A `Viewport` is fully described by a uniform `scale` and a view-space `offset` (where the scene
/// origin lands). Construct it for the classic single-comp aspect-fit, or directly from a board
/// pan/zoom.
public struct Viewport: Sendable, Equatable {
    /// Uniform scene→view scale (points per scene unit).
    public let scale: Double
    /// View-space point where the scene origin (0,0) lands — top-left of the fitted scene rect.
    public let offset: Vec2

    /// Explicit pan/zoom — used by the multi-frame board, where `offset` is the pan and `scale` the
    /// zoom. Scene coordinates here are *board* coordinates.
    public init(scale: Double, offset: Vec2) {
        self.scale = scale
        self.offset = offset
    }

    /// Aspect-fit a composition centered inside a view rectangle (the single-frame editor default).
    public init(compSize: Vec2, viewSize: Vec2) {
        let cw = max(compSize.x, 1), ch = max(compSize.y, 1)
        let s = min(viewSize.x / cw, viewSize.y / ch)
        self.scale = s
        self.offset = Vec2((viewSize.x - compSize.x * s) / 2, (viewSize.y - compSize.y * s) / 2)
    }

    public func toView(_ scenePoint: Vec2) -> Vec2 {
        Vec2(offset.x + scenePoint.x * scale, offset.y + scenePoint.y * scale)
    }

    public func toComp(_ viewPoint: Vec2) -> Vec2 {
        guard scale > 0 else { return .zero }
        return Vec2((viewPoint.x - offset.x) / scale, (viewPoint.y - offset.y) / scale)
    }
}
