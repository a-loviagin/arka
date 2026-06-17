#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import Metal
import simd
import MotionKernel
import MotionRender

/// AppKit-hosted Metal canvas (editor-ui.md §1-2): the display-speed surface, bridged into SwiftUI.
/// Driven by the engine's preview path — a `CADisplayLink` tick asks the clock for time, evaluates
/// the scene, and draws. It reads the live `DocumentModel` each tick, so opening a package or
/// editing the document refreshes the canvas automatically.
final class CanvasNSView: NSView {
    private let model: DocumentModel
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?

    init(model: DocumentModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = model.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    // Display-only: let mouse events fall through to the SwiftUI selection/drag overlay above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        guard window != nil, displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(bounds.width * scale, 1),
                          height: max(bounds.height * scale, 1))
        metalLayer.drawableSize = size
        metalLayer.contentsScale = scale
    }

    @objc private func step() {
        model.playback.tick()
        render()
    }

    func render() {
        guard let renderer = model.renderer, let comp = model.document.mainComposition,
              let drawable = metalLayer.nextDrawable() else { return }
        let t = model.playback.currentTime
        let nodes = RenderTreeBuilder(document: model.document, textEngine: model.textEngine,
                                      textures: model.textures).build(compId: comp.id, at: t)
        let vp = SIMD2<Float>(Float(metalLayer.drawableSize.width),
                              Float(metalLayer.drawableSize.height))
        let bg = comp.backgroundColor
        renderer.draw(nodes: nodes,
                      compSize: SIMD2<Float>(Float(comp.size.x), Float(comp.size.y)),
                      viewport: vp,
                      clear: SIMD4<Double>(bg.r, bg.g, bg.b, bg.a),
                      to: drawable)
    }
}

/// SwiftUI bridge for the canvas (editor-ui.md §1: `NSViewRepresentable`).
struct MetalCanvasView: NSViewRepresentable {
    let model: DocumentModel

    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(model: model) }
    func updateNSView(_ nsView: CanvasNSView, context: Context) {}
}
#endif
