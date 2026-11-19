//! A range of layers (web/app/rangecard.js, linux/src/ui/range-card.c): a
//! left drag of the Select tool that starts on a line lights the layers
//! from the layer of that line to the layer under the pointer
//! (zs_view_light_layers), and the other beads are ghosts. The release
//! opens the card of the range (RangeCard.swift): settings that can change
//! for some layers, with editors in the scope of those layers (overrides
//! from the top of the first layer to the top of the last).
//!
//! The layer under the pointer needs no pick: the pointer goes to the
//! nearest point of the line on the screen from the bed to the top layer
//! shown, up through the point of the press, so two projections for each
//! move. In a view from above (a short line) it picks the line under the
//! pointer.
//!
//! A press with no move is a click. Esc, a click elsewhere, another tool,
//! or the close button ends the range.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// A drag over layers: the layer of the press, the layer now, the point
/// of the press (mm), and whether the layers lit up yet.
struct RangeDrag {
    var layer: Int
    var cur: Int
    var point: SIMD2<Double>
    var start: CGPoint
    var lit = false
}

extension Workspace {
    private var rangeScale: CGFloat { canvas.window?.backingScaleFactor ?? 2 }

    /// A press of the Select tool on a printed line: the start of a drag
    /// over layers.
    func rangeStart(_ p: CGPoint) -> Bool {
        guard tool == .select, page == .threeD, let v = canvas.view else { return false }
        let px = Float(p.x * rangeScale), py = Float(p.y * rangeScale)
        let path = zs_view_pick(v, px, py)
        var q = [Double](repeating: 0, count: 3)
        guard path != noPath, zs_view_surface_point(v, px, py, 0, &q) != 0 else { return false }
        let l = Int(zs_view_path_layer(v, path))
        rangeDrag = RangeDrag(layer: l, cur: l, point: SIMD2(q[0], q[1]), start: p)
        return true
    }

