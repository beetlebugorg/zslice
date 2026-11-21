//! Copy (⌘C), Cut (⌘X), Paste (⌘V), Paste as a New Plate (⇧⌘V), and
//! Duplicate (⌘D) for each kind of object that the app can select, as the
//! web app does (web/app/clipboard.js).
//!
//! What a copy takes, by the selection (the first that applies):
//!
//! - The selected label of the Label tool: the label (its shapes, its
//!   filament, its depth, and its turn).
//! - The selected area of the Support tool: the area, and the part under
//!   its center.
//! - The card of a range of layers: the changes of those layers.
//! - The selected parts: the parts in the core (zs_app_parts_copy), with
//!   their settings, paint, labels, support trees, and the support areas
//!   and marks over them.
//! - A selected line: the report of the line ("Copy for AI").
//!
//! A paste puts the last copy where it fits:
//!
//! - Parts: with parts selected, each copy at a free place (as Duplicate).
//!   With no selection, the group at the bed point under the pointer. On
//!   an empty plate, at the places of the copy. The copies become the
//!   selection.
//! - A label: on the face under the pointer, with the same turn. Else on
//!   the same face, under the label of the copy (over it at the foot of
//!   the part).
//! - A support area: at the same place on the part under the pointer. On
//!   the part of the copy, the area goes to the pointer.
//! - The changes of layers: on the layers of the range card.
//!
//! Each paste is one step of the history. Cut is a copy and a remove (for
//! layers, the changes go; the value of the print stays). The parts stay
//! in the clipboard of the core: one for the process, so a paste works on
//! each plate and in each window. A text field keeps its own copy and
//! paste (ClipboardCommands).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// The last copy of the app. The parts and plates are in the core; this
/// keeps what kind the last copy is, and the data of the other kinds.
enum Clip {
    case parts(Int)
    case plate(Int)
    case label(PartLabel, part: Int)
    case area(SupportArea, part: (index: Int, x: Double, y: Double, rotation: Double)?)
    case range([(name: String, value: String)])
    case line

    @MainActor static var current: Clip?

    var isParts: Bool {
        switch self {
        case .parts, .plate: true
        default: false
        }
    }
}

extension Workspace {
    /// What a copy takes now.
    enum ClipSelection { case label, area, range, parts([Int]), line }

    var clipSelection: ClipSelection? {
        if tool == .label, labelState.label != nil { return .label }
        if tool == .support, supportSelected != nil { return .area }
        if rangeCard != nil { return .range }
        if !selectedParts.isEmpty { return .parts(selectedParts) }
        if selection != nil { return .line }
        return nil
    }

    /// The pointer over the view (points from the top left), or nil.
    var pointerInView: CGPoint? {
        guard let w = canvas.window else { return nil }
        let p = canvas.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return canvas.bounds.contains(p) ? p : nil
    }

    // MARK: - copy, cut, duplicate

    @discardableResult
    func clipCopy() -> Bool {
        guard let sel = clipSelection else {
            showNote("Select a part, a label, a support area, or layers to copy.")
            return false
        }
        switch sel {
        case .label:
            guard var l = labelState.label else { return false }
            l.id = 0
            Clip.current = .label(l, part: labelState.index)
            showNote("Copied the label.")
        case .area:
            guard let i = supportSelected, supportAreas.indices.contains(i) else { return false }
            let a = supportAreas[i]
            let n = Double(max(1, a.points.count))
            let cx = a.points.reduce(0) { $0 + $1.x } / n, cy = a.points.reduce(0) { $0 + $1.y } / n
            let k = zs_app_part_at(model.core, cx, cy)
            let under = k >= 0 ? part(k).map { (index: k, x: $0.x, y: $0.y, rotation: $0.rotation) } : nil
            Clip.current = .area(a, part: under)
            showNote("Copied the support area.")
        case .range:
            let list = rangeChanges()
            guard !list.isEmpty else {
                showNote("These layers have no changes to copy.")
                return false
            }
            Clip.current = .range(list)
            showNote(list.count == 1 ? "Copied 1 change of the layers." : "Copied \(list.count) changes of the layers.")
        case let .parts(list):
            guard copyParts(list) else { return false }
            let n = zs_clipboard_parts()
            showNote(n == 1 ? "Copied the part." : "Copied \(n) parts.")
        case .line:
            copyForAI()
            Clip.current = .line
            showNote("The report of the line is on the clipboard.")
        }
        return true
    }

