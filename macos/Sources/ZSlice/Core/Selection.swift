//! The selected line of a window: a path of the slice and one of its
//! segments, and the facts of the line card (zs_app_inspect,
//! zs_app_inspect_picks, zs_app_measure).
//!
//! A click on a line selects it (zs_view_pick_segment in 3D, and
//! zs_view_pick_layer in mm on the 2D page). The view shows the path in
//! yellow and the segment in orange. "Fade the others" shows the other
//! lines as ghosts (zs_view_isolate).
//!
//! A new slice can change the index of each path. The window keeps the
//! layer, the feature, and the middle point of the selected line, and after
//! the slice zs_app_pick_feature finds the nearest line of the same feature
//! there, as the web app and the GTK app do.
//!
//! The keys of a selected line (docs/user/getting-started.md, "Keys in the
//! preview"): Left and Right step along the print (Shift: a whole line), Up
//! and Down go to the nearest line on the layer above or below, C shows the
//! layers up to the line, and Esc clears the selection.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// The facts of a selected line for its card.
struct LineInfo {
    var path: Int
    var title: String
    var layer: Int
    var feature: Int32
    var plannedSpeed: Double
    var speed: Double
    var flow: Double
    var slowReason: Int32
    var slowText: String
    var measure: zs_measure?
    /// The settings that matter most for the line, with the reason of each.
    var picks: [(name: String, why: String)]
    /// All settings that change the line, by section ("# Speed" lines start
    /// a section).
    var settings: [String]
    /// Why the planned speed, the real speed, and the flow are what they
    /// are, in words; a setting is a mark {{name}}.
    var whyPlanned = "", whyReal = "", whyFlow = ""
    /// The z of the line and its height and width, mm.
    var z = 0.0, height = 0.0, lineWidth = 0.0
    /// The part fan (0 to 1), the time of the layer (s), and the flow limit
    /// (mm³/s; 0: none), with a flag when the flow limit sets the speed.
    var fan = 0.0, layerTime = 0.0, maxFlow = 0.0
    var flowLimited = false
    /// For a support line: the layer and the feature of the part line that
    /// it holds up.
    var holds: (layer: Int, feature: Int)?
    /// The warnings of the check at the line (a bridge, an overhang).
    var issues: [Issue] = []
}

/// (size_t)-1 of the C API: no path.
let noPath = -1

extension Workspace {
    /// The number of settings on the line card.
    static let cardSettings = 5

    // MARK: - pick and select

    /// A click at a point of the view (in points from its top left). card:
    /// open the card of the line (a right click for the menu does not).
    func pick(at p: CGPoint, card: Bool = true) {
        guard let v = canvas.view, model.state == .done || layerCount > 0 else { return }
        var seg = 0
        let path: Int
        if page == .twoD {
            guard let mm = canvas.millimeters(of: p) else { return }
            path = zs_view_pick_layer(v, hi, mm.x, mm.y, &seg)
        } else {
            let s = canvas.window?.backingScaleFactor ?? 2
            path = zs_view_pick_segment(v, Float(p.x * s), Float(p.y * s), &seg)
        }
        if path == noPath {
            clearSelection()
        } else {
            cardAt = p
            // With the line in the pane, the pane shows the new line, and
            // no card opens.
            select(path: path, seg: seg, openCard: card && !lineInPane)
        }
    }

    func select(path: Int, seg: Int, openCard: Bool) {
        let before = selection
        selection = Selection(path: path, seg: seg)
        selection?.key = zs_app_path_key(model.core, path)
        // The same line again while a new slice runs (a right click on it):
        // the core has no slice to read, so the facts of before stay.
        if selection?.key == 0, let before, before.path == path, before.key != 0 {
            selection = before
            selection?.seg = seg
            if openCard { cardOpen = true }
            showSelection()
            return
        }
        selection?.layer = Int(zs_app_path_layer(model.core, path))
        if let m = markPlace() {
            selection?.x = m.x
            selection?.y = m.y
            selection?.z = m.z
        }
        if openCard { cardOpen = true }
        showSelection()
        inspect()
    }

    func clearSelection() {
        selection = nil
        lineInfo = nil
        refindKey = nil
        cardOpen = false
        cardMoved = nil
        showSelection()
    }

    /// The highlight of the view (3D and 2D).
    func showSelection() {
        guard let v = canvas.view else { return }
        if let s = selection {
            zs_view_highlight(v, s.path)
            zs_view_highlight_segment(v, s.path, s.seg)
            zs_view_isolate(v, isolate ? 1 : 0)
            var a: UInt32 = 0, b: UInt32 = 0
            canvas.selection2D = zs_view_path_beads(v, s.path, &a, &b) == 0 ? (a, b, s.seg) : nil
        } else {
            zs_view_highlight(v, noPath)
            zs_view_isolate(v, 0)
            canvas.selection2D = nil
        }
        canvas.requestFrame()
    }

