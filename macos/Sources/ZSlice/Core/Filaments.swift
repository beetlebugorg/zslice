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
