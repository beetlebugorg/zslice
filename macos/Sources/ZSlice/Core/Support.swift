//! The Support tool (S, or U): the support editor of the 3D view
//! (web/app/support.js).
//!
//! - Draw: click points on the part. A point snaps to the end of the
//!   nearest line, as the measure tape does (Shift: no snap). A click on
//!   the first point, or Return, closes the area. Delete removes the last
//!   point; Esc stops the area.
//! - The area: support grows under all of the part in it that faces down
//!   (Support grid or Support tree), also where the support angle gives
//!   none; or no support there (Block). The card of the tool changes the
//!   kind of the area, or deletes it.
//! - Edit: a click on an outline selects its area, and a drag of one of its
//!   points moves the point. The outline follows at once; the slice waits
//!   for the end of the drag (the hold of the plate set, as in the Turn
//!   tool).
//!
//! The core keeps the areas (zs_app_support_area_*), slices with them, and
//! keeps them in the 3MF and the history. The core view draws them
//! (zs_view_support_add). While the tool is on, a pick skips the support
//! lines (zs_view_pick_skip_support), so a click finds the part under them,
//! and the support lines are faint ("See through the support").
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// An area of support: its kind (enum zs_mark_kind), its z range, and its
/// points (mm).
struct SupportArea: Equatable {
    var kind: Int32
    var zLo: Double, zHi: Double
    var points: [SIMD3<Double>]
}

/// A drag of a point of an area.
struct SupportDrag {
    var area: Int
    var point: Int
    var sent = Date.distantPast
    var moved = false
}

extension Workspace {
    /// The kinds that the card offers.
    static let supportKinds: [(kind: Int32, name: String)] = [
        (Int32(ZS_MARK_GRID.rawValue), "Grid"), (Int32(ZS_MARK_TREE.rawValue), "Tree"), (Int32(ZS_MARK_BLOCK.rawValue), "Block"),
    ]

    /// The features of the support lines, faint while the tool is on.
    static let supportFeatures: UInt32 = (1 << 6) | (1 << 7)

    private var scale: CGFloat { canvas.window?.backingScaleFactor ?? 2 }

    /// The tool goes on or off.
    func supportToolChanged(on: Bool) {
        if let v = canvas.view { zs_view_pick_skip_support(v, on ? 1 : 0) }
        if !on {
            supportDraft = []
            supportSelected = nil
        }
        treeClamp = 0
        readSupportTrees()
        readSupportAreas()
        applyFocus()
    }

    /// The areas of the core (after a slice, an undo, or a change).
    func readSupportAreas() {
        guard supportDrag == nil, treeDrag == nil else { return }
        let core = model.core
        supportAreas = (0 ..< zs_app_support_area_count(core)).compactMap { i in
            var kind: Int32 = 0, n = 0, lo = 0.0, hi = 0.0
            guard zs_app_support_area_get(core, i, &kind, nil, 0, &n, &lo, &hi) == 0 else { return nil }
            var xyz = [Double](repeating: 0, count: 3 * n)
            zs_app_support_area_get(core, i, nil, &xyz, n, nil, nil, nil)
            let pts = (0 ..< n).map { SIMD3(xyz[3 * $0], xyz[3 * $0 + 1], xyz[3 * $0 + 2]) }
            return SupportArea(kind: kind, zLo: lo, zHi: hi, points: pts)
        }
        if let s = supportSelected, s >= supportAreas.count { supportSelected = nil }
        showSupport()
    }

    /// The areas and the draft to the core view.
    func showSupport() {
        guard let v = canvas.view else { return }
        zs_view_support_clear(v)
        let on = tool == .support
        func add(_ pts: [SIMD3<Double>], _ kind: Int32, _ flags: Int32) {
            guard !pts.isEmpty else { return }
            var flat = pts.flatMap { [$0.x, $0.y, $0.z] }
            zs_view_support_add(v, &flat, pts.count, kind, flags)
        }
        for (i, a) in supportAreas.enumerated() {
            add(a.points, a.kind, 1 | (i == supportSelected ? 2 : 0) | (on ? 4 : 0))
        }
        if on { add(supportDraft, supportKind, 4) }
        // The overhang under the pointer: a click adds it.
        if on, supportDraft.isEmpty, let h = supportHover {
            var pts = Array(h.points.prefix(3 * h.n))
            zs_view_support_add(v, &pts, h.n, supportKind, 1 | 2 | 4)
        }
        showSupportTrees(v)
        canvas.requestFrame()
    }

