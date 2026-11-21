//! Calibration prints and the import of the profiles of other slicers
//! (src/app/calibrate.zig, src/app/profile_import.zig), as the web app has
//! them.
//!
//! A calibration puts its test part on a new plate (zs_app_calibration_add):
//! a temperature tower, a retraction test, a row of flow cubes, or a
//! pressure advance tower. Its card says how to read the print, and has a
//! button for each step that sets the value of the step on each plate.
//!
//! "Import a profile…" reads a PrusaSlicer, OrcaSlicer, Bambu Studio, or
//! Cura profile (zs_app_profile_import): its values become changes of the
//! settings, as one step of the history. A report shows what zslice set,
//! what went into the limits of a setting, and what it did not import.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI
import UniformTypeIdentifiers

/// The calibration of a plate (zs_app_calibration_get).
struct CalibrationInfo: Identifiable {
    var id: String { name }
    var name: String
    var setting: String
    var note: String
    var steps: [(text: String, value: String)]

    /// The tests of the Calibrate menu: the kind (enum zs_calibration),
    /// the name, and what it prints.
    static let kinds: [(kind: Int32, name: String, tip: String)] = [
        (0, "Temperature Tower", "A block for each nozzle temperature of the material"),
        (1, "Retraction Test", "Two pillars: a retraction length for each band"),
        (2, "Flow Test", "A row of cubes, each with its own flow"),
        (3, "Pressure Advance Tower", "Thin walls with sharp corners: a pressure advance for each band"),
    ]
}

/// The report of an import (zs_app_profile_import_report).
struct ImportReport: Identifiable {
    var id: String { file }
    var file: String
    var rows: [[String]]
}

extension Workspace {
    /// The calibration of the active plate, or nil.
    func calibrationOfPlate() -> CalibrationInfo? {
        guard let text = coreString({ zs_app_calibration_get(model.core, $0, $1, $2) }) else { return nil }
        var c = CalibrationInfo(name: "", setting: "", note: "", steps: [])
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "name": c.name = f.count > 1 ? f[1] : ""
            case "setting": c.setting = f.count > 1 ? f[1] : ""
            case "note": c.note = f.count > 1 ? f[1] : ""
            case "step" where f.count > 2: c.steps.append((f[1], f[2]))
            default: break
            }
        }
        return c.setting.isEmpty ? nil : c
    }

    /// A calibration test on a new plate, then its card. The plate goes
    /// again when the test does not load.
    func calibrate(_ kind: Int32) {
        let from = model.active
        model.addPlate()
        let rc = zs_app_calibration_add(model.core, kind)
        guard rc == 0 else {
            model.removePlate(model.active)
            model.select(from)
            showNote(rc == ZS_INVALID_SETTINGS.rawValue ? "The retraction test needs a retraction length (machine.retract_length)." : "The test did not load. \(statusText(rc))")
            return
        }
        let cal = calibrationOfPlate()
        if let n = cal?.name, !n.isEmpty { zs_set_name(model.set, model.active, n) }
        model.readPlates()
        model.settingsChanged()
        framePlate(model.active)
        calibration = cal
    }

    /// The card of the test of the active plate.
    func showCalibration() {
        guard let c = calibrationOfPlate() else {
            showNote("This plate has no calibration test. Open File > Calibrate to make one.")
            return
        }
        calibration = c
    }

    /// A value of the test on each plate.
    func useCalibration(_ setting: String, _ value: String) {
        var error = ""
        for i in 0 ..< model.plates.count {
            guard let app = zs_set_app(model.set, i) else { continue }
            let rc = zs_app_setting_set(app, setting, value)
            if rc == 0 { zs_set_changed(model.set, i) } else { error = statusText(rc) }
        }
        model.settingsChanged()
        showNote(error.isEmpty ? "\(SettingInfo.byName[setting]?.label ?? setting) is \(value) now." : "The value did not set. \(error)")
    }

    /// Import a Profile…: an open panel, the import, and its report.
    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ini", "json", "3mf", "curaprofile", "cfg", "gcode"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "A PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura profile"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        let rc = data.withUnsafeBytes { zs_app_profile_import(model.core, name, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard rc == 0 else {
            showNote(rc == ZS_INVALID_VALUE.rawValue ? "\(name) is not a profile that zslice reads." : "The profile did not import. \(statusText(rc))")
            return
        }
        model.settingsChanged()
        let rows = (coreString { zs_app_profile_import_report(model.core, $0, $1, $2) } ?? "")
            .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        importReport = ImportReport(file: name, rows: rows)
    }

    /// One part at a time (project.print_sequence = by_object): the place
    /// of part i in the print order, and the count of parts; nil else.
    func printOrder(_ i: Int) -> (index: Int, count: Int)? {
        _ = model.settingsGeneration
        let n = zs_app_part_count(model.core)
        guard model.setting("project.print_sequence") == "by_object", n >= 2, i < n else { return nil }
        return (i, n)
    }

    /// Part i prints one place earlier (-1) or later (+1).
    func reorderPart(_ i: Int, by d: Int) {
        let n = zs_app_part_count(model.core)
        let to = i + d
        guard to >= 0, to < n, zs_app_part_reorder(model.core, i, to) == 0 else { return }
        selectOnlyPart(to)
        model.settingsChanged()
    }
}

/// The card of a calibration test: how to read the print, and a button
/// for each step.
struct CalibrationSheet: View {
    let workspace: Workspace
    let cal: CalibrationInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cal.name).font(.title3.weight(.semibold))
            Text(cal.note).fixedSize(horizontal: false, vertical: true)
            Text("Pick the step that printed best: its value goes on each plate.").font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Array(cal.steps.enumerated()), id: \.offset) { _, st in
                    Button("Use \(st.text)") {
                        workspace.useCalibration(cal.setting, st.value)
                        dismiss()
                    }
                    .help("Set \(cal.setting) to \(st.value) on each plate")
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// The report of an import: the values that zslice set, the values that
/// went into the limits of a setting, and the keys that it did not import.
struct ImportReportSheet: View {
    let report: ImportReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = report.rows
        let format = rows.first { $0.first == "format" }.flatMap { $0.count > 1 ? $0[1] : nil } ?? "Profile"
        VStack(alignment: .leading, spacing: 10) {
            Text("\(format): \(report.file)").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Set", rows.filter { $0.first == "set" || $0.first == "near" }) { r in
                        ["\(at(r, 1)) = \(at(r, 2))", "\(at(r, 3)) = \(at(r, 4))", r.first == "near" ? at(r, 5) : ""]
                    }
                    section("Clamped to the limits of the setting", rows.filter { $0.first == "clamp" }) { r in
                        ["\(at(r, 1)) = \(at(r, 2))", "\(at(r, 3)) = \(at(r, 4))", "wanted \(at(r, 5))"]
                    }
                    section("Not imported", rows.filter { $0.first == "unused" }) { r in
                        ["\(at(r, 1)) = \(at(r, 2))", at(r, 3), ""]
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }

    private func at(_ r: [String], _ i: Int) -> String { i < r.count ? r[i] : "" }

    @ViewBuilder
    private func section(_ title: String, _ list: [[String]], _ cells: @escaping ([String]) -> [String]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(title) (\(list.count))").font(.headline)
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(Array(cells(r).enumerated()), id: \.offset) { _, c in
                                Text(c).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}
