//! The project file: all the plates of a window in one .3mf
//! (zs_set_project_save, zs_set_project_open). It has the parts of each
//! plate, their places and settings, the layer profiles, and the printer,
//! filament, and print settings of each plate. Other slicers open its
//! first plate.
//!
//! File > Save Project (Command-S) writes it: to the file of the window if
//! the window has one, else through a save panel. Save Project As
//! (Shift-Command-S) always asks. The close button of the window has a dot
//! while the plates have changes that are not saved. An open of a .3mf
//! first asks the core if it is a project file (zs_project_file_is); else
//! the file opens as a model.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import UniformTypeIdentifiers

extension SliceModel {
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
        onPlates?()
        return to
    }
}

extension Workspace {
    /// The plates have changes since the last save (or the open).
    var unsaved: Bool { model.history.generation != savedGeneration }

    /// Saves the project file: to the file of the window, or through a
    /// save panel (always with `as`).
    func saveProject(as: Bool = false) {
        if !`as`, let url = projectURL {
            write(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.threeMF]
        let base = (model.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "Untitled" : base) + ".3mf"
        panel.message = "All plates, their parts, and their settings, in one file."
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.write(to: url)
        }
        if let w = canvas.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func write(to url: URL) {
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        guard let data = model.projectFileData(name: name) else {
            showNote("The project did not save")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
            return
        }
        projectURL = url
        savedGeneration = model.history.generation
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        canvas.window?.representedURL = url
        canvas.window?.title = url.lastPathComponent
        showNote("Saved \(url.lastPathComponent)")
    }

    /// Moves the selected part to a new plate, and shows that plate.
    func movePartToNewPlate(_ part: Int? = nil) {
        guard let i = part ?? selectedPart else { return }
        selectPart(nil)
        guard let to = model.movePart(i) else { return }
        selectPlate(to)
    }
}
