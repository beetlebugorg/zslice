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
//! The view has two pages. The 3D page draws the frame data of the core
//! (FrameRenderer). The 2D page draws one layer from the top
//! (LayerRenderer): a drag pans, the wheel and a pinch zoom toward the
//! pointer, and a double click fits the part in the view (as
//! web/app/view2d.js).
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
    /// A click with no drag, at a point of the view (points from the top left).
    func sliceViewClick(_ p: CGPoint)
    /// A double click on the 3D page. Returns true if the camera moves.
    func sliceViewDoubleClick(_ p: CGPoint) -> Bool
    /// A press of the left button. Returns true if the window takes the
    /// drag (a move of a part, an end of the measure tape); then the view
    /// does not orbit, and the drag and the release go to the window.
    func sliceViewPress(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> Bool
    func sliceViewDrag(_ p: CGPoint, _ flags: NSEvent.ModifierFlags)
    func sliceViewRelease(_ p: CGPoint)
    /// A scroll with Command: turns the selected part. Returns true if it did.
    func sliceViewTurnWheel(_ dy: CGFloat) -> Bool
    /// After each frame (the floating labels follow the camera).
    func sliceViewDidDraw()
}

final class MetalSliceView: NSView {
    enum Page: String { case threeD = "3d", twoD = "2d" }

