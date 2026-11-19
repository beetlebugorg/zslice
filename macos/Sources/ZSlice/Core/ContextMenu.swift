//! The context menu of the view (docs/user/getting-started.md, "The
//! context menu"; linux/src/ui/view3d.c). A right click with no drag, or
//! Control and a click, on a line selects it and opens the menu:
//!
//! The menu fits what is under the pointer (web/app/context-menu.js):
//!
//! - on a support line: Remove This Support (a block area over the
//!   overhang that the line holds up), and Remove the Support Marks Here;
//! - on any line: Preview to This Layer (C), and Copy for AI;
//! - on a line of a part: the support marks, the drop, the layer profiles,
//!   and the placement of the part;
//! - on the bed: the plate items;
//! - each time: Clear All Support Marks, Show All Layers (Shift-C), the
//!   test prints, and Reset the View.
//!
//! The items:
//!
//! - Preview to This Layer (C), and Show All Layers (Shift-C);
//! - Add Support Here (grid, tree, or a bridge pad), Block Support Here,
//!   Remove the Support Marks Here, and Clear All Support Marks
//!   (zs_app_mark_*): a disk of 3 mm radius at the middle of the selected
//!   segment, on its layer;
//! - Put This Side on the Bed (zs_app_part_put_down_at), and the
//!   Placement of the part of the line (zs_app_part_place);
//! - for the plate: Smart Placement, Arrange the Plate, Add Models, and
//!   Clear the Plate (zs_app_plate_*);
//! - Add a Drop of Plastic Here: a dot of 1 mm at the middle of the
//!   selected segment, on its layer (zs_app_edit_add_dot), to fill a gap;
//! - Copy for AI: a report of the line (zs_app_line_report) on the
//!   clipboard, with its place in the G-code of the slice, which the app
//!   writes to its cache folder;
//! - Test Print: the top layer, or the layers shown (zs_app_debug_gcode),
//!   to a .gcode file;
//! - Reset the View.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// A menu item that runs a closure.
final class ClosureItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, key: String = "", _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}

extension Workspace {
    /// What is under the pointer, for the menu: a support line, a line of a
    /// part, or none (the bed or the air).
    enum MenuTarget { case support, part, empty }

