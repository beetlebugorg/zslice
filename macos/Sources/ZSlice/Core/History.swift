//! History: the undo list of a plate, on the UndoManager of macOS.
//!
//! The core keeps the list (src/app/history.zig): each change through the
//! C API notes its key, and zs_app_history_commit makes a step of the
//! changes so far. The shell only keeps the timer: it commits 400 ms after
//! the last change, and it tells the core which setting editor has the
//! focus, so an edit of one setting is one step.
//!
//! The UndoManager mirrors the list. Each step before the step now is one
//! undo action, and each step after it one redo action. An undo action
//! calls zs_app_history_undo and registers the redo action, as AppKit
//! expects. So Edit > Undo, Edit > Redo, and their menu titles ("Undo
//! Infill") are those of a Mac app. A jump in the timeline to step i runs
//! the undo or redo actions up to i, so both lists stay right. When the
//! list of the core changes in another way (a step amended or dropped, or
//! the history cleared after a step), the undo actions are made again.
//!
//! After an undo, a redo, or a jump, the core gives the bits of what it
//! restored (enum zs_history_restored). The editors then read the values
//! again, and the plate slices again.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Observation
import SwiftUI

@MainActor
@Observable
final class History {
    @ObservationIgnored let undoManager: UndoManager = {
        let u = UndoManager()
        u.groupsByEvent = false
        u.levelsOfUndo = 0
        return u
    }()
    @ObservationIgnored private unowned let model: SliceModel
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// The undo actions on the UndoManager: the steps before the step now
    /// that it mirrors.
    @ObservationIgnored private var undoActions = 0

    /// Counts the changes of the list, so the views read it again.
    private(set) var generation = 0

    init(model: SliceModel) {
        self.model = model
    }

    private var core: OpaquePointer { model.core }
    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var count: Int { _ = generation; return zs_app_history_count(core) }
    var current: Int { _ = generation; return zs_app_history_current(core) }

    // MARK: - the timer and the focus

    /// A change went to the core: the step comes 400 ms after the last one.
    func noteChange() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    /// Ends the step of the changes so far.
    func commit() {
        timer?.cancel()
        timer = nil
        let before = current
        if zs_app_history_commit(core, now) != 0 {
            listChanged(from: before)
            if ProcessInfo.processInfo.environment["ZSLICE_FRESH"] == nil { SavedSettings.save(from: core) }
        }
    }

    /// The setting whose editor has the focus (nil: none).
    func setFocus(_ key: String?) {
        let before = current
        if zs_app_history_set_focus(core, key, now) != 0 { listChanged(from: before) }
    }

    /// After a commit: a new step is one more undo action. Any other
    /// change of the list makes the undo actions again.
    private func listChanged(from before: Int) {
        let after = current
        if after == before + 1 && undoActions == before {
            register()
        } else {
            rebuild()
        }
        generation += 1
    }

    // MARK: - the UndoManager

    private func register() {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.undoStep() }
        undoManager.setActionName(label(of: current))
        undoManager.endUndoGrouping()
        undoActions += 1
    }

    /// Makes the undo actions again: one for each step before the step now.
    /// The redo actions go (the core keeps its redo steps, and a jump in
    /// the timeline still reaches them).
    private func rebuild() {
        undoManager.removeAllActions()
        undoActions = 0
        for _ in 0 ..< current { register() }
    }

    private func undoStep() {
        let name = label(of: current)
        applied(zs_app_history_undo(core, now))
        undoActions -= 1
        undoManager.registerUndo(withTarget: self) { $0.redoStep() }
        undoManager.setActionName(name)
    }

    private func redoStep() {
        applied(zs_app_history_redo(core, now))
        undoActions += 1
        undoManager.registerUndo(withTarget: self) { $0.undoStep() }
        undoManager.setActionName(label(of: current))
    }

    private func applied(_ bits: Int32) {
        generation += 1
        if bits != 0, ProcessInfo.processInfo.environment["ZSLICE_FRESH"] == nil { SavedSettings.save(from: core) }
        if bits != 0 { model.restored() }
    }

    // MARK: - the timeline

    /// Goes to step i: the undo or redo actions up to it.
    func go(to i: Int) {
        commit()
        while current > i && undoManager.canUndo { undoManager.undo() }
        while current < i && undoManager.canRedo { undoManager.redo() }
        // The redo actions went (a rebuild): the core jumps the rest.
        if current != i {
            applied(zs_app_history_goto(core, i, now))
            rebuild()
        }
    }

    /// Clears the history after step i (redo cannot bring it back).
    func truncate(after i: Int) {
        commit()
        applied(zs_app_history_truncate(core, i, now))
        rebuild()
    }

    /// Undoes one change of a step and keeps the later changes: a new step.
    func revert(_ line: String) -> String? {
        let rc = line.withCString { zs_app_history_revert(core, $0, strlen($0)) }
        guard rc == 0 else { return rc == ZS_NOT_SUPPORTED.rawValue ? "This change cannot be undone alone." : statusText(rc) }
        model.settingsChanged()
        return nil
    }

    // MARK: - the steps

    struct Step: Identifiable {
        let id: Int
        let time: Date
        let kind: String
        /// The change lines (zs_history_diff), and the same in words
        /// ("scope\twords"), one for each change.
        let changes: [String]
        let words: [String]
    }

    func step(_ i: Int) -> Step? {
        _ = generation
        var s = zs_history_step()
        guard zs_app_history_step(core, i, &s) == 0 else { return nil }
        func text(_ p: UnsafePointer<CChar>?, _ n: Int) -> String {
            guard let p, n > 0 else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
        }
        let lines = { (t: String) in t.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
        return Step(id: i, time: Date(timeIntervalSince1970: Double(s.time_ms) / 1000), kind: coreText(s.kind),
                    changes: lines(text(s.changes, s.changes_len)), words: lines(text(s.text, s.text_len)))
    }

    /// The name of step i for the Edit menu ("Undo Infill").
    private func label(of i: Int) -> String {
        guard i > 0, let s = step(i) else { return "" }
        return Self.look(s.kind).label
    }

    /// The look of each kind of step (linux/src/ui/history.c).
    static func look(_ kind: String) -> (color: Color, label: String) {
        let looks: [String: (UInt32, String)] = [
            "walls": (0xd9480f, "Walls"), "infill": (0x2b8a3e, "Infill"), "surface": (0x1c7ed6, "Top and Bottom"),
            "speed": (0x7c3aed, "Speed"), "heat": (0xdc2626, "Temperature and Cooling"), "support": (0x6b7280, "Support"),
            "layers": (0xd99000, "Layers"), "move": (0x0c949e, "Move"), "rotate": (0x0c949e, "Turn"),
            "scale": (0x0c949e, "Scale"), "add": (0x0c949e, "Part Added"), "remove": (0x0c949e, "Part Removed"),
            "quality": (0xdb2777, "Quality"), "printer": (0x334155, "Printer"), "start": (0x808080, "Start"),
        ]
        let (rgb, label) = looks[kind] ?? (0x808080, "Other")
        return (Color(red: Double(rgb >> 16 & 0xff) / 255, green: Double(rgb >> 8 & 0xff) / 255, blue: Double(rgb & 0xff) / 255), label)
    }

    /// A change that can be undone alone (the rule is in the core).
    static func revertible(_ line: String) -> Bool {
        line.withCString { zs_history_revertible($0, strlen($0)) != 0 }
    }
}
