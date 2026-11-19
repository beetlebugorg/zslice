//! The print as it forms (web/app/app.js, toggleSimulation): the core
//! simulates the plastic of the last slice (zs_app_simulate_print). The
//! plastic falls where nothing holds it, sags, cools, and sets, and the
//! view shows it in place of the planned lines. In a replay the toolhead
//! follows the plan while the plastic falls. A new slice shows the plan
//! again.
//!
//! The simulation runs on the main thread (about 1.5 s for a 3DBenchy), as
//! smart placement does: the window shows a note first. The details then
//! say where the print fails, or how far the plastic droops
//! (zs_app_sim_stats), in place of the estimate from the area that hangs
//! in the air.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import QuartzCore

/// The numbers of a simulated print that the window shows.
struct SimResult {
    var moved: Int, movedPaths: Int
    var maxMove: Double
    var failed: Int
    var firstFailedLayer: Int
    var maxDrop: Double
    var materialExact: Bool
    var material: String

    init(_ s: zs_print_sim_stats) {
        moved = s.moved
        movedPaths = s.moved_paths
        maxMove = Double(s.max_move)
        failed = s.failed
        firstFailedLayer = s.first_failed_layer
        maxDrop = Double(s.max_drop)
        materialExact = s.material_exact != 0
        var m = s.material
        material = withUnsafeBytes(of: &m) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Where the print fails, or how far it droops; nil if the plastic
    /// stays where it prints.
    var checkText: String? {
        let as_ = materialExact ? "" : " (simulated as \(material): the simulation has no data for this plastic)"
        if failed > 0, firstFailedLayer >= 0 { return "The print fails at layer \(firstFailedLayer + 1): the plastic over air falls\(as_). " }
        if maxDrop > 0.5 { return String(format: "The plastic droops up to %.1f mm where nothing holds it", maxDrop) + as_ + ". " }
        return nil
    }
}

extension Workspace {
    /// Shows the print as it forms, or the plan again.
    func toggleSimulation() {
        guard !busy else { return }
        if simulated {
            zs_app_show_simulated(model.core, 0)
            simulated = false
            reloadToolpaths()
            return
        }
        guard model.state == .done else {
            showNote("Slice first: the simulation needs a slice.")
            return
        }
        busy = true
        showNote("Simulating the plastic of the print…", seconds: 60)
        Task { @MainActor in
            // Two frames, so the note draws before the wait.
            try? await Task.sleep(for: .milliseconds(80))
            defer { busy = false }
            let t = CACurrentMediaTime()
            var s = zs_print_sim_stats()
            let rc = zs_app_simulate_print(model.core, &s)
            if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
                NSLog("zslice timing: simulated print %.0f ms", (CACurrentMediaTime() - t) * 1000)
            }
            guard rc == 0, zs_app_show_simulated(model.core, 1) == 0 else {
                showNote("The simulation did not run. \(statusText(rc))")
                return
            }
            let r = SimResult(s)
            simulated = true
            simResult = r
            if ProcessInfo.processInfo.environment["ZSLICE_SIM"] != nil {
                NSLog("zslice sim: moved %ld in %ld paths, max %.1f mm, failed %ld from layer %ld, drop %.1f mm, %@: %@",
                      r.moved, r.movedPaths, r.maxMove, r.failed, r.firstFailedLayer, r.maxDrop, r.material, r.checkText ?? "no hint")
            }
            reloadToolpaths()
            showNote(r.moved > 0
                ? String(format: "The plastic of %d lines does not stay where it prints: up to %.1f mm off. Turn on support, or change the turn of the part.", r.movedPaths, r.maxMove)
                : "All the plastic stays where it prints.", seconds: 8)
        }
    }

    /// The view draws the toolpaths of the core again (the plan or the
    /// simulated plastic), with the same layers.
    private func reloadToolpaths() {
        stopReplay()
        canvas.load(model.core)
        if let v = canvas.view { PrinterLibrary.shared.showBed(of: model.core, in: v) }
        readLegend()
        applyRange()
        showSelection()
    }
}