    private func copyParts(_ list: [Int]) -> Bool {
        let n = zs_app_part_count(model.core)
        let parts = Array(Set(list.filter { $0 >= 0 && $0 < n })).sorted()
        guard !parts.isEmpty, zs_app_parts_copy(model.core, parts, parts.count, 0) == 0 else {
            showNote("The parts did not copy.")
            return false
        }
        Clip.current = .parts(zs_clipboard_parts())
        return true
    }

    func clipCut() {
        guard let sel = clipSelection else {
            showNote("Select a part, a label, a support area, or layers to copy.")
            return
        }
        switch sel {
        case .label:
            if clipCopy() { removeLabel() }
        case .area:
            if clipCopy() { removeSupportArea() }
        case .range:
            guard clipCopy(), case let .range(list)? = Clip.current, let (zMin, zMax) = rangeZ() else { return }
            var changed = false
            for c in list where zs_app_override_remove(model.core, zMin, zMax, c.name) == 1 || zs_app_override_clear_at(model.core, zMin, c.name) > 0 {
                changed = true
            }
            if changed { model.settingsChanged() }
        case let .parts(list):
            guard copyParts(list) else { return }
            let n = zs_clipboard_parts()
            removePart()
            showNote(n == 1 ? "Cut the part. ⌘V pastes it." : "Cut \(n) parts. ⌘V pastes them.")
        case .line:
            clipCopy()
        }
    }

    /// A copy next to the selection, with no change of the clipboard.
    func clipDuplicate() {
        switch clipSelection {
        case .parts?: duplicatePart()
        case .label?:
            if var l = labelState.label {
                l.id = 0
                pasteLabel(l, at: nil, part: labelState.index)
            }
        default: showNote("⌘D duplicates parts and labels.")
        }
    }

    // MARK: - paste

    /// Pastes the last copy. at: a point of the view (the pointer, or the
    /// place of a right click). here: the parts go there also with parts
    /// selected (the context menu).
    func clipPaste(at: CGPoint? = nil, here: Bool = false) {
        guard let clip = Clip.current else {
            showNote("The clipboard is empty: copy a part, a label, a support area, or layers first.")
            return
        }
        let at = at ?? pointerInView
        let in3D = page == .threeD
        switch clip {
        case .parts, .plate:
            var x = 0.0, y = 0.0
            var point = false
            if (here || selectedParts.isEmpty), in3D, let p = at, let v = canvas.view {
                let s = canvas.window?.backingScaleFactor ?? 2
                point = zs_view_bed_point(v, Float(p.x * s), Float(p.y * s), &x, &y) != 0
            }
            pasteParts(point ? (x, y) : nil)
        case let .label(l, part):
            guard in3D else {
                showNote("Paste a label in the 3D view.")
                return
            }
            pasteLabel(l, at: at, part: part)
        case let .area(a, part):
            guard in3D, let p = at, let k = partAt(p) else {
                showNote("Point at a part to paste the support area there.")
                return
            }
            if pasteArea(a, from: part, onto: k, at: p) { showNote("Pasted the support area.") }
        case let .range(list):
            guard let (zMin, zMax) = rangeZ() else {
                showNote("Select layers first (drag up or down over the print), then paste the changes.")
                return
            }
            var done = 0
            var error = ""
            for c in list {
                guard SettingInfo.byName[c.name]?.perLayer == true else { continue }
                if zs_app_override_set(model.core, zMin, zMax, c.name, c.value) == 0 { done += 1 } else { error = "The value of \(SettingInfo.byName[c.name]?.label ?? c.name) did not paste." }
            }
            if done > 0 { model.settingsChanged() }
            if !error.isEmpty { showNote(error) }
        case .line:
            showNote("The report of a line is text: paste it into a chat or a note.")
        }
    }

