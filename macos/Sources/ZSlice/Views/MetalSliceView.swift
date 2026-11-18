//! MetalSliceView: the 3D view of a slice, an NSView over a CAMetalLayer.
//!
//! The view owns one zs_view of the core with no native surface
//! (ZS_SURFACE_FRAME). On each frame it calls zs_view_draw, which keeps the
//! frame data in the core, and FrameRenderer draws that data with Metal.
//!
//! The view draws only when something changes: an input, a camera
//! animation, a new slice, or a new size. The display link of the view
//! runs while a frame waits or the camera moves, and pauses after that, so
//! the app is idle at rest.
//!
//! The core takes pixels with the origin at the top left. The view is
//! flipped, and it multiplies points by the backing scale.
//!
//! Input, as in the GTK app (linux/src/ui/view3d.c):
//! - a left drag orbits;
//! - a right or middle drag pans (a two-finger press and drag on a
//!   trackpad is a right drag);
//! - a two-finger scroll on a trackpad zooms toward the pointer, and so do
//!   the mouse wheel and a pinch.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import QuartzCore
import SwiftUI

final class MetalSliceView: NSView {
    private(set) var view: OpaquePointer?
    private let renderer: FrameRenderer?
    private var link: CADisplayLink?
    private var needsFrame = false
    private var animating = false
    private var lastTick: CFTimeInterval = 0
    private var lastDrag: NSPoint?
    private var loadedGeneration = -1

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        renderer = FrameRenderer()
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        var surface = zs_surface(kind: Int32(ZS_SURFACE_FRAME.rawValue), display: nil, surface: nil, window: 0)
        var v: OpaquePointer?
        if renderer != nil, zs_view_new(&surface, 1, 1, &v) == 0 { view = v }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        link?.invalidate()
        if let view { zs_view_free(view) }
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = renderer?.device
        l.pixelFormat = FrameRenderer.colorFormat
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        l.framebufferOnly = ProcessInfo.processInfo.environment["ZSLICE_SNAPSHOT"] == nil
        l.isOpaque = true
        return l
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            link?.invalidate()
            link = nil
            return
        }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            l.isPaused = true
            link = l
        }
        updateDark()
        resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = scale
        resizeDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeDrawable()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDark()
    }

    private func resizeDrawable() {
        let w = max(1, (bounds.width * scale).rounded()), h = max(1, (bounds.height * scale).rounded())
        metalLayer.drawableSize = CGSize(width: w, height: h)
        if let view { zs_view_resize(view, UInt32(w), UInt32(h)) }
        requestFrame()
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var model: SliceModel?

    private func updateDark() {
        guard let view else { return }
        zs_view_set_dark(view, isDark ? 1 : 0)
        // The colors of the view come with its data.
        if let model, model.resultGeneration > 0 { zs_view_load(view, model.core) }
        requestFrame()
    }

    /// Loads the new slice of the model into the view.
    func show(_ model: SliceModel) {
        self.model = model
        guard let view, model.resultGeneration != loadedGeneration, model.state == .done else { return }
        loadedGeneration = model.resultGeneration
        let rc = zs_view_load(view, model.core)
        if rc != 0 { NSLog("zslice: the 3D view did not load the toolpaths: \(statusText(rc))") }
        requestFrame()
    }

    func requestFrame() {
        needsFrame = true
        link?.isPaused = false
    }

    private func startAnimation() {
        animating = true
        lastTick = 0
        requestFrame()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view else { return }
        if animating {
            let now = link.timestamp
            let dt = lastTick == 0 ? 1.0 / 60 : now - lastTick
            lastTick = now
            animating = zs_view_animate(view, min(dt, 0.1)) != 0
            needsFrame = true
        }
        if needsFrame {
            needsFrame = false
            drawFrame()
        }
        if !animating && !needsFrame { link.isPaused = true }
    }

    /// For development and screenshots: ZSLICE_SNAPSHOT=path.png writes the
    /// first frame of a slice to that file.
    private var snapshot = ProcessInfo.processInfo.environment["ZSLICE_SNAPSHOT"].map { URL(fileURLWithPath: $0) }

    private func drawFrame() {
        guard let view, let renderer else { return }
        let rc = zs_view_draw(view)
        guard rc == 0, let frame = zs_view_web_frame(view) else {
            if rc != 0 { NSLog("zslice: the 3D view did not draw: \(statusText(rc))") }
            return
        }
        var shot: URL?
        if loadedGeneration >= 0, let s = snapshot {
            shot = s
            snapshot = nil
        }
        renderer.draw(frame.pointee, in: metalLayer, snapshot: shot)
    }

    // MARK: - input

    private func pixel(_ event: NSEvent) -> (Float, Float) {
        let p = convert(event.locationInWindow, from: nil)
        return (Float(p.x * scale), Float(p.y * scale))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDown(with event: NSEvent) { lastDrag = convert(event.locationInWindow, from: nil) }
    override func otherMouseDown(with event: NSEvent) { lastDrag = convert(event.locationInWindow, from: nil) }

    private func dragDelta(_ event: NSEvent) -> (Float, Float)? {
        let p = convert(event.locationInWindow, from: nil)
        defer { lastDrag = p }
        guard let last = lastDrag else { return nil }
        return (Float(p.x - last.x), Float(p.y - last.y))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let view, let (dx, dy) = dragDelta(event) else { return }
        zs_view_orbit(view, dx, dy)
        requestFrame()
    }

    override func rightMouseDragged(with event: NSEvent) { pan(event) }
    override func otherMouseDragged(with event: NSEvent) { pan(event) }

    private func pan(_ event: NSEvent) {
        guard let view, let (dx, dy) = dragDelta(event) else { return }
        let s = Float(scale)
        zs_view_pan(view, dx * s, dy * s)
        requestFrame()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let view else { return }
        let (px, py) = pixel(event)
        // A positive delta of AppKit scrolls up (away from the user); it
        // zooms in, as a GTK scroll with a negative dy does.
        if event.hasPreciseScrollingDeltas {
            // A trackpad: 40 points are one wheel step.
            zs_view_zoom_at(view, powf(1.15, Float(-event.scrollingDeltaY / 40)), px, py)
            requestFrame()
        } else if event.scrollingDeltaY != 0 {
            zs_view_zoom_at(view, powf(1.15, event.scrollingDeltaY > 0 ? -1 : 1), px, py)
            startAnimation()
        }
    }

    override func magnify(with event: NSEvent) {
        guard let view else { return }
        let (px, py) = pixel(event)
        zs_view_zoom_at(view, Float(1 / (1 + event.magnification)), px, py)
        requestFrame()
    }
}

/// The 3D view for SwiftUI.
struct SliceView: NSViewRepresentable {
    let model: SliceModel

    func makeNSView(context: Context) -> MetalSliceView {
        MetalSliceView(frame: .zero)
    }

    func updateNSView(_ nsView: MetalSliceView, context: Context) {
        // Reading resultGeneration here makes SwiftUI call this again for
        // each new slice.
        _ = model.resultGeneration
        nsView.show(model)
    }
}
