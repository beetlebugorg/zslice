//! The tools of the view (web/app/tools.js, linux/src/ui/view3d.c): the
//! tool strip at the left picks what the mouse does.
//!
//! - Select (S): a click selects a line (Selection.swift).
//! - Move (M): a drag on a part moves it on the bed. Command and a drag do
//!   the same in the other tools. The frame of the part follows the pointer
//!   at once (zs_view_part_box), the core gets the place at most each 60
//!   ms, and the part slices once, at the end of the drag. Command and the
//!   wheel turn the selected part by 15° a step.
//! - Turn (R): the keys turn the selected part in steps of 15° (Shift:
//!   5°): Left and Right about Z (on the bed), Up and Down about X, Page Up
//!   and Page Down about Y.
//! - Measure (T): a tape between two points of the print or the bed. A
//!   click snaps to the end of the nearest line (Shift: no snap). A click on
//!   a circle or an arc gives its size, and the point is its center. A
//!   third click starts again, a drag of an end moves it, and Esc clears.
//!   The core draws the tape in the 3D view (zs_view_set_measure).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

enum Tool: String, CaseIterable {
    case select, move, turn, measure

    var key: String {
        switch self {
        case .select: "s"
        case .move: "m"
        case .turn: "r"
        case .measure: "t"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"
        case .move: "Move"
        case .turn: "Turn"
        case .measure: "Measure"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .turn: "arrow.trianglehead.2.clockwise.rotate.90"
        case .measure: "ruler"
        }
    }

    var help: String {
        switch self {
        case .select: "Select (S): click a line to see what it is and the settings that change it."
        case .move: "Move (M): drag a part to move it on the bed. Command-scroll turns it by 15°. Command-drag moves a part in any tool."
        case .turn: "Turn (R): click a part, then drag its red, green, or blue ring to turn it about X, Y, or Z (15°; Shift: 5°). Keys: Left and Right about Z, Up and Down about X, Page Up and Page Down about Y."
        case .measure: "Measure (T): click two points of the print or the bed. A click on a circle or an arc measures from its center. Shift: no snap. Esc clears."
        }
    }
}

/// A point of the measure tape (mm), and the circle or arc under it.
struct TapePoint {
    var x: Double, y: Double, z: Double
    /// The radius of a circle (shape 1) or an arc (shape 2), else 0.
    var r: Double = 0
    var shape: Int32 = 0
}

/// A drag of a part: the part, its place and the bed point at the press.
struct PartDrag {
    var index: Int
    var x0: Double, y0: Double
    var bx0: Double, by0: Double
    var x: Double, y: Double
    var sent = Date.distantPast
}

extension Workspace {
    func setTool(_ t: Tool) {
        tool = t
        if t != .measure { clearTape() }
        if t == .select { selectPart(nil) }
        showRings()
        canvas.window?.invalidateCursorRects(for: canvas)
    }

    private var pixelScale: CGFloat { canvas.window?.backingScaleFactor ?? 2 }

    // MARK: - parts

    /// The part under a point of the view: the part of the line there, or
    /// the part on the bed there. nil if none.
    func partAt(_ p: CGPoint) -> Int? {
        guard let v = canvas.view, page == .threeD else { return nil }
        let px = Float(p.x * pixelScale), py = Float(p.y * pixelScale)
        let path = zs_view_pick(v, px, py)
        if path != noPath {
            let part = zs_app_part_of_path(model.core, path)
            if part >= 0 { return part }
        }
        var x = 0.0, y = 0.0
        guard zs_view_bed_point(v, px, py, &x, &y) != 0 else { return nil }
        let part = zs_app_part_at(model.core, x, y)
        return part >= 0 ? part : nil
    }

    func part(_ i: Int) -> zs_part? {
        var p = zs_part()
        return zs_app_part_get(model.core, i, &p) == 0 ? p : nil
    }

    /// Selects a part (nil: none). The view draws its frame on the bed,
    /// and in the Turn tool the rings around it.
    func selectPart(_ i: Int?) {
        selectedPart = i
        showPartBox(i.flatMap { part($0) }.map { ($0.x, $0.y, $0.size_x, $0.size_y) })
        showRings()
    }

