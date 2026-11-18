//! The preview of the space bar: the print in 3D, with a slider for the
//! layers.
//!
//! It is the 3D view of the app (MetalSliceView, Render/), in a Quick Look
//! preview extension. A drag turns the print, a right drag pans it, and a
//! scroll or a pinch zooms. The slider shows the layers up to one layer
//! (zs_view_set_layer).
//!
//! - A G-code file of any slicer: its beads, one color for each feature
//!   (zs_gcode_open, zs_view_load_gcode).
//! - An STL or 3MF model: zslice slices it with its default settings
//!   (zs_app_load_stl, zs_app_slice), and the view shows the toolpaths.
//!   The bar shows the progress until then.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import QuickLookUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let canvas = MetalSliceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let layerLabel = NSTextField(labelWithString: "")
    private let factsLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var gcode: OpaquePointer?
    private var app: OpaquePointer?
    private var layers = 0
    /// The events of the slice reach the controller through a weak box.
    private var box: Unmanaged<EventBox>?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        slider.target = self
        slider.action = #selector(layerChanged)
        slider.isContinuous = true
        slider.isEnabled = false
        layerLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        layerLabel.alignment = .right
        factsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.isIndeterminate = false
        progress.isHidden = true
        progress.controlSize = .small

        let row = NSStackView(views: [slider, layerLabel])
        row.spacing = 10
        layerLabel.setContentHuggingPriority(.required, for: .horizontal)
        layerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let bar = NSStackView(views: [row, progress, factsLabel])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        row.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -28).isActive = true
        progress.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true

        let root = NSStackView(views: [canvas, bar])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .width
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 680)
        view = root
        preferredContentSize = NSSize(width: 800, height: 680)
    }

    isolated deinit {
        // zs_app_free stops the slice first, so no event comes after it.
        if let app { zs_app_free(app) }
        if let gcode { zs_gcode_free(gcode) }
        box?.release()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        _ = view
        if Render.isGcode(url) {
            var g: OpaquePointer?
            let rc = zs_gcode_open(url.path, &g)
            guard rc == 0, let g else { throw CocoaError(.fileReadCorruptFile) }
            gcode = g
            canvas.load(gcode: g)
            var info = zs_gcode_info()
            if zs_gcode_get_info(g, &info) == 0 { layers = info.layers }
            factsLabel.stringValue = Render.facts(gcode: g).joined(separator: "  ·  ")
            showLayers()
        } else {
            try await sliceModel(url)
        }
    }

    // MARK: - a model: slice it

    private func sliceModel(_ url: URL) async throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var a: OpaquePointer?
        let b = Unmanaged.passRetained(EventBox(self))
        box = b
        guard zs_app_new({ user, event, value, _ in
            guard let user else { return }
            let box = Unmanaged<EventBox>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { box.vc?.event(event, value) } }
        }, b.toOpaque(), &a) == 0, let a else { throw CocoaError(.fileReadUnknown) }
        app = a
        let rc = data.withUnsafeBytes { zs_app_load_stl(a, url.lastPathComponent, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard rc == 0 else { throw CocoaError(.fileReadCorruptFile) }
        factsLabel.stringValue = (Render.facts(app: a) + ["Slicing with the default settings of zslice…"]).joined(separator: "  ·  ")
        progress.isHidden = false
        guard zs_app_slice(a) == 0 else { throw CocoaError(.fileReadUnknown) }
        // Quick Look shows the preview now; the slice goes on.
    }

    private func event(_ event: Int32, _ value: Double) {
        guard let app else { return }
        switch event {
        case Int32(ZS_EVENT_PROGRESS.rawValue):
            progress.doubleValue = value * 100
        case Int32(ZS_EVENT_SLICED.rawValue):
            progress.isHidden = true
            canvas.load(app)
            layers = zs_app_layer_count(app)
            factsLabel.stringValue = (Render.facts(app: app) + sliceFacts(app) + ["the default settings of zslice"]).joined(separator: "  ·  ")
            showLayers()
        case Int32(ZS_EVENT_FAILED.rawValue):
            progress.isHidden = true
            factsLabel.stringValue = (Render.facts(app: app) + ["zslice could not slice it"]).joined(separator: "  ·  ")
        default:
            break
        }
    }

    private func sliceFacts(_ app: OpaquePointer) -> [String] {
        var st = zs_stats()
        guard zs_app_stats(app, &st) == 0 else { return [] }
        return st.print_time_s > 0 ? ["Print time \(Render.duration(st.print_time_s))"] : []
    }

    // MARK: - the layers

    private func showLayers() {
        guard layers > 0 else { return }
        slider.isEnabled = true
        slider.minValue = 1
        slider.maxValue = Double(layers)
        slider.numberOfTickMarks = 0
        slider.doubleValue = Double(layers)
        layerChanged()
    }

    @objc private func layerChanged() {
        guard let v = canvas.view, layers > 0 else { return }
        let n = max(1, min(layers, Int(slider.doubleValue.rounded())))
        zs_view_set_layer(v, n - 1)
        canvas.requestFrame()
        var z = -1.0
        if let gcode {
            var l = zs_gcode_layer()
            if zs_gcode_get_layer(gcode, n - 1, &l) == 0 { z = l.z }
        }
        layerLabel.stringValue = z >= 0 ? String(format: "Layer %d of %d · %.2f mm", n, layers, z) : "Layer \(n) of \(layers)"
    }
}

/// A weak link from the worker thread of the core to the controller.
private final class EventBox: @unchecked Sendable {
    weak var vc: PreviewViewController?
    init(_ vc: PreviewViewController) { self.vc = vc }
}
