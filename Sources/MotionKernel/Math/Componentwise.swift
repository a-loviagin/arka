import Foundation

/// A value decomposable into scalar components. Lets the evaluator handle two things generically:
/// separated-dimension tracks (position split into X/Y) and per-component spring math (the
/// closed-form spring is scalar; a Vec2/Color spring is one solve per component).
///
/// `lerp`/`cubic` (from `Interpolatable`) still own straight/bezier blending — for color that
/// stays in OKLab. Component decomposition is only used for separation and springs.
public protocol Componentwise: Interpolatable {
    static var components: [Component] { get }
    func component(_ c: Component) -> Double
    static func fromComponents(_ f: (Component) -> Double) -> Self
}

extension Double: Componentwise {
    public static var components: [Component] { [.x] }
    public func component(_ c: Component) -> Double { self }
    public static func fromComponents(_ f: (Component) -> Double) -> Double { f(.x) }
}

extension Vec2: Componentwise {
    public static var components: [Component] { [.x, .y] }
    public func component(_ c: Component) -> Double { c == .x ? x : y }
    public static func fromComponents(_ f: (Component) -> Double) -> Vec2 {
        Vec2(f(.x), f(.y))
    }
}

extension ColorValue: Componentwise {
    public static var components: [Component] { [.x, .y, .z, .w] }
    public func component(_ c: Component) -> Double {
        switch c { case .x: r; case .y: g; case .z: b; case .w: a }
    }
    public static func fromComponents(_ f: (Component) -> Double) -> ColorValue {
        ColorValue(r: f(.x), g: f(.y), b: f(.z), a: f(.w))
    }
}
