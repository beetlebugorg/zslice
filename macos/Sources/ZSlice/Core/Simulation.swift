//! The print as it forms (web/app/app.js, toggleSimulation): the core
//! simulates the plastic of the last slice (zs_app_simulate_print). The
//! plastic falls where nothing holds it, sags, cools, and sets, and the
//! view shows it in place of the planned lines. In a replay the toolhead
//! follows the plan while the plastic falls. A new slice shows the plan
//! again until its simulation is ready.
//!
//! The core simulates the print after each slice of the active plate, on
//! the thread of the slice (zs_app_set_auto_simulate), and a change stops
//! it. On ZS_EVENT_SIMULATED the toolpaths take the result
//! (zs_app_sim_adopt), and the view loads it. The details then say where
//! the print fails, or how far the plastic droops (zs_app_sim_stats), in
//! place of the estimate from the area that hangs in the air. The colors
//! popover has Show the Plan while the simulated plastic shows, and Show
//! the Print as It Forms while the plan shows.
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
    /// The simulation of the slice is ready (the slice thread ran it): the
    /// view shows the plastic as it set, and the details give the hint.
    func simulatedReady() {
        simulated = true
        readSimResult()
        reloadToolpaths()
    }

    private func readSimResult() {
        var s = zs_print_sim_stats()
        simResult = zs_app_sim_stats(model.core, &s) == 0 ? SimResult(s) : nil
        if ProcessInfo.processInfo.environment["ZSLICE_SIM"] != nil, let r = simResult {
            NSLog("zslice sim: moved %ld in %ld paths, max %.1f mm, failed %ld from layer %ld, drop %.1f mm, %@: %@, %.0f ms after the slice",
                  r.moved, r.movedPaths, r.maxMove, r.failed, r.firstFailedLayer, r.maxDrop, r.material, r.checkText ?? "no hint",
                  (CACurrentMediaTime() - slicedAt) * 1000)
        }
    }

    /// Shows the plan, or the print as it forms again: the simulation that
    /// is there, else a new one on this thread.
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
        if zs_app_show_simulated(model.core, 1) == 0 {
            simulatedReady()
            return
        }
        busy = true
        showNote("Simulating the plastic of the print…", seconds: 60)
        Task { @MainActor in
            // Two frames, so the note draws before the wait.
            try? await Task.sleep(for: .milliseconds(80))
            defer { busy = false }
            let rc = zs_app_simulate_print(model.core, nil)
            guard rc == 0, zs_app_show_simulated(model.core, 1) == 0 else {
                showNote("The simulation did not run. \(statusText(rc))")
                return
            }
            showNote("The print as it forms.", seconds: 2)
            simulatedReady()
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
        relightRange()
    }
}