    func toggleIsolate() {
        isolate.toggle()
        showSelection()
    }

    /// Reads the facts of the selected line for its card.
    private func inspect() {
        guard let s = selection else { return }
        var info = zs_inspect()
        guard zs_app_inspect(model.core, s.path, &info) == 0 else {
            lineInfo = nil
            return
        }
        var picks = [zs_pick](repeating: zs_pick(), count: Self.cardSettings)
        var n = 0
        _ = zs_app_inspect_picks(model.core, s.path, &picks, picks.count, &n)
        var m = zs_measure()
        let measured = zs_app_measure(model.core, s.path, s.seg, &m) == 0
        lineInfo = LineInfo(
            path: s.path, title: coreText(info.title), layer: info.layer, feature: info.feature,
            plannedSpeed: info.planned_speed, speed: info.speed, flow: info.flow,
            slowReason: info.slow_reason, slowText: coreText(info.slow_text),
            measure: measured ? m : nil,
            picks: picks.prefix(n).map { (coreText($0.name), coreText($0.why)) }.filter { SettingInfo.byName[$0.0] != nil },
            settings: coreText(info.settings).split(separator: "\n").map(String.init),
            whyPlanned: coreText(info.why_planned), whyReal: coreText(info.why_real), whyFlow: coreText(info.why_flow),
            z: info.z, height: info.height, lineWidth: info.line_width,
            fan: info.fan, layerTime: info.layer_time, maxFlow: info.max_flow, flowLimited: info.flow_limited != 0,
            holds: info.holds_layer == ZS_NO_PATH ? nil : (Int(info.holds_layer), Int(info.holds_feature)),
            issues: lineIssues(ofPath: s.path, layer: Int(info.layer)))
        refindKey = middle(of: s.path).map { RefindKey(layer: info.layer, feature: info.feature, x: $0.x, y: $0.y) }
    }

    /// The warnings of the check at a line, the worst first: its own, and
    /// the ones within `near` mm of it on its layer. Only a check that has
    /// run (zs_app_checks_ready): the check of a whole slice can take a
    /// second, too long for a click. readIssues adds them later.
    func lineIssues(ofPath path: Int, layer: Int, near: Double = 3) -> [Issue] {
        guard zs_app_checks_ready(model.core) != 0, !issues.isEmpty else { return [] }
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0, path < tp.path_count, let ends = tp.path_ends, let pts = tp.points else { return [] }
        let a = path > 0 ? Int(ends[path - 1]) : 0, b = Int(ends[path])
        return issues.filter { i in
            guard i.layer == layer else { return false }
            if i.path == path { return true }
            return (a ..< b).contains { k in hypot(Double(pts[2 * k]) - i.x, Double(pts[2 * k + 1]) - i.y) <= near }
        }
    }

    /// The middle point of a path (mm), from the toolpaths of the slice.
    private func middle(of path: Int) -> (x: Double, y: Double)? {
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0, path < tp.path_count, let ends = tp.path_ends, let pts = tp.points else { return nil }
        let start = path > 0 ? Int(ends[path - 1]) : 0, end = Int(ends[path])
        guard end > start else { return nil }
        let k = (start + end) / 2
        return (Double(pts[2 * k]), Double(pts[2 * k + 1]))
    }

    /// After a new slice: the same line, or none.
    func refindSelection() {
        guard selection != nil, let key = refindKey else {
            if selection != nil { clearSelection() }
            return
        }
        let path = zs_app_pick_feature(model.core, key.layer, key.feature, key.x, key.y)
        guard path != noPath, let v = canvas.view else {
            clearSelection()
            return
        }
        let segs = zs_view_path_segments(v, path)
        select(path: path, seg: min(selection?.seg ?? 0, max(0, segs - 1)), openCard: false)
    }

    /// A double click on the 3D page: the camera turns to face the side of
    /// the print under the point (zs_view_look_at_side), at a distance for
    /// the size of the part there. The first click of the double click
    /// picked a line: that selection goes.
    func lookAtSide(_ p: CGPoint) -> Bool {
        guard let v = canvas.view, model.state == .done else { return false }
        let s = canvas.window?.backingScaleFactor ?? 2
        let px = Float(p.x * s), py = Float(p.y * s)
        guard zs_view_look_at_side(v, px, py, Float(partSize(at: px, py))) != 0 else { return false }
        clearSelection()
        return true
    }