    /// The parts of the clipboard on the active plate: the center of the
    /// group at a bed point, or free places. The copies become the
    /// selection.
    private func pasteParts(_ bed: (x: Double, y: Double)?) {
        guard zs_clipboard_parts() > 0 else {
            showNote("The clipboard is empty: copy a part first.")
            return
        }
        model.history.commit()
        let first = zs_app_parts_paste(model.core, bed == nil ? 0 : 1, bed?.x ?? 0, bed?.y ?? 0)
        guard first >= 0 else {
            showNote("The parts did not paste.")
            return
        }
        let n = zs_app_part_count(model.core)
        selectOnlyPart(first)
        for i in (first + 1) ..< max(first + 1, n) { togglePart(i) }
        model.readPlates()
        model.settingsChanged()
        if zs_app_plate_fits(model.core) == 0 { showNote("The parts do not all fit on the bed. Move some, or paste on another plate.") }
    }

    /// A copy of a label on part `part` (or the part under the point). On
    /// a face under the point: there, with the same turn. Else under the
    /// label of the copy, on the same face, or over it when no face is
    /// under it.
    func pasteLabel(_ src: PartLabel, at p: CGPoint?, part: Int) {
        if tool != .label { setTool(.label) }
        var index = labelState.index >= 0 ? labelState.index : part
        var label: PartLabel?
        var curve = 0.0
        if let p, let k = partAt(p) {
            index = k
            if let s = labelSessionFor(k), let r = labelRayAt(p), let at = LabelPlace(s, ray: r) {
                var l = src
                l.origin = Array(at.origin)
                l.normal = Array(at.normal)
                l.right = Array(at.right)
                label = l.withAngle(src.angle)
                curve = at.curve
            }
        }
        guard index >= 0 else {
            showNote("Point at a part to paste the label there.")
            return
        }
        if index != labelState.index { loadLabels(index) }
        if label == nil {
            // Under the label of the copy: its height and 1 mm lower, on the
            // surface again (a ray in along the normal from 5 mm out). With
            // no face there (the label is at the foot of the part), over it.
            let h = LabelOutline(src).map { $0.box.y1 - $0.box.y0 } ?? 5
            let n = SIMD3<Double>(src.normal)
            for sign in [-1.0, 1.0] {
                let at = SIMD3<Double>(src.origin) + sign * (h + 1) * src.up
                let from = at + 5 * n
                let ray = [from.x, from.y, from.z, -n.x, -n.y, -n.z].map(Float.init)
                let place = labelSessionFor(index).flatMap { LabelPlace($0, ray: ray) }
                if ProcessInfo.processInfo.environment["ZSLICE_LABEL_LOG"] != nil {
                    NSLog("zslice label paste: %@ from %.1f %.1f %.1f, up %.2f %.2f %.2f, hit %@", sign < 0 ? "under" : "over", from.x, from.y, from.z,
                          src.up.x, src.up.y, src.up.z, place.map { String(format: "%.1f %.1f %.1f", $0.origin.x, $0.origin.y, $0.origin.z) } ?? "none")
                }
                if let place, place.origin.z >= 0 {
                    label = src.moved(origin: place.origin, normal: place.normal)
                    curve = place.curve
                    break
                }
            }
        }
        guard let label else {
            showNote("The label does not fit here. Point at a face of the part, then paste.")
            return
        }
        var id: UInt32 = 0
        let json = label.json
        guard json.withCString({ zs_app_label_add(model.core, index, $0, strlen($0), &id) }) == 0 else {
            showNote("The label does not fit here.")
            return
        }
        model.settingsChanged()
        loadLabels(index, select: id)
        labelState.curve = curve
    }

