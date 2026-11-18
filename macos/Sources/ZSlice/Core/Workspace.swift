//! Workspace: the model of one window. It holds the plate (a SliceModel),
//! the 3D view, the layer range, and the replay.
//!
//! The layer range is two numbers: the top layer that shows (hi) and the
//! lowest layer that shows (lo). The view shows the layers lo to hi. After a
//! new slice, the top knob stays where it was if it can; a top knob at the
//! top layer stays at the top (web/app/layers.js, linux/src/ui/layer-range.c).
//!
//! The replay moves the nozzle along the print in time (zs_view_set_time).
//! The scrub bar shows the time in the top layer: layer l prints from the
//! end time of the last path of layer l - 1 to the end time of its own last
//! path (zs_toolpaths.path_end_time). The replay runs on the frames of the
//! display link of the view, and the layer slider follows it.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Observation

@MainActor
@Observable
final class Workspace {
    let model = SliceModel()
    @ObservationIgnored let canvas = MetalSliceView(frame: .zero)

    // The layers of the last slice, and the range that shows.
    private(set) var layerCount = 0
    private(set) var lo = 0
    private(set) var hi = 0
    @ObservationIgnored private(set) var layerEnd: [Double] = []
    @ObservationIgnored private(set) var layerZ: [Float] = []
    @ObservationIgnored private(set) var layerSlowed: [Bool] = []

    // The replay: the print time that the view shows (nil: the whole layer
    // range), and its speed.
    private(set) var time: Double?
    private(set) var playing = false
    var speed = 10.0

    static let speeds: [Double] = [1, 2, 5, 10, 25, 50, 100]

    // The selected line and its card (Selection.swift).
    var selection: Selection?
    var lineInfo: LineInfo?
    @ObservationIgnored var refindKey: RefindKey?
    var cardOpen = false
    /// Where the click was (points in the view), and where the user moved
    /// the card to; the card keeps that place until it closes.
    var cardAt = CGPoint(x: 120, y: 120)
    var cardMoved: CGPoint?
    /// "Fade the others": the app keeps the choice.
    var isolate = UserDefaults.standard.bool(forKey: "isolate") {
        didSet { UserDefaults.standard.set(isolate, forKey: "isolate") }
    }

    /// The page of the view: 3D, or one layer from the top. The app keeps
    /// the choice for the next window.
    var page: MetalSliceView.Page = MetalSliceView.Page(rawValue: UserDefaults.standard.string(forKey: "view") ?? "") ?? .threeD {
        didSet {
            canvas.page = page
            UserDefaults.standard.set(page.rawValue, forKey: "view")
        }
    }

    init() {
        canvas.delegate = self
        if ProcessInfo.processInfo.environment["ZSLICE_PANEL"] != nil { showSettings = true }
        if let m = ProcessInfo.processInfo.environment["ZSLICE_MODE"].flatMap(Int.init) { colorMode = m }
        if let p = ProcessInfo.processInfo.environment["ZSLICE_VIEW"].flatMap(MetalSliceView.Page.init) { page = p }
        canvas.page = page
        model.onSliced = { [weak self] in self?.sliced() }
    }

    // MARK: - the slice

    private func sliced() {
        stopReplay()
        if let v = canvas.view { zs_view_set_mode(v, Int32(colorMode)) }
        canvas.load(model.core)
        readLegend()
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0 else { return }
        let n = tp.layer_count
        layerZ = Array(UnsafeBufferPointer(start: tp.layer_z, count: tp.layer_z == nil ? 0 : n))
        layerSlowed = tp.layer_slowed == nil ? Array(repeating: false, count: n) : (0 ..< n).map { tp.layer_slowed[$0] != 0 }
        layerEnd = (0 ..< n).map { l in
            let end = Int(tp.layer_ends[l])
            return end > 0 && tp.path_end_time != nil ? Double(tp.path_end_time[end - 1]) : 0
        }
        let wasTop = hi >= layerCount - 1
        layerCount = n
        if wasTop || hi >= n { hi = max(0, n - 1) }
        lo = min(lo, hi)
        applyRange()
        applyFocus()
        refindSelection()
        // After the first frames of the new slice: a pick needs the camera.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.applyTestHooks() }
    }

