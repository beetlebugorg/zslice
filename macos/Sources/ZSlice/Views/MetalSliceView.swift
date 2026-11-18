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
//! The window model (Workspace) is the delegate of the view. It gets the
//! keys of the view, a call on each frame of a replay, and a call when the
//! appearance changes (the colors of the view come with its data).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import ImageIO
import QuartzCore
import SwiftUI

/// The window side of the 3D view.
@MainActor
protocol SliceViewDelegate: AnyObject {
    /// One frame of the display link, dt seconds after the frame before.
    /// Returns true while it needs more frames (a replay).
    func sliceViewTick(_ dt: Double) -> Bool
    /// A key in the view. Returns true if it used the key.
    func sliceViewKey(_ event: NSEvent) -> Bool
    /// The light or dark look changed: load the scene again.
    func sliceViewAppearanceChanged()
}

final class MetalSliceView: NSView {
    weak var delegate: SliceViewDelegate?
    private(set) var view: OpaquePointer?
    private let renderer: FrameRenderer?
    private var link: CADisplayLink?
    private var needsFrame = false
    private var animating = false
    private var lastTick: CFTimeInterval = 0
    private var lastDrag: NSPoint?
    private var loaded = false
    private var ticking = false

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

    private func updateDark() {
        guard let view else { return }
        zs_view_set_dark(view, isDark ? 1 : 0)
        delegate?.sliceViewAppearanceChanged()
        requestFrame()
    }

    /// Loads the last slice of an app into the view.
    func load(_ core: OpaquePointer) {
        guard let view else { return }
        let rc = zs_view_load(view, core)
        if rc != 0 { NSLog("zslice: the 3D view did not load the toolpaths: \(statusText(rc))") }
        loaded = rc == 0
        requestFrame()
    }

    func requestFrame() {
        needsFrame = true
        link?.isPaused = false
    }

    /// Calls the delegate on each frame until it returns false.
    func startTicking() {
        ticking = true
        lastTick = 0
        requestFrame()
    }

    func startAnimation() {
        animating = true
        lastTick = 0
        requestFrame()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view else { return }
        let now = link.timestamp
        let dt = min(lastTick == 0 ? 1.0 / 60 : now - lastTick, 0.1)
        lastTick = now
        if ticking {
            ticking = delegate?.sliceViewTick(dt) ?? false
            needsFrame = true
        }
        if animating {
            animating = zs_view_animate(view, dt) != 0
            needsFrame = true
        }
        if needsFrame {
            needsFrame = false
            drawFrame()
        }
        if !animating && !ticking && !needsFrame {
            link.isPaused = true
            lastTick = 0
        }
    }

    /// For development and screenshots: ZSLICE_SNAPSHOT=path.png writes the
    /// window to that file, after the first frame of a slice. The 3D view
    /// comes from Metal, and the controls over it from AppKit
    /// (cacheDisplay draws them, but not the Metal layer). So it needs no
    /// permission to record the screen.
    private var snapshot = ProcessInfo.processInfo.environment["ZSLICE_SNAPSHOT"].map { URL(fileURLWithPath: $0) }

    private func drawFrame() {
        guard let view, let renderer else { return }
        let rc = zs_view_draw(view)
        guard rc == 0, let frame = zs_view_web_frame(view) else {
            if rc != 0 { NSLog("zslice: the 3D view did not draw: \(statusText(rc))") }
            return
        }
        var shot: (@Sendable (CGImage) -> Void)?
        if loaded, let url = snapshot {
            snapshot = nil
            shot = { image in
                // A moment later, so the controls show the new slice.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated { self.writeSnapshot(image, to: url) }
                }
            }
        }
        renderer.draw(frame.pointee, in: metalLayer, snapshot: shot)
    }

    private func writeSnapshot(_ frame: CGImage, to url: URL) {
        guard let content = window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard let ui = rep.cgImage,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        // The 3D view at its place in the window (AppKit has y up).
        let r = convert(bounds, to: content)
        let k = CGFloat(w) / content.bounds.width
        ctx.draw(frame, in: CGRect(x: r.minX * k, y: (content.bounds.height - r.maxY) * k, width: r.width * k, height: r.height * k))
        ctx.draw(ui, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - input

    private func pixel(_ event: NSEvent) -> (Float, Float) {
        let p = convert(event.locationInWindow, from: nil)
        return (Float(p.x * scale), Float(p.y * scale))
    }

    override func keyDown(with event: NSEvent) {
        if delegate?.sliceViewKey(event) != true { super.keyDown(with: event) }
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

/// The 3D view for SwiftUI. The window model owns the NSView, so the view
/// and its camera stay when SwiftUI makes this struct again.
struct SliceView: NSViewRepresentable {
    let canvas: MetalSliceView

    func makeNSView(context: Context) -> MetalSliceView { canvas }
    func updateNSView(_ nsView: MetalSliceView, context: Context) {}
}
