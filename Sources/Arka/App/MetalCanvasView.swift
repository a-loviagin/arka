#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import Metal
import simd
import MotionKernel

/// AppKit-hosted Metal canvas (editor-ui.md §1-2): the display-speed surface, bridged into SwiftUI.
/// Driven by the engine's preview path — a `CADisplayLink` tick asks the clock for time, evaluates
/// the scene, and draws. Scrubbing later uses this exact path (render at t), so it feels identical.
final class CanvasNSView: NSView {
    private var renderer: MetalRenderer?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?

    var document: MotionDocument
    let playback: PlaybackController

    init(document: MotionDocument, playback: PlaybackController) {
        self.document = document
        self.playback = playback
        super.init(frame: .zero)
        wantsLayer = true
        if let device = MTLCreateSystemDefaultDevice() {
            metalLayer.device = device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = true
            renderer = try? MetalRenderer(device: device)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

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
        playback.tick()
        render()
    }

    func render() {
        guard let renderer, let comp = document.mainComposition,
              let drawable = metalLayer.nextDrawable() else { return }
        let t = playback.currentTime
        let items = RenderTreeBuilder(document: document).build(compId: comp.id, at: t)
        let vp = SIMD2<Float>(Float(metalLayer.drawableSize.width),
                              Float(metalLayer.drawableSize.height))
        let bg = comp.backgroundColor
        renderer.draw(items: items,
                      compSize: SIMD2<Float>(Float(comp.size.x), Float(comp.size.y)),
                      viewport: vp,
                      clear: SIMD4<Double>(bg.r, bg.g, bg.b, bg.a),
                      to: drawable)
    }
}

/// SwiftUI bridge for the canvas (editor-ui.md §1: `NSViewRepresentable`).
struct MetalCanvasView: NSViewRepresentable {
    let document: MotionDocument
    let playback: PlaybackController

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(document: document, playback: playback)
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.document = document
    }
}
#endif