    /// For development and screenshots, once after the first slice:
    /// ZSLICE_LAYERS=lo,hi sets the layer range (layer numbers from 1), and
    /// ZSLICE_TIME=t shows the replay at t seconds (as in the GTK app).
    @ObservationIgnored private var hooked = false

    private func applyTestHooks() {
        guard !hooked else { return }
        hooked = true
        let env = ProcessInfo.processInfo.environment
        if let r = env["ZSLICE_LAYERS"]?.split(separator: ",").compactMap({ Int($0) }), r.count == 2 {
            setRange(lo: r[0] - 1, hi: r[1] - 1)
        }
        // ZSLICE_SET="name=value;name=value" makes each change a step, and
        // ZSLICE_UNDO=n then undoes n steps through the UndoManager.
        if let sets = env["ZSLICE_SET"] {
            model.history.commit()
            for pair in sets.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { model.set(kv[0], kv[1]) }
                model.history.commit()
            }
            for _ in 0 ..< (env["ZSLICE_UNDO"].flatMap(Int.init) ?? 0) { model.history.undoManager.undo() }
        }
        // ZSLICE_PICK=x,y picks the line at that point of the view (points),
        // as a click does (as in the GTK app).
        if let xy = env["ZSLICE_PICK"]?.split(separator: ",").compactMap({ Double($0) }), xy.count == 2 {
            pick(at: CGPoint(x: xy[0], y: xy[1]))
        }
        // ZSLICE_DOUBLE_CLICK=x,y: a double click there (as in the GTK app).
        if let xy = env["ZSLICE_DOUBLE_CLICK"]?.split(separator: ",").compactMap({ Double($0) }), xy.count == 2, let v = canvas.view {
            if !lookAtSide(CGPoint(x: xy[0], y: xy[1])) { zs_view_reset_smooth(v) }
            canvas.startAnimation()
        }
        if let t = env["ZSLICE_TIME"].flatMap(Double.init), let v = canvas.view {
            time = t
            zs_view_set_time(v, t)
            hi = Int(zs_view_layer_at_time(v, t))
            lo = min(lo, hi)
            canvas.layer2D = hi
            canvas.requestFrame()
        }
    }

    // MARK: - the layer range

    /// Sets the layers that show: lo to hi.
    func setRange(lo newLo: Int, hi newHi: Int) {
        let top = max(0, layerCount - 1)
        hi = min(top, max(0, newHi))
        lo = min(hi, max(0, newLo))
        stopReplay()
        time = nil
        applyRange()
    }

    /// Moves the top knob by `step` layers (the bottom knob follows down).
    func moveTop(_ step: Int) { setRange(lo: min(lo, hi + step), hi: hi + step) }

    /// Moves the bottom knob by `step` layers (the top knob follows up).
    func moveBottom(_ step: Int) { setRange(lo: lo + step, hi: max(hi, lo + step)) }

    private func applyRange() {
        guard let v = canvas.view else { return }
        zs_view_set_layer_range(v, lo, hi)
        canvas.layer2D = hi
        canvas.dim2D = focusMask != 0 && focusFirst && hi > 0
        canvas.requestFrame()
    }

    func z(of layer: Int) -> Float { layer < layerZ.count ? layerZ[layer] : 0 }
    func isSlowed(_ layer: Int) -> Bool { layer < layerSlowed.count && layerSlowed[layer] }

    // MARK: - the replay

    /// The start and end time of a layer, in seconds from the start.
    func layerTimes(_ l: Int) -> (Double, Double) {
        guard l < layerEnd.count else { return (0, 0) }
        return (l > 0 ? layerEnd[l - 1] : 0, layerEnd[l])
    }

    /// Where the scrub bar is in the top layer: 0 at its start, 1 at its end.
    var scrubFraction: Double {
        let (t0, t1) = layerTimes(hi)
        guard let time, t1 > t0 else { return 1 }
        return min(1, max(0, (time - t0) / (t1 - t0)))
    }

    /// A drag of the scrub bar: the nozzle at fraction f of the top layer.
    func scrub(to f: Double) {
        stopReplay()
        guard let v = canvas.view else { return }
        page = .threeD
        let (t0, t1) = layerTimes(hi)
        if f >= 1 {
            time = nil
            zs_view_set_layer_range(v, lo, hi)
        } else {
            time = t0 + f * (t1 - t0)
            zs_view_set_time(v, time!)
        }
        canvas.requestFrame()
    }

    func togglePlay() { playing ? stopReplay() : startReplay() }

    func startReplay() {
        guard let v = canvas.view, layerCount > 0 else { return }
        page = .threeD
        let d = zs_view_duration(v)
        var t = time ?? 0
        if t <= 0 || t >= d { t = 0 }
        // After a move of the slider: from the start of the top layer.
        if t <= 0 && hi + 1 < layerCount { t = layerTimes(hi).0 }
        time = t
        playing = true
        canvas.startTicking()
    }

    func stopReplay() {
        playing = false
    }

    private func stepReplay(_ dt: Double) -> Bool {
        guard playing, let v = canvas.view, var t = time else { return false }
        let d = zs_view_duration(v)
        t += dt * speed
        if t >= d {
            playing = false
            time = nil
            hi = max(0, layerCount - 1)
            applyRange()
            return false
        }
        time = t
        zs_view_set_time(v, t)
        let layer = Int(zs_view_layer_at_time(v, t))
        hi = layer
        lo = min(lo, layer)
        canvas.layer2D = layer
        return true
    }

    // MARK: - the settings drawer

    /// The drawer shows. The app keeps the choice for the next window.
    var showSettings = UserDefaults.standard.bool(forKey: "panel") {
        didSet {
            UserDefaults.standard.set(showSettings, forKey: "panel")
            if !showSettings { focus(0, firstLayer: false) }
        }
    }

    enum DrawerPage: String { case settings, history }

    /// The pages of the settings browser that show, from its first page.
    var settingsPath: [SettingsRoute] = []

    /// Opens the drawer on all settings of the selected line.
    func showLineSettings() {
        showSettings = true
        drawerPage = .settings
        settingsPath = [.line]
    }

    /// The page of the drawer.
    var drawerPage = DrawerPage(rawValue: ProcessInfo.processInfo.environment["ZSLICE_PAGE"] ?? "") ?? .settings

    // MARK: - the colors and the line types

    /// The colors of the view (enum zs_view_mode): the filament, one color
    /// for each line type, or a ramp of a value. The app keeps the choice.
    static let colorModes = ["Filament", "Line Type", "Speed", "Flow", "Layer Time", "Line Width"]
    static let legendUnits = ["", "", "mm/s", "mm³/s", "s", "mm"]

    var colorMode = UserDefaults.standard.integer(forKey: "mode") {
        didSet {
            UserDefaults.standard.set(colorMode, forKey: "mode")
            applyMode()
        }
    }

    /// The range of the ramp of a value mode, after a load.
    private(set) var legend: (lo: Double, hi: Double)?

    /// The line types that show (a bit for each feature and mark; 0: all
    /// in their colors). The others fade to ghosts.
    var shownTypes: UInt32 = 0 {
        didSet { applyFocus() }
    }

    func toggleType(_ f: Int) {
        let bit = UInt32(1) << UInt32(f)
        var m = shownTypes == 0 ? Feature.all : shownTypes
        m ^= bit
        shownTypes = m == Feature.all || m == 0 ? 0 : m
    }

    /// Sets the color mode of the view, and loads the slice again (the
    /// colors come with the data).
    private func applyMode() {
        guard let v = canvas.view else { return }
        zs_view_set_mode(v, Int32(colorMode))
        if model.state == .done {
            canvas.load(model.core)
            applyRange()
            applyFocus()
            showSelection()
        }
        readLegend()
    }

    private func readLegend() {
        var lo = 0.0, hi = 0.0
        if let v = canvas.view, colorMode >= 2, zs_view_legend(v, &lo, &hi) != 0 { legend = (lo, hi) } else { legend = nil }
    }

    /// The lines that the drawer points at: a bit for each feature and mark
    /// (0: all lines, in their colors). firstLayer: only the lines of the
    /// first layer.
    @ObservationIgnored private var focusMask: UInt32 = 0
    @ObservationIgnored private var focusFirst = false

    func focus(_ mask: UInt32, firstLayer: Bool) {
        // A hidden drawer shows the whole print.
        let m = showSettings ? mask : 0
        focusMask = m
        focusFirst = firstLayer
        applyFocus()
    }

    private func applyFocus() {
        guard let v = canvas.view else { return }
        let mask = focusMask != 0 ? focusMask : shownTypes
        let zmax = focusMask != 0 && focusFirst && !layerZ.isEmpty ? Double(layerZ[0]) : -1
        zs_view_focus(v, mask, zmax)
        // In 2D, a focus on the first layer while the view shows another
        // layer: all lines are faint (web/app/view2d.js, dim).
        canvas.focus2D = mask
        canvas.dim2D = focusMask != 0 && focusFirst && hi > 0
        canvas.requestFrame()
    }

    /// Fits the part in the view: the 2D page fits the layer, and the 3D
    /// page moves the camera back to the start view.
    func fit() {
        if page == .twoD {
            canvas.fit2D()
        } else if let v = canvas.view {
            zs_view_reset_smooth(v)
            canvas.startAnimation()
        }
    }

    // MARK: - the G-code

    /// Exports the G-code of the last slice with a save panel.
    func exportGcode(from window: NSWindow?) {
        guard let data = model.gcode() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gcode]
        let base = (model.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "plate" : base) + ".gcode"
        let write = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }
}