    // MARK: - one click: the overhang under the pointer

    /// The pointer moved in the Support tool: the overhang near the point
    /// of the part under it, at most once for each frame (the last place
    /// of the pointer wins).
    func supportHover(at p: CGPoint?) {
        guard tool == .support, page == .threeD, supportDraft.isEmpty, !treeAdding, treeDrag == nil else {
            if supportHover != nil {
                supportHover = nil
                showSupport()
            }
            return
        }
        hoverAt = p
        guard !hoverDue else { return }
        hoverDue = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hoverDue = false
            pickOverhang()
        }
    }

    func pickOverhangForTest() { pickOverhang() }

    private func pickOverhang() {
        let before = supportHover != nil
        defer { if before || supportHover != nil { showSupport() } }
        guard let p = hoverAt, let q = surfacePoint(p, snap: false) else {
            supportHover = nil
            return
        }
        let t = CACurrentMediaTime()
        let cap = 2048
        var pts = [Double](repeating: 0, count: 3 * cap)
        var n = 0
        var zLo = 0.0, zHi = 0.0
        // 4 mm: the overhang can be beside the point, as on the web.
        let part = zs_app_support_pick(model.core, q.x, q.y, q.z, 4, &pts, cap, &n, &zLo, &zHi)
        if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
            NSLog("zslice support pick: part %ld, %ld points, %.2f ms", part, n, (CACurrentMediaTime() - t) * 1000)
        }
        supportHover = part >= 0 && n >= 3 ? (pts, n, zLo, zHi) : nil
    }

    /// A click on a highlighted overhang: it becomes an area of support.
    /// Returns false with nothing under the pointer.
    private func addHoveredOverhang() -> Bool {
        guard var h = supportHover else { return false }
        supportHover = nil
        let i = zs_app_support_area_add(model.core, supportKind, &h.points, h.n, h.zLo, h.zHi)
        guard i >= 0 else {
            showNote("The overhang did not become an area. \(statusText(Int32(-i)))")
            return true
        }
        supportSelected = Int(i)
        supportEdited()
        return true
    }

    // MARK: - picks

    private func pixel(_ p: SIMD3<Double>) -> CGPoint? { canvas.viewPoint(x: p.x, y: p.y, z: p.z) }

    /// The point of an area near a point of the view, the selected area first.
    private func supportPoint(near p: CGPoint) -> (area: Int, point: Int)? {
        let order = supportAreas.indices.sorted { a, _ in a == supportSelected }
        for i in order {
            for (j, q) in supportAreas[i].points.enumerated() {
                if let s = pixel(q), hypot(s.x - p.x, s.y - p.y) < 10 { return (i, j) }
            }
        }
        return nil
    }

    /// The area whose outline is near a point of the view.
    private func supportOutline(near p: CGPoint) -> Int? {
        var best: Int?
        var bestD: CGFloat = 10
        for (i, a) in supportAreas.enumerated() {
            let q = a.points.map(pixel)
            for j in q.indices {
                guard let s = q[j], let e = q[(j + 1) % q.count] else { continue }
                let d = segmentDistance(p, s, e)
                if d < bestD {
                    bestD = d
                    best = i
                }
            }
        }
        return best
    }

    private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    private func surfacePoint(_ p: CGPoint, snap: Bool) -> SIMD3<Double>? {
        guard let v = canvas.view else { return nil }
        var out = [Double](repeating: 0, count: 3)
        guard zs_view_surface_point(v, Float(p.x * scale), Float(p.y * scale), snap ? 1 : 0, &out) != 0 else { return nil }
        return SIMD3(out[0], out[1], out[2])
    }

    // MARK: - draw

    /// A click of the Support tool.
    func supportClick(_ p: CGPoint, snap: Bool) {
        guard page == .threeD else { return }
        if treeAddClick(p) { return }
        // The first point of the draft closes it.
        if supportDraft.count >= 3, let s = pixel(supportDraft[0]), hypot(s.x - p.x, s.y - p.y) < 10 {
            closeSupportArea()
            return
        }
        // With no draft, a click on an outline selects its area.
        if supportDraft.isEmpty, let i = supportOutline(near: p) {
            supportSelected = i
            showSupport()
            return
        }
        // One click: the overhang under the pointer. Option and a click
        // draw an area point by point.
        if supportDraft.isEmpty, !NSEvent.modifierFlags.contains(.option), addHoveredOverhang() { return }
        guard let q = surfacePoint(p, snap: snap) else { return }
        if supportDraft.isEmpty { supportSelected = nil }
        if supportDraft.count >= 256 { return }
        supportDraft.append(q)
        showSupport()
    }

    func closeSupportArea() {
        guard supportDraft.count >= 3 else { return }
        var flat = supportDraft.flatMap { [$0.x, $0.y, $0.z] }
        let n = supportDraft.count
        supportDraft = []
        let i = zs_app_support_area_add(model.core, supportKind, &flat, n, 1, 0)
        if i < 0 {
            showNote("The area needs 3 points or more, at most 256.")
        } else {
            supportSelected = Int(i)
        }
        supportEdited()
    }

    /// After a change of the areas in the core: a step of the history, the
    /// areas again, and a slice.
    func supportEdited() {
        model.history.commit()
        model.history.attach()
        model.settingsGeneration += 1
        model.requestSlice()
        readSupportAreas()
        // An area removed or made Block: a part can lose what held it.
        checkPendingFall()
    }

    func setSupportKind(_ kind: Int32) {
        if let i = supportSelected {
            if zs_app_support_area_set_kind(model.core, i, kind) == 0 { supportEdited() }
        } else {
            supportKind = kind
            showSupport()
        }
    }

    @discardableResult
    func removeSupportArea() -> Bool {
        guard let i = supportSelected else { return false }
        supportSelected = nil
        if zs_app_support_area_remove(model.core, i) == 0 { supportEdited() }
        return true
    }

    /// The keys of the tool. True if it used the key.
    func supportKey(_ event: NSEvent) -> Bool {
        guard tool == .support else { return false }
        switch event.specialKey {
        case .carriageReturn?, .enter?:
            guard supportDraft.count >= 3 else { return false }
            closeSupportArea()
            return true
        case .delete?:
            if !supportDraft.isEmpty {
                supportDraft.removeLast()
                showSupport()
                return true
            }
            return removeSupportArea() || deleteTreeBranch()
        case .deleteForward?:
            return removeSupportArea() || deleteTreeBranch()
        default:
            guard event.charactersIgnoringModifiers == "\u{1b}" else { return false }
            if !supportDraft.isEmpty {
                supportDraft = []
                showSupport()
                return true
            }
            if supportSelected != nil {
                supportSelected = nil
                showSupport()
                return true
            }
            if treeAdding {
                setTreeAdding(false)
                return true
            }
            if treeSelected != nil {
                treeSelected = nil
                treeClamp = 0
                showSupport()
                return true
            }
            return false
        }
    }

    // MARK: - drag a point

    /// A press on a point of an area starts a drag of it.
    func supportPress(_ p: CGPoint) -> Bool {
        guard tool == .support, page == .threeD, supportDraft.isEmpty else { return false }
        guard let hit = supportPoint(near: p) else { return treePress(p) }
        treeSelected = nil
        supportSelected = hit.area
        supportDrag = SupportDrag(area: hit.area, point: hit.point)
        showSupport()
        return true
    }

    func supportDragged(_ p: CGPoint, snap: Bool) {
        guard var d = supportDrag, d.area < supportAreas.count, let q = surfacePoint(p, snap: snap) else { return }
        supportAreas[d.area].points[d.point] = q
        d.moved = true
        // The outline follows at once; the core gets the points at most
        // each 60 ms, and holds the slice.
        showSupport()
        if Date().timeIntervalSince(d.sent) > 0.06 {
            d.sent = Date()
            sendSupportArea(d.area)
            model.changedHeld()
        }
        supportDrag = d
    }

    func supportReleased() {
        guard let d = supportDrag else { return }
        supportDrag = nil
        guard d.moved else { return }
        sendSupportArea(d.area)
        // The drag slices once, at the end, and is one step.
        model.changedHeld()
        model.release()
        model.history.commit()
        model.history.attach()
        model.settingsGeneration += 1
        readSupportAreas()
    }

    private func sendSupportArea(_ i: Int) {
        let pts = supportAreas[i].points
        var flat = pts.flatMap { [$0.x, $0.y, $0.z] }
        zs_app_support_area_set(model.core, i, &flat, pts.count, 1, 0)
    }
}
