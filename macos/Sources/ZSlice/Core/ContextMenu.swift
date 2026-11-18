//! The context menu of the view (docs/user/getting-started.md, "The
//! context menu"; linux/src/ui/view3d.c). A right click with no drag, or
//! Control and a click, on a line selects it and opens the menu:
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
//! - Copy for AI: a report of the line (zs_app_line_report) on the
//!   clipboard, with its place in the G-code of the slice, which the app
//!   writes to its cache folder;
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
    /// The menu for a point of the view: it selects the line there first.
    func contextMenu(at p: CGPoint) -> NSMenu {
        pick(at: p, card: false)
        let menu = NSMenu()
        if let s = selection, let v = canvas.view {
            let layer = zs_view_path_layer(v, s.path)
            menu.addItem(ClosureItem("Preview to This Layer") { [weak self] in
                guard let self else { return }
                setRange(lo: lo, hi: layer)
            })
        }
        if hi < layerCount - 1 || lo > 0 {
            menu.addItem(ClosureItem("Show All Layers") { [weak self] in
                guard let self else { return }
                setRange(lo: 0, hi: layerCount - 1)
            })
        }
        if selection != nil {
            menu.addItem(.separator())
            let support = NSMenuItem(title: "Add Support Here", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, kind) in [("Grid", ZS_MARK_GRID), ("Tree", ZS_MARK_TREE), ("Bridge (a Pad)", ZS_MARK_BRIDGE)] {
                sub.addItem(ClosureItem(title) { [weak self] in self?.addMark(Int32(kind.rawValue)) })
            }
            support.submenu = sub
            menu.addItem(support)
            menu.addItem(ClosureItem("Block Support Here") { [weak self] in self?.addMark(Int32(ZS_MARK_BLOCK.rawValue)) })
            menu.addItem(ClosureItem("Remove the Support Marks Here") { [weak self] in self?.removeMarks() })
            menu.addItem(.separator())
            menu.addItem(ClosureItem("New Profile from Here Up") { [weak self] in self?.newLayerProfile(up: true) })
            menu.addItem(ClosureItem("New Profile from Here Down") { [weak self] in self?.newLayerProfile(up: false) })
        }
        if let s = selection, zs_app_part_of_path(model.core, s.path) >= 0 {
            menu.addItem(.separator())
            menu.addItem(ClosureItem("Put This Side on the Bed") { [weak self] in self?.putDown() })
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
            menu.addItem(place)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Smart Placement") { [weak self] in self?.plateAction(zs_app_plate_smart_place) })
        menu.addItem(ClosureItem("Arrange the Plate") { [weak self] in self?.plateAction(zs_app_plate_arrange) })
        menu.addItem(ClosureItem("Add Models…") { [weak self] in self?.addModels() })
        menu.addItem(ClosureItem("Clear the Plate") { [weak self] in self?.plateAction(zs_app_plate_clear) })
        if zs_app_mark_count(model.core) > 0 {
            menu.addItem(ClosureItem("Clear All Support Marks") { [weak self] in
                guard let self else { return }
                zs_app_marks_clear(model.core)
                model.settingsChanged()
            })
        }
        if selection != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureItem("Copy for AI") { [weak self] in self?.copyForAI() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Reset the View") { [weak self] in
            guard let self, let v = canvas.view else { return }
            zs_view_reset_smooth(v)
            canvas.startAnimation()
        })
        return menu
    }

    /// The place of a support mark: the middle of the selected segment,
    /// at the z of its layer.
    private func markPlace() -> (x: Double, y: Double, z: Double)? {
        guard let s = selection else { return nil }
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0, s.path < tp.path_count, let ends = tp.path_ends, let pts = tp.points else { return nil }
        let a = s.path == 0 ? 0 : Int(ends[s.path - 1]), b = Int(ends[s.path])
        guard b > a else { return nil }
        let i = s.seg >= 0 && a + s.seg + 1 < b ? a + s.seg : a + (b - a) / 2 - (b - a > 1 ? 1 : 0)
        let j = i + 1 < b ? i + 1 : i
        var layer = 0
        while layer < tp.layer_count && Int(tp.layer_ends[layer]) <= s.path { layer += 1 }
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
        drawerPage = .settings
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
    func plateAction(_ action: (OpaquePointer?) -> Int32) {
        guard action(model.core) == 0 else { return }
        clearSelection()
        model.settingsChanged()
    }

    private func addMark(_ kind: Int32) {
        guard let m = markPlace() else { return }
        if zs_app_mark_add(model.core, m.x, m.y, m.z, 3, kind) == 0 { model.settingsChanged() }
    }

    private func removeMarks() {
        guard let m = markPlace() else { return }
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
