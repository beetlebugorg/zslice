//! The project file: all the plates of a window in one .3mf
//! (zs_set_project_save, zs_set_project_open). It has the parts of each
//! plate, their places and settings, the layer profiles, and the printer,
//! filament, and print settings of each plate. Other slicers open its
//! first plate.
//!
//! The document of the window (ProjectDocument in ZSliceApp.swift) saves
//! it: File > Save, Save As, Duplicate, Revert, Versions, and autosave are
//! those of macOS. An open of a .3mf first asks the core if it is a project
//! file (zs_project_file_is); else the file opens as a model.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import UniformTypeIdentifiers

/// The bytes of the project file for a save, shared with the thread of
/// the save: nil while there is a change after the last copy.
final class SaveBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    /// The change that the bytes show, and the last change.
    private var gen = 0, changes = 0
    /// A save wrote bytes older than the last change.
    private var staleSave = false

    var current: Data? { lock.withLock { data } }
    func set(_ d: Data?) { lock.withLock { data = d; gen = changes } }
    func changed() { lock.withLock { changes += 1 } }
    /// The count of the changes now, for a copy made on another thread.
    var changeCount: Int { lock.withLock { changes } }
    /// A copy that shows the plates as they were at change `at`.
    func set(_ d: Data?, at: Int) { lock.withLock { data = d; gen = at } }

    /// The copy runs on this queue (the core reads the set under its lock).
    static let queue = DispatchQueue(label: "zslice.savebytes", qos: .utility)

    /// The bytes for a save (any thread). It notes a save of old bytes.
    func forSave() -> Data? {
        lock.withLock {
            if gen < changes { staleSave = true }
            return data
        }
    }

    /// True once after a save of old bytes.
    func takeStaleSave() -> Bool {
        lock.withLock {
            defer { staleSave = false }
            return staleSave
        }
    }
}

extension SliceModel {
    /// After a change: a new copy when the window is idle. The copy writes
    /// all meshes, so it waits until the changes stop and the slice is
    /// done, and the core makes it on a background queue: it never slows a
    /// slice or the window. The last copy stays until then, so a save never
    /// waits (see ProjectDocument.snapshot).
    func scheduleSaveBytes() {
        SessionStore.shared.changed()
        saveBytes.changed()
        saveBytesDue = true
        saveBytesTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushSaveBytesIfIdle() }
        saveBytesTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    /// Makes the copy if one is due and no slice runs (else the end of the
    /// slice calls this again).
    func flushSaveBytesIfIdle() {
        guard saveBytesDue, state != .slicing, !saveBytesBusy else { return }
        saveBytesDue = false
        guard document != nil else {
            saveBytes.set(nil)
            return
        }
        saveBytesBusy = true
        let at = saveBytes.changeCount
        let set = set, name = name, bytes = saveBytes
        let timing = ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil
        // The model (and its set) lives until the copy is done, also when
        // its window closes meanwhile.
        let keep = self
        SaveBytes.queue.async {
            let t = CACurrentMediaTime()
            withExtendedLifetime(keep) { bytes.set(Self.projectBytes(set, name), at: at) }
            if timing { NSLog("zslice timing: save copy %.1f ms (background)", (CACurrentMediaTime() - t) * 1000) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    saveBytesBusy = false
                    markStaleSave()
                    // A change while the copy ran: one more copy.
                    if saveBytesDue { flushSaveBytesIfIdle() }
                }
            }
        }
    }

    /// The bytes of the project file of a set (any thread).
    nonisolated static func projectBytes(_ set: OpaquePointer, _ name: String) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard zs_set_project_save(set, name, &out, &len) == 0, let out else { return nil }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
    }

    /// A save in the moment before wrote the copy before the last change:
    /// the document has changes again.
    private func markStaleSave() {
        if saveBytes.takeStaleSave(), let document, !document.isDocumentEdited {
            document.updateChangeCount(.changeDone)
        }
    }

    /// A copy of the plates as a project file, at once on the main thread
    /// (a save from the main thread, and the open of a document).
    func refreshSaveBytes() {
        let t = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil { NSLog("zslice timing: save copy %.1f ms", (CACurrentMediaTime() - t) * 1000) }
        }
        saveBytesDue = false
        saveBytes.set(document == nil ? nil : projectFileData(name: name))
        markStaleSave()
    }

    /// Opens a project file in place of the plates of the window.
    func openProjectFile(_ data: Data) throws {
        var message = [CChar](repeating: 0, count: 512)
        let rc = data.withUnsafeBytes { zs_set_project_open(set, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &message, message.count) }
        let why = message.withUnsafeBufferPointer { coreText($0.baseAddress) }
        guard rc == 0 else { throw Project.Failure(message: why.isEmpty ? statusText(rc) : why) }
        if !why.isEmpty { NSLog("zslice: project file: %@", why) }
        readPlatesAfterLoad()
    }

    /// All plates as the bytes of a project file.
    func projectFileData(name: String) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard zs_set_project_save(set, name, &out, &len) == 0, let out else { return nil }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
    }

    /// Moves a part of the active plate to another plate (nil: a new plate
    /// with the settings of this one). Returns the index of that plate.
    @discardableResult
    func movePart(_ part: Int, to plate: Int? = nil) -> Int? {
        let to = zs_set_part_move(set, active, part, plate ?? -1)
        guard to >= 0 else { return nil }
        readPlates()
        settingsGeneration += 1
        history.attach()
        onPlates?()
        return to
    }
}

extension Workspace {
    /// Copies of the selected part until there are n in all: on its plate
    /// while they fit, then on new plates (zs_set_fill). A note says how
    /// many and on how many plates.
    func fillPart(_ n: Int) {
        guard let i = selectedPart, n > 1 else { return }
        model.history.commit()
        var plates = 0
        let made = zs_set_fill(model.set, model.active, i, n, &plates)
        guard made >= 0 else {
            showNote("The copies did not work. \(statusText(Int32(made)))")
            return
        }
        model.readPlates()
        model.settingsGeneration += 1
        // The core made the steps of the history: the undo actions follow.
        model.history.attach()
        model.onPlates?()
        fitAfterSlice = true
        let all = Int(made)
        if all < n {
            showNote("\(all) of \(n) fit: the part is too big for more plates", seconds: 6)
        } else {
            showNote("\(all) in all, on \(plates) plate\(plates == 1 ? "" : "s")")
        }
    }

    /// Moves the selected part to a new plate, and shows that plate.
    func movePartToNewPlate(_ part: Int? = nil) {
        guard let i = part ?? selectedPart else { return }
        selectPart(nil)
        guard let to = model.movePart(i) else { return }
        selectPlate(to)
    }
}
