//! The filaments of the plate (src/app/filament_slots.zig,
//! web/app/filaments.js). Filament 1 is the filament of the settings; each
//! other one has its own material, color, and temperatures. A part or a
//! range of layers prints with filament k when its setting
//! project.filament is k (zs_app_part_setting_set, zs_app_override_set),
//! and the G-code changes the filament there.
//!
//! The list and the grams of each filament come from the core: after each
//! slice (the stats change) and after each change of the list (the
//! settings generation changes), the views read them again.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation

/// One filament of the plate. index: from 0 (filament 1 on the screen).
struct FilamentSlot: Identifiable, Equatable {
    var index: Int
    var name: String
    var material: String
    var color: String
    var id: Int { index }
}

/// The filament of the last slice: grams of each filament, the changes,
/// and the grams of all flushes.
struct FilamentStats: Equatable {
    var grams: [Double]
    var changes: Int
    var flushG: Double
}

extension Workspace {
    /// The printer of the active plate: its own, or the printer of the
    /// toolbar.
    var platePrinter: Printer? { assigned(plate: model.active) ?? PrinterStore.shared.current }

    /// Makes the filaments of the plate the spools that printer `p` has
    /// loaded: the same count (filaments added or removed at the end),
    /// then the material (upper case) and the color of each, in the order
    /// of the printer. Filament k prints from its spool k: the deck maps
    /// them at the start of the print. The spools of a second nozzle
    /// ("nozzle": "aux") stay out. Returns the words for a note.
    func useLoadedFilaments(_ p: Printer) async -> String {
        let r = await PrinterLink.loadedFilaments(p)
        guard let all = r.list else { return r.why }
        // zslice prints with one nozzle (next_hotend is 0 in the change
        // G-code). A spool of the second nozzle stays out, or a change
        // would ask for it in the main nozzle.
        let aux = all.filter { $0.nozzle == "aux" }
        let want = Array(all.filter { $0.nozzle != "aux" }.prefix(16))
        if want.isEmpty { return "The spools of \(p.name) feed its second nozzle only. zslice prints with the main nozzle: load a spool in the AMS." }
        var have = model.filaments.count
        while have < want.count, model.addFilament() != nil { have += 1 }
        while have > want.count {
            model.removeFilament(have - 1)
            have -= 1
        }
        for (k, f) in want.prefix(have).enumerated() {
            model.setFilament(k, "filament.material", f.material.uppercased())
            if f.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { model.setFilament(k, "filament.color", f.color) }
        }
        let words = want.map { "\($0.slot.isEmpty ? "roll" : $0.slot) \($0.material)" }.joined(separator: ", ")
        let skipped = aux.isEmpty ? "" : " Not used: " + aux.map { "\($0.slot.isEmpty ? "spool" : $0.slot) \($0.material)" }.joined(separator: ", ")
            + " (the second nozzle; zslice prints with the main nozzle)."
        return "\(want.count) \(want.count == 1 ? "filament" : "filaments") from \(p.name): \(words).\(skipped)"
    }
}

extension SliceModel {
    /// The materials that the list offers.
    static let filamentKinds = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA"]

    var filaments: [FilamentSlot] {
        _ = settingsGeneration
        _ = stats
        let app = core
        func get(_ i: Int, _ name: String) -> String {
            coreString { zs_app_filament_get(app, i, name, $0, $1, $2) } ?? ""
        }
        return (0 ..< zs_app_filament_count(app)).map { i in
            FilamentSlot(index: i, name: get(i, "filament.name"), material: get(i, "filament.material"), color: get(i, "filament.color"))
        }
    }

    var filamentStats: FilamentStats? {
        _ = stats
        let app = core
        let n = min(zs_app_filament_count(app), 16)
        var grams = [Double](repeating: 0, count: 16)
        var changes: UInt32 = 0
        var flush = 0.0
        guard zs_app_filament_stats(app, &grams, 16, &changes, &flush) == 0 else { return nil }
        return FilamentStats(grams: Array(grams.prefix(n)), changes: Int(changes), flushG: flush)
    }

    /// A new filament (a copy of filament 1 with a new color). Its index,
    /// or nil.
    @discardableResult
    func addFilament() -> Int? {
        var i = 0
        guard zs_app_filament_add(core, &i) == 0 else { return nil }
        settingsChanged()
        return i
    }

    /// Removes filament i (from 1). Its parts and layers print with
    /// filament 1.
    func removeFilament(_ i: Int) {
        guard i >= 1, zs_app_filament_remove(core, i) == 0 else { return }
        settingsChanged()
    }

    /// A value of filament i ("filament.color"). nil, or why it failed.
    @discardableResult
    func setFilament(_ i: Int, _ name: String, _ value: String) -> String? {
        let rc = zs_app_filament_set(core, i, name, value)
        guard rc == 0 else { return "The value is not valid." }
        settingsChanged()
        return nil
    }
}
