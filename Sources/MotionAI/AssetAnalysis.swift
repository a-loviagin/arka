import Foundation

/// One-time analysis of an imported asset (ai-pipeline.md §3), cached and sent as *text* with every
/// request — the model never re-sees an asset's raw pixels (only the canvas snapshot does that). The
/// palette + dimensions are deterministic CV (extracted in the render layer); `subject` is an
/// optional one-line vision description.
public struct AssetAnalysis: Codable, Sendable, Equatable {
    public var assetId: String
    public var palette: [String]      // dominant colors, #RRGGBB
    public var subject: String?       // e.g. "a blue rocket logo on transparent background"
    public var width: Int
    public var height: Int

    public init(assetId: String, palette: [String] = [], subject: String? = nil,
                width: Int = 0, height: Int = 0) {
        self.assetId = assetId; self.palette = palette; self.subject = subject
        self.width = width; self.height = height
    }
}