extension Workspace: SliceViewDelegate {
    func sliceViewClick(_ p: CGPoint) { pick(at: p) }
    func sliceViewDoubleClick(_ p: CGPoint) -> Bool { lookAtSide(p) }

    func sliceViewTick(_ dt: Double) -> Bool { stepReplay(dt) }

    func sliceViewAppearanceChanged() {
        if model.state == .done { canvas.load(model.core); applyRange() }
    }

    /// The keys of the preview (docs/user/getting-started.md, "Keys in the
    /// preview"), for the case with no selected line.
    func sliceViewKey(_ event: NSEvent) -> Bool {
        if selectionKey(event) { return true }
        let shift = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .upArrow?: shift ? moveBottom(1) : moveTop(1)
        case .downArrow?: shift ? moveBottom(-1) : moveTop(-1)
        case .pageUp?: moveTop(10)
        case .pageDown?: moveTop(-10)
        case .leftArrow?: scrubStep(-0.02)
        case .rightArrow?: scrubStep(0.02)
        default:
            switch event.charactersIgnoringModifiers {
            case "k": shift ? moveBottom(1) : moveTop(1)
            case "j": shift ? moveBottom(-1) : moveTop(-1)
            case "h": scrubStep(-0.02)
            case "l": scrubStep(0.02)
            case "C" where shift: setRange(lo: 0, hi: layerCount - 1)
            case "n" where !shift: showSettings.toggle()
            default: return false
            }
        }
        return true
    }

    private func scrubStep(_ df: Double) { scrub(to: min(1, max(0, scrubFraction + df))) }
}