    weak var delegate: SliceViewDelegate?
    /// The page that shows.
    var page = Page.threeD {
        didSet { if page != oldValue { requestFrame() } }
    }
    /// The layer of the 2D page.
    var layer2D = 0 {
        didSet { if page == .twoD { requestFrame() } }
    }
    /// The focus of the 2D page: the lines out of it are faint.
    var focus2D: UInt32 = 0 {
        didSet { if page == .twoD { requestFrame() } }
    }
    /// All lines of the 2D page faint: a focus on the first layer while
    /// the page shows another layer.
    var dim2D = false {
        didSet { if page == .twoD && dim2D != oldValue { requestFrame() } }
    }
    private var layerRenderer: LayerRenderer?
    // The camera of the 2D page: a point (x, y) mm is at
    // (ox + x * scale, oy + y * scale) pixels from the bottom left.
    private var scale2D = 1.0, ox2D = 0.0, oy2D = 0.0
    private var fitted2D = false
    /// The selected path of the 2D page: its beads, and the segment.
    var selection2D: (UInt32, UInt32, Int)? {
        didSet { if page == .twoD { requestFrame() } }
    }
    private var pressAt: NSPoint?
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
        if let renderer { layerRenderer = LayerRenderer(renderer) }
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
        if loaded, snapshot != nil, snapshotDue == nil {
            snapshotDue = CACurrentMediaTime() + 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.requestFrame() }
        }
        layerRenderer?.setOutlines(from: view)
        fitted2D = false
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
    /// window to that file, 1.5 s after the first load of a slice (so a
    /// camera animation and the hooks of the window are done). The 3D view
    /// comes from Metal, and the controls over it from AppKit
    /// (cacheDisplay draws them, but not the Metal layer). So it needs no
    /// permission to record the screen.
    private var snapshotDue: CFTimeInterval?
    private var snapshot = ProcessInfo.processInfo.environment["ZSLICE_SNAPSHOT"].map { URL(fileURLWithPath: $0) }

    private func drawFrame() {
        guard let view, let renderer else { return }
        let rc = zs_view_draw(view)
        guard rc == 0, let frame = zs_view_web_frame(view) else {
            if rc != 0 { NSLog("zslice: the 3D view did not draw: \(statusText(rc))") }
            return
        }
        var shot: (@Sendable (CGImage) -> Void)?
        if loaded, let url = snapshot, let due = snapshotDue, CACurrentMediaTime() >= due {
            snapshot = nil
            shot = { image in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.writeSnapshot(image, to: url) }
                }
            }
        }
        if page == .twoD, let lr = layerRenderer {
            renderer.sync(frame.pointee)
            lr.setBed(from: frame.pointee)
            lr.draw(layerFrame(view), in: metalLayer, snapshot: shot)
        } else {
            renderer.draw(frame.pointee, in: metalLayer, snapshot: shot)
        }
        delegate?.sliceViewDidDraw()
    }

    /// The point of the view (points from the top left) of a point of the
    /// print (mm), on the page that shows, or nil (behind the camera).
    func viewPoint(x: Double, y: Double, z: Double) -> CGPoint? {
        guard let view else { return nil }
        if page == .twoD {
            let px = ox2D + x * scale2D, py = Double(pixelSize.1) - (oy2D + y * scale2D)
            return CGPoint(x: px / scale, y: py / scale)
        }
        var px: Float = 0, py: Float = 0
        guard zs_view_pixel_of(view, x, y, z, &px, &py) != 0 else { return nil }
        return CGPoint(x: CGFloat(px) / scale, y: CGFloat(py) / scale)
    }

    private var pixelSize: (Int, Int) { (Int(metalLayer.drawableSize.width), Int(metalLayer.drawableSize.height)) }

    /// What the 2D page draws now.
    private func layerFrame(_ view: OpaquePointer) -> LayerFrame {
        let (w, h) = pixelSize
        if !fitted2D { fit2D() }
        var f = LayerFrame(width: w, height: h, scale: scale2D, ox: ox2D, oy: oy2D, layer: layer2D)
        var a: UInt32 = 0, b: UInt32 = 0
        if zs_view_layer_beads(view, layer2D, &a, &b) == 0 { f.beads = (a, b) }
        if zs_view_layer_marks(view, layer2D, &a, &b) == 0 { f.marks = (a, b) }
        f.dark = isDark
        f.mask = focus2D
        if let (a, b, seg) = selection2D, a >= f.beads.0, b <= f.beads.1 {
            f.selection = (a, b)
            if seg >= 0 && a + UInt32(seg) < b { f.segment = Int(a) + seg }
        }
        f.dim = dim2D
        return f
    }

    /// Fits the beads (or the bed, with no beads) in the view: 85 % of it.
    func fit2D() {
        guard let view else { return }
        let (w, h) = pixelSize
        var b = [Double](repeating: 0, count: 4)
        if zs_view_bounds(view, &b) != 0 {
            let bed = layerRenderer?.bed ?? [220, 220]
            b = [0, 0, Double(bed.x), Double(bed.y)]
        }
        let bw = max(b[2] - b[0], 1), bh = max(b[3] - b[1], 1)
        scale2D = 0.85 * min(Double(w) / bw, Double(h) / bh)
        ox2D = Double(w) / 2 - (b[0] + b[2]) / 2 * scale2D
        oy2D = Double(h) / 2 - (b[1] + b[3]) / 2 * scale2D
        fitted2D = true
        requestFrame()
    }

    /// The point of the bed (mm) under a point of the 2D page.
    func millimeters(of p: CGPoint) -> (x: Double, y: Double)? {
        guard page == .twoD, scale2D > 0 else { return nil }
        let px = Double(p.x * scale), py = Double(pixelSize.1) - Double(p.y * scale)
        return ((px - ox2D) / scale2D, (py - oy2D) / scale2D)
    }

    /// Zooms the 2D page by `factor` about the pixel (px, py) from the top
    /// left.
    private func zoom2D(_ factor: Double, _ px: Double, _ py: Double) {
        let y = Double(pixelSize.1) - py
        let mx = (px - ox2D) / scale2D, my = (y - oy2D) / scale2D
        scale2D = min(2000, max(0.05, scale2D * factor))
        ox2D = px - mx * scale2D
        oy2D = y - my * scale2D
        requestFrame()
    }

    private func writeSnapshot(_ frame: CGImage, to url: URL) {
        // Three layers: the frame of the window (the title bar and the
        // toolbar), the Metal picture, then the controls of the content (the
        // content is clear where the 3D view shows).
        guard let window, let content = window.contentView else { return }
        let outer = content.superview ?? content
        func image(of v: NSView) -> CGImage? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep.cgImage
        }
        guard let back = image(of: outer), let front = image(of: content) else { return }
        let k = CGFloat(back.width) / outer.bounds.width
        let w = back.width, h = back.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        // A rect of a view in the context, which has its origin at the bottom left.
        func place(_ v: NSView) -> CGRect {
            let r = v.convert(v.bounds, to: nil)
            return CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
        }
        ctx.draw(back, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(frame, in: place(self))
        ctx.draw(front, in: place(content))
        // The title bar and the toolbar again, over the 3D view under them.
        let bar = window.contentLayoutRect.maxY * k
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: bar, width: CGFloat(w), height: CGFloat(h) - bar))
        ctx.draw(back, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        guard let out = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
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

    /// The window took the drag of this press (sliceViewPress).
    private var windowDrag = false

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = convert(event.locationInWindow, from: nil)
        pressAt = lastDrag
        windowDrag = delegate?.sliceViewPress(lastDrag!, event.modifierFlags) ?? false
    }

    override func rightMouseDown(with event: NSEvent) { lastDrag = convert(event.locationInWindow, from: nil) }
    override func otherMouseDown(with event: NSEvent) { lastDrag = convert(event.locationInWindow, from: nil) }

    private func dragDelta(_ event: NSEvent) -> (Float, Float)? {
        let p = convert(event.locationInWindow, from: nil)
        defer { lastDrag = p }
        guard let last = lastDrag else { return nil }
        return (Float(p.x - last.x), Float(p.y - last.y))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { pressAt = nil }
        if windowDrag {
            windowDrag = false
            delegate?.sliceViewRelease(p)
            return
        }
        // A drag is no click.
        guard let at = pressAt, hypot(p.x - at.x, p.y - at.y) < 4 else { return }
        if event.clickCount == 2 {
            // The 2D page fits the part. On the 3D page, the camera turns
            // to face the side under the pointer, or goes back to its start.
            if page == .twoD {
                fit2D()
            } else if let view {
                if delegate?.sliceViewDoubleClick(p) != true { zs_view_reset_smooth(view) }
                startAnimation()
            }
        } else if event.clickCount == 1 {
            delegate?.sliceViewClick(p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if windowDrag {
            delegate?.sliceViewDrag(convert(event.locationInWindow, from: nil), event.modifierFlags)
            return
        }
        guard let view, let (dx, dy) = dragDelta(event) else { return }
        if page == .twoD {
            pan2D(dx, dy)
            return
        }
        zs_view_orbit(view, dx, dy)
        requestFrame()
    }

    private func pan2D(_ dx: Float, _ dy: Float) {
        ox2D += Double(dx) * scale
        oy2D -= Double(dy) * scale
        requestFrame()
    }

    override func rightMouseDragged(with event: NSEvent) { pan(event) }
    override func otherMouseDragged(with event: NSEvent) { pan(event) }

    private func pan(_ event: NSEvent) {
        guard let view, let (dx, dy) = dragDelta(event) else { return }
        if page == .twoD {
            pan2D(dx, dy)
            return
        }
        let s = Float(scale)
        zs_view_pan(view, dx * s, dy * s)
        requestFrame()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let view else { return }
        let (px, py) = pixel(event)
        if event.modifierFlags.contains(.command), event.scrollingDeltaY != 0,
           delegate?.sliceViewTurnWheel(event.scrollingDeltaY) == true {
            return
        }
        if page == .twoD {
            let steps = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : (event.scrollingDeltaY > 0 ? 1 : -1)
            if event.scrollingDeltaY != 0 { zoom2D(pow(1.2, steps), Double(px), Double(py)) }
            return
        }
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
        if page == .twoD {
            zoom2D(1 + event.magnification, Double(px), Double(py))
            return
        }
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
