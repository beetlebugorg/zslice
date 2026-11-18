//! Refinements (src/app/refine.zig): the first slice is a guide, and the
//! user refines it. After each slice, the window gives the refinements of
//! the plate (zs_app_refine_records) to a store of the app, under an id of
//! the plate's project (zs_refine_merge). The core then finds the
//! refinements that the user made in two or more other projects with the
//! same material and nozzle (zs_app_refine_suggest). The details of the
//! print offer them, each with Apply (one history step,
//! zs_app_refine_apply) and a button that hides it for good.
//!
//! The store is a text file in Application Support/zslice (refine.txt):
//! it stays on the device. The hidden suggestions are in refine-hidden.json.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation
import QuartzCore

/// A suggestion: its line for zs_app_refine_apply, its words, and the
/// number of other projects with it.
struct Refinement: Identifiable, Equatable {
    var id: String { line }
    var line: String
    var whereText: String
    var what: String
    var count: Int
}

@MainActor
enum RefineStore {
    private static var folder: URL { SavedSettings.folder }
    private static let fresh = ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil
        && ProcessInfo.processInfo.environment["ZSLICE_REFINE"] == nil
    private static var memory = ""

    private static var file: URL {
        if let f = ProcessInfo.processInfo.environment["ZSLICE_REFINE"] { return URL(fileURLWithPath: f) }
        return folder.appendingPathComponent("refine.txt")
    }

    private static var hiddenFile: URL { file.deletingLastPathComponent().appendingPathComponent("refine-hidden.json") }

    static var store: String {
        get { fresh ? memory : ((try? String(contentsOf: file, encoding: .utf8)) ?? "") }
        set {
            if fresh {
                memory = newValue
                return
            }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? newValue.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static var hidden: Set<String> {
        get { (try? Data(contentsOf: hiddenFile)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? [] }
        set {
            guard !fresh, let d = try? JSONEncoder().encode(newValue) else { return }
            try? d.write(to: hiddenFile, options: .atomic)
        }
    }
}

/// A C call with a string and its length.
private func withBytes<R>(_ s: String, _ body: (UnsafePointer<CChar>, Int) -> R) -> R {
    s.withCString { body($0, strlen($0)) }
}

extension Workspace {
    /// The id of the project of the active plate in the store: one id for
    /// each plate, kept with the session.
    var refineProject: String {
        let key = String(model.plates.indices.contains(model.active) ? model.plates[model.active].id : 0)
        if let id = refineIDs[key] { return id }
        let id = UUID().uuidString
        refineIDs[key] = id
        return id
    }

    /// After a slice: the records of the plate go to the store, and the
    /// suggestions come back (0.8 s after the last slice).
    func refreshRefinementsSoon() {
        refineTask?.cancel()
        refineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, model.state == .done else { return }
            refreshRefinements()
        }
    }

    func refreshRefinements() {
        let t = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil { NSLog("zslice timing: refinements %.1f ms", (CACurrentMediaTime() - t) * 1000) }
        }
        let core = model.core
        let project = refineProject
        let records = coreString { zs_app_refine_records(core, $0, $1, $2) } ?? ""
        let store = RefineStore.store
        let merged = withBytes(store) { sp, sn in
            project.withCString { pp in
                withBytes(records) { rp, rn in
                    coreString { zs_refine_merge(sp, sn, pp, rp, rn, $0, $1, $2) }
                }
            }
        } ?? store
        if merged != store { RefineStore.store = merged }
        let text = withBytes(merged) { sp, sn in
            project.withCString { pp in coreString { zs_app_refine_suggest(core, sp, sn, pp, $0, $1, $2) } }
        } ?? ""
        let hidden = RefineStore.hidden
        refinements = text.split(separator: "\n").compactMap { line -> Refinement? in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, !hidden.contains(String(line)) else { return nil }
            let (kind, key, value, lo, hi) = (f[0], f[2], f[3], f[5], f[6])
            // The words of the change, as the history writes them.
            let scope = kind == "layers" ? "layers:\(lo):\(hi)" : kind == "part" ? "part:each part" : "print"
            let change = "\(scope)\t\(key)\t\t\(value)\n"
            let words = withBytes(change) { cp, cn in coreString { zs_app_history_describe(core, cp, cn, $0, $1, $2) } } ?? ""
            let parts = words.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 1).map(String.init)
            return Refinement(line: String(line), whereText: parts.first ?? "", what: parts.count > 1 ? parts[1] : key, count: Int(f[4]) ?? 0)
        }
        if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil || ProcessInfo.processInfo.environment["ZSLICE_REFINE"] != nil {
            NSLog("zslice refine: %d records, %d suggestions", records.split(separator: "\n").count, refinements.count)
        }
        // For tests: ZSLICE_DETAILS=1 opens the details, and
        // ZSLICE_REFINE_APPLY=1 applies the first suggestion once.
        let env = ProcessInfo.processInfo.environment
        if env["ZSLICE_DETAILS"] != nil { detailsOpen = true }
        if env["ZSLICE_REFINE_APPLY"] != nil, !refineApplied, let r = refinements.first {
            refineApplied = true
            applyRefinement(r)
            NSLog("zslice refine: applied %@, wall count %@, undo %@", r.what, model.setting("project.wall_count"), model.history.undoManager.undoMenuItemTitle)
        }
    }

    /// Applies a suggestion: one step of the history, and a new slice.
    func applyRefinement(_ r: Refinement, refresh: Bool = true) {
        let rc = withBytes(r.line) { zs_app_refine_apply(model.core, $0, $1) }
        guard rc == 0 else {
            showNote("The refinement did not apply. \(statusText(rc))")
            return
        }
        refinements.removeAll { $0 == r }
        model.history.commit()
        model.settingsChanged()
        showNote("Applied: \(r.what). Undo removes it.")
        if refresh { refreshRefinementsSoon() }
    }

    /// Never offers this suggestion again.
    func hideRefinement(_ r: Refinement) {
        var h = RefineStore.hidden
        h.insert(r.line)
        RefineStore.hidden = h
        refinements.removeAll { $0 == r }
    }
}