    /// The largest size of the part under a pixel (the part of the path
    /// there, or the part on the bed there), or 0 for the whole print.
    private func partSize(at px: Float, _ py: Float) -> Double {
        guard let v = canvas.view else { return 0 }
        var part = -1
        var seg = 0
        let path = zs_view_pick_segment(v, px, py, &seg)
        if path != noPath { part = zs_app_part_of_path(model.core, path) }
        var x = 0.0, y = 0.0
        if part < 0, zs_view_bed_point(v, px, py, &x, &y) != 0 { part = zs_app_part_at(model.core, x, y) }
        var info = zs_part()
        guard part >= 0, zs_app_part_get(model.core, part, &info) == 0 else { return 0 }
        return max(info.size_x, info.size_y, info.size_z)
    }

    // MARK: - the keys of a selected line

    /// The keys of a selected line. Returns false for a key it does not use.
    func selectionKey(_ event: NSEvent) -> Bool {
        guard let s = selection, let v = canvas.view else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let key = event.charactersIgnoringModifiers ?? ""
        func step(_ dir: Int32) {
            var path = s.path, seg = s.seg
            if zs_view_step(v, &path, &seg, dir, shift ? 1 : 0) != 0 { follow(path, max(seg, 0)) }
        }
        func layer(_ dl: Int) {
            let l = zs_view_path_layer(v, s.path) + dl
            guard l >= 0 && l < layerCount else { return }
            let path = zs_view_nearest_on_layer(v, s.path, l)
            if path != noPath { follow(path, 0) }
        }
        switch event.specialKey {
        case .leftArrow?: step(-1)
        case .rightArrow?: step(1)
        case .upArrow? where !shift: layer(1)
        case .downArrow? where !shift: layer(-1)
        default:
            switch key {
            case "k": layer(1)
            case "j": layer(-1)
            case "c": setRange(lo: lo, hi: zs_view_path_layer(v, s.path))
            // Esc: the card first (closeCard keeps a line of the pane), then the selection.
            case "\u{1b}": if cardOpen { closeCard() } else { clearSelection() }
            default: return false
            }
        }
        return true
    }

    /// Selects a line from a key, and the layer slider follows it.
    private func follow(_ path: Int, _ seg: Int) {
        guard let v = canvas.view else { return }
        let l = zs_view_path_layer(v, path)
        if l > hi || l < lo { setRange(lo: min(lo, l), hi: max(l, lo)) }
        select(path: path, seg: seg, openCard: false)
    }
}

extension Workspace {
    /// The screen box of a whole path (points from the top left), for a
    /// card that keeps out of it (zs_view_path_rect).
    func lineRect(_ path: Int) -> CGRect? {
        guard let v = canvas.view, page == .threeD else { return nil }
        var r = [Float](repeating: 0, count: 4)
        let rc = zs_view_path_rect(v, path, &r)
        if ProcessInfo.processInfo.environment["ZSLICE_CARD_LOG"] != nil { NSLog("zslice card: path %ld rect rc %d %.0f %.0f %.0f %.0f", path, rc, r[0], r[1], r[2], r[3]) }
        guard rc != 0 else { return nil }
        let s = CGFloat(canvas.window?.backingScaleFactor ?? 2)
        return CGRect(x: CGFloat(r[0]) / s, y: CGFloat(r[1]) / s, width: CGFloat(r[2] - r[0]) / s, height: CGFloat(r[3] - r[1]) / s)
    }

    /// The screen box of a part with its turn rings (radius 0.62 times its
    /// largest size, and 4 mm), for its card.
    func partRect(_ i: Int) -> CGRect? {
        var p = zs_part()
        guard page == .threeD, zs_app_part_get(model.core, i, &p) == 0 else { return nil }
        let r = 0.62 * max(p.size_x, p.size_y, p.size_z) + 4
        let cz = p.size_z / 2
        var pts: [CGPoint] = []
        for dx in [-1.0, 1.0] { for dy in [-1.0, 1.0] { for dz in [-1.0, 1.0] {
            if let q = canvas.viewPoint(x: p.x + dx * r, y: p.y + dy * r, z: max(0, cz + dz * r)) { pts.append(q) }
        } } }
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

struct Selection: Equatable {
    var path: Int
    var seg: Int
    /// Read when the line is selected, from its slice, so an edit works
    /// while a new slice runs: the key of the line (zs_app_path_key, 0: no
    /// slice), its layer, and the middle of the segment for a drop.
    var key: UInt64 = 0
    var layer = -1
    var x = 0.0, y = 0.0, z = 0.0
}

struct RefindKey {
    var layer: Int
    var feature: Int32
    var x: Double
    var y: Double
}