    /// The menu for a point of the view: it selects the line there first.
    /// It fits what is under the pointer (web/app/context-menu.js): the
    /// support items on a support line, the part items on a line of a part,
    /// and the plate items on the bed. The view items show each time.
    func contextMenu(at p: CGPoint) -> NSMenu {
        let menu = NSMenu()
        // On a dot of a support tree that the Select tool picked: its own
        // menu.
        if tool != .support, supportPick?.tree == true, let (_, part, i) = treeElement(at: p) {
            treeSelected = (part, i)
            showSupport()
            menu.addItem(ClosureItem("Delete Branch") { [weak self] in self?.removePickedSupport() })
            return menu
        }
        pick(at: p, card: false)
        var on = MenuTarget.empty
        if let s = selection {
            var info = zs_inspect()
            let f = zs_app_inspect(model.core, s.path, &info) == 0 ? info.feature : -1
            on = f == Int32(ZS_FEATURE_SUPPORT.rawValue) || f == Int32(ZS_FEATURE_SUPPORT_INTERFACE.rawValue) ? .support : .part
        }
        let marks = zs_app_mark_count(model.core) > 0
        // Each section starts after a separator.
        func section(_ items: [NSMenuItem]) {
            guard !items.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
        if on == .support {
            var items = [ClosureItem("Remove This Support") { [weak self] in self?.removeSupportHere() }]
            if marks { items.append(ClosureItem("Remove the Support Marks Here") { [weak self] in self?.removeMarks() }) }
            section(items)
        }
        if let s = selection, let v = canvas.view {
            let layer = zs_view_path_layer(v, s.path)
            section([
                ClosureItem("Preview to This Layer") { [weak self] in
                    guard let self else { return }
                    setRange(lo: lo, hi: layer)
                },
                ClosureItem("Copy for AI") { [weak self] in self?.copyForAI() },
            ])
        }
        if on == .part {
            let support = NSMenuItem(title: "Add Support Here", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, kind) in [("Grid", ZS_MARK_GRID), ("Tree", ZS_MARK_TREE), ("Bridge (a Pad)", ZS_MARK_BRIDGE)] {
                sub.addItem(ClosureItem(title) { [weak self] in self?.addMark(Int32(kind.rawValue)) })
            }
            support.submenu = sub
            var items: [NSMenuItem] = [support, ClosureItem("Block Support Here") { [weak self] in self?.addMark(Int32(ZS_MARK_BLOCK.rawValue)) }]
            if marks { items.append(ClosureItem("Remove the Support Marks Here") { [weak self] in self?.removeMarks() }) }
            items.append(ClosureItem("Add a Drop of Plastic Here") { [weak self] in self?.addDrop() })
            section(items)
            section([
                ClosureItem("New Profile from Here Up") { [weak self] in self?.newLayerProfile(up: true) },
                ClosureItem("New Profile from Here Down") { [weak self] in self?.newLayerProfile(up: false) },
            ])
        }
        if on == .part, let s = selection, zs_app_part_of_path(model.core, s.path) >= 0 {
            let place = NSMenuItem(title: "Placement", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let modes: [(String, Int32, Int32)] = [
                ("Smart Placement", Int32(ZS_PLACE_SMART.rawValue), 0), ("Less Support", Int32(ZS_PLACE_LESS_SUPPORT.rawValue), 0),
                ("Strong Along X of the Part", Int32(ZS_PLACE_STRENGTH.rawValue), 0),
                ("Strong Along Y of the Part", Int32(ZS_PLACE_STRENGTH.rawValue), 1),
                ("Strong Along Z of the Part", Int32(ZS_PLACE_STRENGTH.rawValue), 2),
            ]
            for (title, mode, axis) in modes {
                sub.addItem(ClosureItem(title) { [weak self] in self?.placeLinePart(mode, axis) })
            }
            place.submenu = sub
            section([ClosureItem("Put This Side on the Bed") { [weak self] in self?.putDown() }, place])
        }
        if on == .empty {
            var items: [NSMenuItem] = [
                ClosureItem("Smart Placement") { [weak self] in self?.smartPlace() },
                ClosureItem("Arrange the Plate") { [weak self] in self?.plateAction(zs_app_plate_arrange, fits: true) },
                ClosureItem("Add Models…") { [weak self] in self?.addModels() },
                ClosureItem("Clear the Plate") { [weak self] in self?.plateAction(zs_app_plate_clear) },
            ]
            if model.plates.count > 1 {
                let i = model.active
                items.append(ClosureItem("Remove This Plate") { [weak self] in self?.removePlate(i) })
            }
            section(items)
        }
        var view: [NSMenuItem] = []
        if marks {
            view.append(ClosureItem("Clear All Support Marks") { [weak self] in
                guard let self else { return }
                zs_app_marks_clear(model.core)
                model.settingsChanged()
            })
        }
        if hi < layerCount - 1 || lo > 0 {
            view.append(ClosureItem("Show All Layers") { [weak self] in
                guard let self else { return }
                setRange(lo: 0, hi: layerCount - 1)
            })
        }
        if layerCount > 0 {
            view.append(ClosureItem("Test Print: the Top Layer…") { [weak self] in
                guard let self else { return }
                saveTestPrint(lo: hi, hi: hi + 1)
            })
            if lo > 0 || hi < layerCount - 1 {
                view.append(ClosureItem("Test Print: the Layers Shown…") { [weak self] in
                    guard let self else { return }
                    saveTestPrint(lo: lo, hi: hi + 1)
                })
            }
        }
        view.append(ClosureItem("Reset the View") { [weak self] in
            guard let self, let v = canvas.view else { return }
            zs_view_reset_smooth(v)
            canvas.startAnimation()
        })
        section(view)
        return menu
    }

    /// "Remove This Support": the support line holds up an overhang, and a
    /// block area over that overhang takes the support away, as the Support
    /// tool does. The overhang is the first surface that faces down, up from
    /// the line in steps of 0.5 mm (zs_app_support_pick). The support marks
    /// of the user near the line go too.
    func removeSupportHere() {
        guard let m = markPlace() else {
            showNote("The plate is slicing. Remove the support again in a moment.")
            return
        }
        var changed = zs_app_mark_remove_near(model.core, m.x, m.y, m.z, 3) > 0
        var tp = zs_toolpaths()
        let top = zs_app_toolpaths(model.core, &tp) == 0 && tp.layer_count > 0 ? Double(tp.layer_z[tp.layer_count - 1]) : m.z
        let cap = 2048
        var pts = [Double](repeating: 0, count: 3 * cap)
        var n = 0
        var zLo = 0.0, zHi = 0.0
        var z = m.z
        while z <= top + 0.5 {
            if zs_app_support_pick(model.core, m.x, m.y, z, 2, &pts, cap, &n, &zLo, &zHi) >= 0, n >= 3 { break }
            n = 0
            z += 0.5
        }
        if n >= 3, zs_app_support_area_add(model.core, Int32(ZS_MARK_BLOCK.rawValue), &pts, n, zLo, zHi) >= 0 { changed = true }
        guard changed else {
            showNote("zslice found no overhang over this support.")
            return
        }
        clearSelection()
        supportEdited()
    }

    /// The place of a support mark: the middle of the selected segment,
    /// at the z of its layer.
    func markPlace() -> (x: Double, y: Double, z: Double)? {
        guard let s = selection else { return nil }
        return pathPoint(s.path, seg: s.seg)
    }

    /// The middle of segment `seg` of path `path` (-1: the middle of the
    /// path), at the z of its layer.
    func pathPoint(_ path: Int, seg: Int) -> (x: Double, y: Double, z: Double)? {
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0, path < tp.path_count, let ends = tp.path_ends, let pts = tp.points else { return nil }
        let a = path == 0 ? 0 : Int(ends[path - 1]), b = Int(ends[path])
        guard b > a else { return nil }
        let i = seg >= 0 && a + seg + 1 < b ? a + seg : a + (b - a) / 2 - (b - a > 1 ? 1 : 0)
        let j = i + 1 < b ? i + 1 : i
        var layer = 0
        while layer < tp.layer_count && Int(tp.layer_ends[layer]) <= path { layer += 1 }
        let z = layer < tp.layer_count ? Double(tp.layer_z[layer]) : 0
        return ((Double(pts[2 * i]) + Double(pts[2 * j])) / 2, (Double(pts[2 * i + 1]) + Double(pts[2 * j + 1])) / 2, z)
    }

    /// A layer profile from the layer of the selected line, up or down. The
    /// drawer opens on it: a change goes only to its layers.
    func newLayerProfile(up: Bool) {
        guard let s = selection else { return }
        var info = zs_inspect()
        guard zs_app_inspect(model.core, s.path, &info) == 0 else { return }
        let zMin = up ? info.z : -1e6, zMax = up ? 1e6 : info.z
        let name = up ? "Layers \(info.layer + 1) and up" : "Layers 1 to \(info.layer + 1)"
        guard zs_app_profile_set(model.core, zMin, zMax, name) == 0 else { return }
        model.settingsChanged()
        editScope(.layers(zMin: zMin, zMax: zMax, name: name))
    }

    /// Opens the settings drawer on a scope.
    func editScope(_ scope: SettingScope) {
        model.scope = scope
        showSettings = true
        settingsPath = []
    }

    /// The part of the selected line lies on the bed with the side of the
    /// line down.
    private func putDown() {
        guard let s = selection, let m = markPlace() else { return }
        let part = zs_app_part_of_path(model.core, s.path)
        guard part >= 0, zs_app_part_put_down_at(model.core, Int(part), m.x, m.y, m.z) == 0 else { return }
        clearSelection()
        model.settingsChanged()
    }

    private func placeLinePart(_ mode: Int32, _ axis: Int32) {
        guard let s = selection else { return }
        let part = zs_app_part_of_path(model.core, s.path)
        guard part >= 0, zs_app_part_place(model.core, Int(part), mode, axis) == 0 else { return }
        clearSelection()
        model.settingsChanged()
    }

    /// Smart placement, arrange, or clear, for all the parts of the plate.
    /// fits: the action gives 1 if all parts fit (arrange, smart placement).
    func plateAction(_ action: (OpaquePointer?) -> Int32, fits: Bool = false) {
        // Arrange and smart placement give 1 if all parts fit, 0 if not; a
        // status is below 0.
        let rc = action(model.core)
        guard rc >= 0 else {
            showNote(statusText(rc))
            return
        }
        clearSelection()
        model.settingsChanged()
        if fits, rc == 0 {
            showNote("Not all parts fit on the plate.")
        }
    }

    /// Smart placement: it turns each part and tries its sides, which can
    /// take some seconds on the main thread (the core has no progress for
    /// it). The window shows that it works first, then runs it.
    func smartPlace() {
        guard !busy else { return }
        busy = true
        showNote("Smart placement: finding the best side of each part…", seconds: 120)
        Task { @MainActor in
            // Two frames, so the note and its spinner draw before the wait.
            try? await Task.sleep(for: .milliseconds(80))
            let t = CACurrentMediaTime()
            plateAction(zs_app_plate_smart_place, fits: true)
            busy = false
            if note?.hasPrefix("Smart placement") == true {
                showNote(String(format: "Smart placement done in %.1f s.", CACurrentMediaTime() - t), seconds: 2.5)
            }
        }
    }

    /// A drop of plastic of 1 mm at the middle of the selected segment, on
    /// the layer of its line.
    private func addDrop() {
        // The place and the layer of the selection, which work while a new
        // slice runs (zs_app_edit_add_dot_z).
        guard let s = selection, s.layer >= 0 else { return }
        let layer = s.layer
        let rc = zs_app_edit_add_dot_z(model.core, layer, s.z, s.x, s.y, 1.0)
        guard rc == 0 else {
            showNote("The drop did not work. \(statusText(rc))")
            return
        }
        editsChanged("A drop of plastic of 1.0 mm on layer \(layer + 1).")
    }

    private func addMark(_ kind: Int32) {
        guard let m = markPlace() else {
            showNote("The plate is slicing. Add the mark again in a moment.")
            return
        }
        if zs_app_mark_add(model.core, m.x, m.y, m.z, 3, kind) == 0 { model.settingsChanged() }
    }

    private func removeMarks() {
        guard let m = markPlace() else {
            showNote("The plate is slicing. Remove the marks again in a moment.")
            return
        }
        if zs_app_mark_remove_near(model.core, m.x, m.y, m.z, 3) > 0 { model.settingsChanged() }
    }

    /// A report of the selected line on the clipboard, for an AI chat.
    func copyForAI() {
        guard let s = selection else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("zslice")
        let file = dir.appendingPathComponent("last-slice.gcode")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let g = model.gcode() { try? g.write(to: file) }
        var out: UnsafePointer<CChar>?
        var len = 0
        guard zs_app_line_report(model.core, s.path, file.path, &out, &len) == 0, let out else { return }
        let text = String(decoding: UnsafeRawBufferPointer(start: out, count: len), as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