    /// A copy of a support area on part `k`, under the point p: at the
    /// same place on that part (turned with it), or, on the part of the
    /// copy, with its center at the surface under the point.
    private func pasteArea(_ src: SupportArea, from: (index: Int, x: Double, y: Double, rotation: Double)?, onto k: Int, at p: CGPoint) -> Bool {
        guard let to = part(k) else { return false }
        let n = Double(max(1, src.points.count))
        let cx = src.points.reduce(0) { $0 + $1.x } / n, cy = src.points.reduce(0) { $0 + $1.y } / n
        var move: (SIMD3<Double>) -> SIMD3<Double>
        if let f = from, f.index != k || abs(f.x - to.x) > 1e-6 || abs(f.y - to.y) > 1e-6 {
            let a = (to.rotation - f.rotation) * .pi / 180
            move = { q in
                let dx = q.x - f.x, dy = q.y - f.y
                return SIMD3(to.x + dx * cos(a) - dy * sin(a), to.y + dx * sin(a) + dy * cos(a), q.z)
            }
        } else {
            guard let v = canvas.view else { return false }
            let s = canvas.window?.backingScaleFactor ?? 2
            var out = [Double](repeating: 0, count: 3)
            guard zs_view_surface_point(v, Float(p.x * s), Float(p.y * s), 0, &out) != 0 else {
                showNote("Point at a part to paste the support area there.")
                return false
            }
            move = { q in SIMD3(q.x + out[0] - cx, q.y + out[1] - cy, q.z) }
        }
        var flat = src.points.map(move).flatMap { [$0.x, $0.y, $0.z] }
        let i = zs_app_support_area_add(model.core, src.kind, &flat, src.points.count, src.zLo, src.zHi)
        guard i >= 0 else {
            showNote("The support area did not paste.")
            return false
        }
        if tool == .support { supportSelected = Int(i) }
        supportEdited()
        return true
    }

    // MARK: - the layers of the range card

    /// The z range of the range card, or nil.
    private func rangeZ() -> (Double, Double)? {
        guard let r = rangeCard, let a = layerTopBottom(r.lo), let b = layerTopBottom(r.hi) else { return nil }
        return (a.top, b.top)
    }

    /// The changes of the layers of the range card: the overrides that
    /// cover its first layer, the last one of each setting.
    private func rangeChanges() -> [(name: String, value: String)] {
        guard let (zMin, _) = rangeZ() else { return [] }
        var out: [(name: String, value: String)] = []
        func text(_ p: UnsafePointer<CChar>?, _ n: Int) -> String {
            p.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: n), as: UTF8.self) } ?? ""
        }
        for i in 0 ..< zs_app_override_count(model.core) {
            var o = zs_override()
            guard zs_app_override_get(model.core, i, &o) == 0, o.z_min <= zMin + 1e-4, o.z_max >= zMin - 1e-4 else { continue }
            let name = text(o.name, o.name_len), value = text(o.value, o.value_len)
            out.removeAll { $0.name == name }
            out.append((name, value))
        }
        return out
    }

    // MARK: - the plate

    func copyPlate() {
        guard zs_app_part_count(model.core) > 0, zs_app_parts_copy(model.core, nil, 0, 1) == 0 else {
            showNote("The plate has no parts to copy.")
            return
        }
        let n = zs_clipboard_parts()
        Clip.current = .plate(n)
        showNote(n == 1 ? "Copied the plate (1 part)." : "Copied the plate (\(n) parts).")
    }

    /// A new plate after the others with the parts or plate of the
    /// clipboard, at the places of the copy. It becomes the active plate.
    func pasteAsPlate() {
        guard Clip.current?.isParts == true, zs_clipboard_parts() > 0 else {
            showNote("Copy parts or a plate first.")
            return
        }
        model.addPlate()
        guard zs_app_parts_paste(model.core, 0, 0, 0) >= 0 else {
            showNote("The plate did not paste.")
            return
        }
        model.readPlates()
        model.settingsChanged()
        framePlate(model.active)
    }

    /// A new plate after the others with a copy of the active plate (its
    /// settings, parts, support, and layer changes), with no change of the
    /// clipboard. It becomes the active plate.
    func duplicatePlate() {
        let from = model.core
        guard zs_app_part_count(from) > 0 else {
            showNote("The plate has no parts to duplicate.")
            return
        }
        model.addPlate()
        guard zs_app_plate_copy_to(from, model.core) >= 0 else {
            showNote("The plate did not duplicate.")
            return
        }
        model.readPlates()
        model.settingsChanged()
        framePlate(model.active)
    }
}