    /// The rings of the Turn tool around the selected part (the core draws
    /// them): its center at half its height, and a radius for its size.
    func showRings() {
        guard let v = canvas.view else { return }
        if tool == .turn, let i = selectedPart, let p = part(i) {
            zs_view_set_rings(v, p.x, p.y, p.size_z / 2, 0.62 * max(p.size_x, p.size_y, p.size_z) + 4)
        } else {
            zs_view_set_rings(v, 0, 0, 0, 0)
        }
        canvas.requestFrame()
    }

    private func showPartBox(_ b: (x: Double, y: Double, w: Double, h: Double)?) {
        guard let v = canvas.view else { return }
        if let b {
            zs_view_part_box(v, b.x - b.w / 2, b.y - b.h / 2, b.x + b.w / 2, b.y + b.h / 2)
        } else {
            zs_view_part_box(v, 0, 0, -1, -1)
        }
        canvas.requestFrame()
    }

    // MARK: - the mouse

    /// A press: the Move tool or Command on a part starts a move, and the
    /// Measure tool on an end of the tape starts a drag of that end.
    func press(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> Bool {
        if tool == .measure, let i = tapeEnd(near: p) {
            tapeDrag = i
            return true
        }
        if tool == .turn, selectedPart != nil, let v = canvas.view {
            let px = Float(p.x * pixelScale), py = Float(p.y * pixelScale)
            let axis = zs_view_ring_at(v, px, py, Float(8 * pixelScale))
            if axis >= 0, zs_view_ring_press(v, axis, px, py) != 0 {
                ringDrag = (Int(axis), 0)
                canvas.requestFrame()
                return true
            }
        }
        guard tool == .move || flags.contains(.command), let i = partAt(p), let info = part(i), let v = canvas.view else {
            return false
        }
        var bx = 0.0, by = 0.0
        guard zs_view_bed_point(v, Float(p.x * pixelScale), Float(p.y * pixelScale), &bx, &by) != 0 else { return false }
        clearSelection()
        selectPart(i)
        partDrag = PartDrag(index: i, x0: info.x, y0: info.y, bx0: bx, by0: by, x: info.x, y: info.y)
        return true
    }

    func drag(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) {
        if let r = ringDrag, let i = selectedPart, let v = canvas.view, let info = part(i) {
            let total = zs_view_ring_drag(v, Float(p.x * pixelScale), Float(p.y * pixelScale), flags.contains(.shift) ? 5 : 15)
            let step = total - r.sent
            if step != 0 {
                if r.axis == 2 {
                    zs_app_part_rotate(model.core, i, info.rotation + step)
                } else {
                    zs_app_part_turn(model.core, i, Int32(r.axis), step)
                }
                ringDrag = (r.axis, total)
                model.changedHeld()
                selectPart(i)
            }
            ringLabel = (String(format: "%@%.0f° about %@", total > 0 ? "+" : "", total, ["X", "Y", "Z"][r.axis]), p)
            canvas.requestFrame()
            return
        }
        if let i = tapeDrag {
            moveTapeEnd(i, to: p, snap: !flags.contains(.shift))
            return
        }
        guard var d = partDrag, let v = canvas.view, let info = part(d.index) else { return }
        var bx = 0.0, by = 0.0
        guard zs_view_bed_point(v, Float(p.x * pixelScale), Float(p.y * pixelScale), &bx, &by) != 0 else { return }
        d.x = d.x0 + bx - d.bx0
        d.y = d.y0 + by - d.by0
        // The frame follows at once; the core gets the place at most each
        // 60 ms, and the slice waits for the end of the drag.
        showPartBox((d.x, d.y, info.size_x, info.size_y))
        if Date().timeIntervalSince(d.sent) > 0.06 {
            d.sent = Date()
            zs_app_part_move(model.core, d.index, d.x, d.y)
            model.changedHeld()
        }
        partDrag = d
    }

    func release(_ p: CGPoint) {
        if let r = ringDrag, let v = canvas.view {
            zs_view_ring_release(v)
            ringDrag = nil
            ringLabel = nil
            // The turn slices once, at the end of the drag.
            if r.sent != 0 { model.release() }
            canvas.requestFrame()
            return
        }
        if tapeDrag != nil {
            tapeDrag = nil
            return
        }
        guard let d = partDrag else { return }
        partDrag = nil
        zs_app_part_move(model.core, d.index, d.x, d.y)
        // The move slices once, at the end of the drag.
        model.changedHeld()
        model.release()
    }

    /// Command and the wheel: the selected part turns 15° a step.
    func turnWheel(_ dy: CGFloat) -> Bool {
        guard let i = selectedPart, let p = part(i) else { return false }
        zs_app_part_rotate(model.core, i, p.rotation + (dy > 0 ? 15 : -15))
        selectPart(i)
        model.changedHeld()
        wheelSlice.run { [weak self] in self?.model.release() }
        return true
    }

    // MARK: - the Turn tool

    /// The keys of the Turn tool. Returns false for a key it does not use.
    func turnKey(_ event: NSEvent) -> Bool {
        guard tool == .turn, let i = selectedPart, let p = part(i) else { return false }
        let step = event.modifierFlags.contains(.shift) ? 5.0 : 15.0
        switch event.specialKey {
        case .leftArrow?: zs_app_part_rotate(model.core, i, p.rotation + step)
        case .rightArrow?: zs_app_part_rotate(model.core, i, p.rotation - step)
        case .upArrow?: zs_app_part_turn(model.core, i, 0, step)
        case .downArrow?: zs_app_part_turn(model.core, i, 0, -step)
        case .pageUp?: zs_app_part_turn(model.core, i, 1, step)
        case .pageDown?: zs_app_part_turn(model.core, i, 1, -step)
        default: return false
        }
        selectPart(i)
        model.settingsChanged()
        return true
    }

    // MARK: - the measure tape

    /// A click of the Measure tool. snap: to the end of the nearest line,
    /// and to the center of a circle or an arc.
    func measureClick(_ p: CGPoint, snap: Bool) {
        guard let v = canvas.view else { return }
        var pt: (Double, Double, Double)
        var path = noPath, seg = 0
        if page == .twoD {
            guard let mm = canvas.millimeters(of: p) else { return }
            pt = (mm.x, mm.y, Double(z(of: hi)))
            path = zs_view_pick_layer(v, hi, mm.x, mm.y, &seg)
        } else {
            var out = [Double](repeating: 0, count: 3)
            let px = Float(p.x * pixelScale), py = Float(p.y * pixelScale)
            guard zs_view_surface_point(v, px, py, snap ? 1 : 0, &out) != 0 else { return }
            pt = (out[0], out[1], out[2])
            path = zs_view_pick_segment(v, px, py, &seg)
        }
        // A circle or an arc under the pointer: the point is its center.
        if snap, path != noPath {
            var m = zs_measure()
            if zs_app_measure(model.core, path, seg, &m) == 0, m.shape == 1 || m.shape == 2 {
                select(path: path, seg: seg, openCard: false)
                addTape(TapePoint(x: m.center_x, y: m.center_y, z: pt.2, r: m.radius, shape: m.shape))
                return
            }
        }
        addTape(TapePoint(x: pt.0, y: pt.1, z: pt.2))
    }

    private func addTape(_ p: TapePoint) {
        // A third point starts a new measure.
        if tape.count >= 2 { tape = [] }
        tape.append(p)
        showTape()
    }

    func clearTape() {
        guard !tape.isEmpty else { return }
        tape = []
        showTape()
    }

    private func tapeEnd(near p: CGPoint) -> Int? {
        var best: Int?
        var bestD: CGFloat = 14
        for (i, q) in tape.enumerated() {
            guard let s = canvas.viewPoint(x: q.x, y: q.y, z: q.z) else { continue }
            let d = hypot(s.x - p.x, s.y - p.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func moveTapeEnd(_ i: Int, to p: CGPoint, snap: Bool) {
        guard i < tape.count, let v = canvas.view else { return }
        if page == .twoD {
            guard let mm = canvas.millimeters(of: p) else { return }
            tape[i] = TapePoint(x: mm.x, y: mm.y, z: tape[i].z)
        } else {
            var out = [Double](repeating: 0, count: 3)
            guard zs_view_surface_point(v, Float(p.x * pixelScale), Float(p.y * pixelScale), snap ? 1 : 0, &out) != 0 else { return }
            // A moved end is a point, not a center.
            tape[i] = TapePoint(x: out[0], y: out[1], z: out[2])
        }
        showTape()
    }

    /// The tape in the 3D view (the core draws it), and the readout.
    private func showTape() {
        guard let v = canvas.view else { return }
        var pts = tape.flatMap { [$0.x, $0.y, $0.z] }
        zs_view_set_measure(v, tape.count, &pts)
        canvas.requestFrame()
        placeTape()
    }

    /// The points of the tape in the view, after each frame (the readout
    /// and the 2D tape follow the camera).
    func placeTape() {
        let pts = tape.compactMap { canvas.viewPoint(x: $0.x, y: $0.y, z: $0.z) }
        if pts.count != tapeScreen.count || zip(pts, tapeScreen).contains(where: { hypot($0.x - $1.x, $0.y - $1.y) > 0.5 }) {
            tapeScreen = pts
        }
    }
}

// MARK: - the part card

extension Workspace {
    /// The settings that a part has of its own (zs_app_part_setting_get).
    func partSettings(_ i: Int) -> [(info: SettingInfo, value: String)] {
        _ = model.settingsGeneration
        return SettingInfo.all.filter(\.perPart).compactMap { info in
            coreString { zs_app_part_setting_get(model.core, i, info.name, $0, $1, $2) }.map { (info, $0) }
        }
    }

    /// Sets a setting of a part (nil: the value of the plate again).
    @discardableResult
    func setPartSetting(_ i: Int, _ name: String, _ value: String?) -> String? {
        let rc = zs_app_part_setting_set(model.core, i, name, value)
        guard rc == 0 else { return statusText(rc) }
        model.settingsChanged()
        return nil
    }

    func duplicatePart() {
        guard let i = selectedPart else { return }
        let j = zs_app_part_duplicate(model.core, i)
        if j >= 0 { selectPart(j) }
        model.settingsChanged()
    }

    /// Makes each separate body of the selected part a part of its own.
    func splitPart() {
        guard let i = selectedPart else { return }
        let n = zs_app_part_split(model.core, i)
        if n > 0 {
            model.settingsChanged()
            selectPart(i)
        } else if n == 0 {
            let a = NSAlert()
            a.messageText = "The part is one body"
            a.informativeText = "It has no separate bodies to split."
            a.runModal()
        }
    }

    func placePart(_ mode: Int32) {
        guard let i = selectedPart else { return }
        if zs_app_part_place(model.core, i, mode, 2) == 0 {
            selectPart(i)
            model.settingsChanged()
        }
    }

    func resetPart() {
        guard let i = selectedPart, zs_app_part_reset(model.core, i) == 0 else { return }
        selectPart(i)
        model.settingsChanged()
    }

    func removePart() {
        guard let i = selectedPart, zs_app_part_remove(model.core, i) == 0 else { return }
        selectPart(nil)
        clearSelection()
        model.settingsChanged()
    }

    /// The keys of a selected part: the arrows move it 1 mm (Shift: 10 mm),
    /// Tab and Shift-Tab select the next part and the part before, D
    /// duplicates it, Delete removes it, and Esc clears the selection. The
    /// part slices after a pause of 0.6 s in the keys.
    func partKey(_ event: NSEvent) -> Bool {
        guard let i = selectedPart, let p = part(i) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let d = shift ? 10.0 : 1.0
        func move(_ dx: Double, _ dy: Double) {
            zs_app_part_move(model.core, i, p.x + dx, p.y + dy)
            selectPart(i)
            model.changedHeld()
            keySlice.run { [weak self] in self?.model.release() }
        }
        switch event.specialKey {
        case .leftArrow?: move(-d, 0)
        case .rightArrow?: move(d, 0)
        case .upArrow?: move(0, d)
        case .downArrow?: move(0, -d)
        case .tab?, .backTab?:
            let n = zs_app_part_count(model.core)
            guard n > 0 else { return false }
            selectPart((i + (shift || event.specialKey == .backTab ? n - 1 : 1)) % n)
        case .delete?, .deleteForward?: removePart()
        default:
            switch event.charactersIgnoringModifiers {
            case "d" where !shift: duplicatePart()
            case "\u{1b}": selectPart(nil)
            default: return false
            }
        }
        return true
    }
}