    /// The layer under the pointer in a drag over layers.
    private func rangeLayer(at p: CGPoint, _ d: RangeDrag) -> Int? {
        guard let v = canvas.view, !layerZ.isEmpty else { return nil }
        let s = rangeScale
        let lo = min(self.lo, layerZ.count - 1), hi = min(self.hi, layerZ.count - 1)
        var ax: Float = 0, ay: Float = 0, bx: Float = 0, by: Float = 0
        let ok = zs_view_pixel_of(v, d.point.x, d.point.y, 0, &ax, &ay) != 0 &&
            zs_view_pixel_of(v, d.point.x, d.point.y, Double(layerZ[hi]), &bx, &by) != 0
        let len2 = ok ? Double((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) : 0
        let px = Double(p.x * s), py = Double(p.y * s)
        if len2 < Double(24 * s * 24 * s) {
            let path = zs_view_pick(v, Float(px), Float(py))
            return path == noPath ? nil : Int(zs_view_path_layer(v, path))
        }
        let t = ((px - Double(ax)) * Double(bx - ax) + (py - Double(ay)) * Double(by - ay)) / len2
        let want = max(0, min(1, t)) * Double(layerZ[hi])
        // The first layer with its top at or over the height.
        var l = lo, h = hi
        while l < h {
            let m = (l + h) / 2
            if Double(layerZ[m]) < want { l = m + 1 } else { h = m }
        }
        return l
    }

    func rangeMoved(_ p: CGPoint) {
        guard var d = rangeDrag, let v = canvas.view else { return }
        guard d.lit || hypot(p.x - d.start.x, p.y - d.start.y) > 4 else { return }
        guard let l = rangeLayer(at: p, d), !(d.lit && l == d.cur) else { return }
        if !d.lit {
            // The drag is for the layers: no line, no support, and no card
            // of an old range.
            clearSelection()
            clearSupportPick()
            closeRangeCard()
        }
        d.lit = true
        d.cur = l
        rangeDrag = d
        zs_view_light_layers(v, min(d.layer, l), max(d.layer, l))
        canvas.requestFrame()
    }

    /// The end of a drag over layers: the card of the range. False for a
    /// press with no drag: it is a click.
    func rangeReleased() -> Bool {
        guard let d = rangeDrag else { return true }
        rangeDrag = nil
        guard d.lit else { return false }
        openRangeCard(min(d.layer, d.cur), max(d.layer, d.cur))
        return true
    }

    /// The top and the bottom of a layer, mm.
    func layerTopBottom(_ layer: Int) -> (top: Double, bottom: Double)? {
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0, tp.layer_count > 0 else { return nil }
        let l = min(layer, tp.layer_count - 1)
        let top = Double(tp.layer_z[l])
        let bottom = l > 0 ? Double(tp.layer_z[l - 1]) : top - (tp.layer_height.map { Double($0[0]) } ?? 0)
        return (top, bottom)
    }

    /// Opens the card of layers lo to hi: its editors set overrides of the
    /// layers with a top from the top of lo to the top of hi, and show the
    /// values of lo.
    func openRangeCard(_ lo: Int, _ hi: Int) {
        guard let a = layerTopBottom(lo), let b = layerTopBottom(hi), let v = canvas.view else { return }
        rangeCard = (lo, hi)
        zs_view_light_layers(v, lo, hi)
        model.scope = .layers(zMin: a.top, zMax: b.top, name: lo == hi ? "Layer \(lo + 1)" : "Layers \(lo + 1)–\(hi + 1)")
        canvas.requestFrame()
    }

    func closeRangeCard() {
        guard rangeCard != nil else { return }
        rangeCard = nil
        if case .layers = model.scope { model.scope = .print }
        if let v = canvas.view { zs_view_light_layers(v, 1, 0) }
        canvas.requestFrame()
    }

    /// The box of the lit layers on the screen: the box of the print from
    /// the bottom of the first layer to the top of the last.
    func rangeRect() -> CGRect? {
        guard let r = rangeCard, let v = canvas.view, let a = layerTopBottom(r.lo), let b = layerTopBottom(r.hi) else { return nil }
        var bounds = [Double](repeating: 0, count: 4)
        guard zs_view_bounds(v, &bounds) == 0 else { return nil }
        var pts: [CGPoint] = []
        for k in 0 ..< 8 {
            if let q = canvas.viewPoint(x: k & 1 != 0 ? bounds[2] : bounds[0], y: k & 2 != 0 ? bounds[3] : bounds[1], z: k & 4 != 0 ? b.top : a.bottom) {
                pts.append(q)
            }
        }
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension Workspace {
    /// ZSLICE_SELECT_TEST (see applyTestHooks).
    func runSelectTest(_ f: [String]) async {
        try? await Task.sleep(for: .seconds(1))
        setTool(.select)
        switch f.first {
        case "parts":
            selectOnlyPart(0)
            duplicatePart()
            plateAction(zs_app_plate_arrange, fits: true)
            selectOnlyPart(0)
            togglePart(1)
            NSLog("zslice select test: %ld parts selected", selectedParts.count)
            try? await Task.sleep(for: .seconds(2))
            // The arrows move both.
            let before = selectedParts.compactMap { part($0)?.x }
            for k in selectedParts { if let q = part(k) { zs_app_part_move(model.core, k, q.x + 5, q.y) } }
            let after = selectedParts.compactMap { part($0)?.x }
            NSLog("zslice select test: x %@ -> %@", before.map { String(format: "%.1f", $0) }.joined(separator: ","), after.map { String(format: "%.1f", $0) }.joined(separator: ","))
        case "range" where f.count >= 3:
            guard let lo = Int(f[1]), let hi = Int(f[2]) else { return }
            openRangeCard(lo, hi)
            NSLog("zslice select test: layers %ld to %ld, card %d, scope %@", lo, hi, rangeCard == nil ? 0 : 1, "\(model.scope)")
            if let v = f.count >= 4 ? f[3] : nil {
                let rc = model.set("project.infill_density", v)
                try? await Task.sleep(for: .seconds(2))
                var buf = [CChar](repeating: 0, count: 64)
                let at = zs_app_setting_get_at(model.core, layerTopBottom(lo)?.top ?? 0, "project.infill_density", &buf, buf.count, nil)
                NSLog("zslice select test: set %@ (%@), at layer %ld: %@ (%d), print: %@", v, rc ?? "ok", lo, String(cString: buf), at, model.setting("project.infill_density"))
            }
        case "support" where f.count >= 3:
            if f.count >= 4 {
                model.set("project.support_style", f[3])
                model.set("project.support", "everywhere")
                try? await Task.sleep(for: .seconds(4))
            }
            guard let v = canvas.view else { return }
            let s = canvas.window?.backingScaleFactor ?? 2
            var x = Double(f[1]) ?? 0, y = Double(f[2]) ?? 0
            if f[1] == "auto" {
                // The first support line from the bottom of the view up.
                let w = canvas.bounds.width, h = canvas.bounds.height
                var found = false
                var yy = h - 1
                while yy > 0, !found {
                    var xx: CGFloat = 0
                    while xx < w, !found {
                        var seg = 0
                        let path = zs_view_pick_segment(v, Float(xx * s), Float(yy * s), &seg)
                        if path != noPath, zs_view_path_feature(v, path) == Int32(ZS_FEATURE_SUPPORT.rawValue) {
                            found = true
                            x = xx
                            y = yy
                        }
                        xx += 3
                    }
                    yy -= 3
                }
            }
            let ok = selectSupport(at: CGPoint(x: x, y: y))
            NSLog("zslice select test: the support line at %.0f, %.0f: picked %d, tree %d, nodes %ld, overhang %ld points",
                  x, y, ok ? 1 : 0, supportPick?.tree == true ? 1 : 0, supportPick?.only?.nodes.count ?? 0, supportPick?.overhang?.n ?? 0)
            if ok, ProcessInfo.processInfo.environment["ZSLICE_SELECT_DEL"] != nil {
                let areas = zs_app_support_area_count(model.core)
                let used = removePickedSupport()
                NSLog("zslice select test: Delete %d, support areas %ld -> %ld, picked %d", used ? 1 : 0, areas, zs_app_support_area_count(model.core), supportPick == nil ? 0 : 1)
            }
        default:
            NSLog("zslice select test: unknown %@", f.joined(separator: " "))
        }
    }
}
