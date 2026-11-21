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
    /// The nozzle (filament.nozzle): 0 the main one, 1 the second.
    var nozzle = 0
    /// The values come from a spool of the printer (source.printer).
    var fromPrinter = false
    /// The user set a value by hand (source.hand): it stays when the
    /// printer has other spools.
    var hand = false
    /// The tray of its spool (source.tray), -1 for none, and its holder
    /// ("A1", "Ext", or "").
    var tray = -1
    var slot = ""
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
    /// them at the start of the print. A spool of a second nozzle ("nozzle":
    /// "aux") prints on that nozzle on a printer with two nozzles
    /// (machine.nozzles), and stays out on one with one. Returns the words
    /// for a note.
    func useLoadedFilaments(_ p: Printer) async -> String {
        let r = await PrinterLink.loadedFilaments(p)
        guard let json = r.json, r.list != nil else { return r.why }
        // The core makes the filaments of the plate the spools of the
        // printer (and keeps a filament set by hand only without flag 1).
        var words = fromPrinter(p, json, flags: 1)
        // The nozzle that the printer has (both nozzles of an X2D are the
        // same kind): the type and the flow of its file.
        if let nz = r.nozzles.lazy.compactMap(PrinterLink.nozzleOfCode).first {
            model.set("machine.nozzle_type", nz.type)
            model.set("machine.nozzle_flow", nz.flow)
            words += " Nozzles: \(nz.type.replacingOccurrences(of: "_", with: " ")), \(nz.flow.replacingOccurrences(of: "_", with: " "))."
        }
        return words
    }

    /// The spools of a printer on the filaments of the plate
    /// (zs_app_filaments_from_printer): `json` is the reply of a printdeck,
    /// or the list of zs_printer_status_filaments. flags 1: "Use the
    /// printer's filament", also over a filament set by hand; flags 2: the
    /// automatic follow. Returns the words of the core, and slices again
    /// when a filament changed.
    @discardableResult
    func fromPrinter(_ p: Printer, _ json: Data, flags: Int32) -> String {
        var changed: Int32 = 0
        var message = [CChar](repeating: 0, count: 1024)
        let rc = json.withUnsafeBytes { b in
            zs_app_filaments_from_printer(model.core, p.name, b.bindMemory(to: CChar.self).baseAddress, b.count, flags, &changed, &message, message.count)
        }
        let words = message.withUnsafeBufferPointer { coreText($0.baseAddress) }
        if changed == 1 { model.settingsChanged() }
        if rc != 0, words.isEmpty { return "\(p.name) tells no spool for this plate." }
        return words
    }

    /// The automatic follow of the spools: the spools in a status object
    /// of the printer of the plate (zs_printer_status_filaments), with
    /// flags 2. A note says what changed.
    func followSpools(_ p: Printer, status s: OpaquePointer) {
        guard let text = coreString({ zs_printer_status_filaments(s, $0, $1, $2) }), !text.isEmpty else { return }
        var changed: Int32 = 0
        var message = [CChar](repeating: 0, count: 1024)
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { b in
            zs_app_filaments_from_printer(model.core, p.name, b.bindMemory(to: CChar.self).baseAddress, b.count, 2, &changed, &message, message.count)
        }
        guard changed == 1 else { return }
        model.settingsChanged()
        let words = message.withUnsafeBufferPointer { coreText($0.baseAddress) }
        if !words.isEmpty { showNote(words, seconds: 6) }
    }

    /// The spools of the printer of the plate now: after a change of the
    /// printer of the plate.
    func followSpoolsNow() {
        guard let p = platePrinter, p.kind == .printdeck || p.kind == .bambu else { return }
        Task { @MainActor in
            guard let s = await PrinterLink.statusObject(p) else { return }
            defer { zs_printer_status_free(s) }
            followSpools(p, status: s)
        }
    }
}

extension SliceModel {
    /// The nozzles of the printer (machine.nozzles): 2 on an X2D.
    var nozzleCount: Int {
        _ = settingsGeneration
        return max(Int(Double(setting("machine.nozzles")) ?? 1), 1)
    }

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
            FilamentSlot(index: i, name: get(i, "filament.name"), material: get(i, "filament.material"), color: get(i, "filament.color"),
                         nozzle: Int(Double(get(i, "filament.nozzle")) ?? 0), fromPrinter: get(i, "source.printer") == "1",
                         hand: get(i, "source.hand") == "1", tray: Int(get(i, "source.tray")) ?? -1, slot: get(i, "source.slot"))
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
