//! The import of a model from a model page or a ZIP file
//! (docs/internals/model-import.md, linux/src/ui/model-import.c). The rules
//! are in the core (zs_import_*), and zslice calls no API of a site.
//!
//! A model page: the sheet says how to get the ZIP file of the model, and
//! Open the Page opens it in the browser. A ZIP file (from Open, Add Models,
//! or a drop): the sheet lists its files by kind, with a check box for each
//! file that loads. The list is the question before the load, so Return
//! does not start it. Load adds the checked files as parts, on a new plate
//! if the active plate has parts, and zs_set_spill puts the parts that do
//! not fit the bed on more plates. A file that fails does not stop the
//! others. An import never starts a print.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI
import UniformTypeIdentifiers

/// The files of a ZIP file, and the choice of the user.
@MainActor
@Observable
final class ImportChoice: Identifiable {
    struct Row: Identifiable {
        let id: Int
        let name: String
        let detail: String
        let group: String
        let canLoad: Bool
        var checked: Bool
    }

    let name: String
    let data: Data
    private(set) var title = ""
    private(set) var subtitle = "The files of the ZIP file"
    private(set) var note = ""
    private(set) var rows: [Row] = []
    /// The sum of the checked files, or why they cannot load.
    private(set) var sum = ""
    private(set) var ready = false
    @ObservationIgnored private let list: OpaquePointer

    /// nil, with the result of the core in `error`, for a file with no list.
    init?(name: String, data: Data, error: inout Int32) {
        var out: OpaquePointer?
        let rc = data.withUnsafeBytes { zs_import_list_zip($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &out) }
        guard rc == Int32(ZS_IMPORT_OK.rawValue), let out else {
            error = rc
            return nil
        }
        self.name = name
        self.data = data
        list = out
        var info = zs_import_info()
        zs_import_list_info(list, &info)
        let named = coreText(info.title)
        title = named.isEmpty ? name : named
        note = coreText(info.note)
        rows = (0 ..< zs_import_count(list)).compactMap { i in
            var f = zs_import_file()
            guard zs_import_file_get(list, i, &f) == Int32(ZS_IMPORT_OK.rawValue) else { return nil }
            return Row(id: i, name: coreText(f.name), detail: Self.detail(f), group: coreText(f.kind_label), canLoad: f.can_load != 0, checked: f.checked != 0)
        }
        readSum()
    }

    isolated deinit { zs_import_list_free(list) }

    /// "STL, 2 MB, 3 plates. In the folder a. Its note."
    private static func detail(_ f: zs_import_file) -> String {
        var d = f.kind == Int32(ZS_IMPORT_KIND_OTHER.rawValue) ? "" : coreText(f.kind_label)
        if f.size > 0 { d += (d.isEmpty ? "" : ", ") + ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file) }
        if f.plates > 1 { d += ", \(f.plates) plates" }
        let folder = coreText(f.folder), note = coreText(f.note)
        if !folder.isEmpty { d += ". In the folder \(folder)" }
        if !note.isEmpty { d += (d.isEmpty ? "" : ". ") + note }
        return d
    }

    func set(_ i: Int, on: Bool) {
        zs_import_check(list, i, on ? 1 : 0)
        var f = zs_import_file()
        if zs_import_file_get(list, i, &f) == Int32(ZS_IMPORT_OK.rawValue), let k = rows.firstIndex(where: { $0.id == i }) {
            rows[k].checked = f.checked != 0
        }
        readSum()
    }

    private func readSum() {
        var files = 0
        var bytes: UInt64 = 0
        let rc = zs_import_ready(list, &files, &bytes)
        ready = rc == Int32(ZS_IMPORT_OK.rawValue)
        sum = ready
            ? "\(files) \(files == 1 ? "file" : "files"), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). It does not start a print."
            : coreText(zs_import_message(rc))
    }

    /// The bytes of file i.
    func bytes(_ i: Int) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = data.withUnsafeBytes { zs_import_zip_file(list, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, i, &out, &len) }
        guard rc == Int32(ZS_IMPORT_OK.rawValue), let out else { return nil }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
    }
}

extension Workspace {
    /// A ZIP file: the sheet with its files.
    func openZip(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            showImportError("The ZIP file did not open", "zslice could not read \(url.lastPathComponent).")
            return
        }
        openZip(name: url.lastPathComponent, data: data)
    }

    func openZip(name: String, data: Data) {
        var rc: Int32 = 0
        guard let c = ImportChoice(name: name, data: data, error: &rc) else {
            showImportError("The ZIP file did not open", coreText(zs_import_message(rc)))
            return
        }
        importChoice = c
    }

    /// The sheet for the address of a model page.
    func askModelPage(_ text: String = "") {
        importPageText = text
        importPageOpen = true
    }

    /// Adds the checked files as parts (the steps of model-import.md).
    func loadImport(_ c: ImportChoice) {
        var failed: [String] = []
        var loaded = 0
        if zs_app_part_count(model.core) > 0 { model.addPlate() }
        let startEmpty = zs_app_part_count(model.core) == 0
        for r in c.rows where r.checked {
            guard let data = c.bytes(r.id) else {
                failed.append("\(r.name): \(coreText(zs_import_message(Int32(ZS_IMPORT_NOT_ZIP.rawValue))))")
                continue
            }
            let isProject = data.withUnsafeBytes { zs_project_file_is($0.bindMemory(to: UInt8.self).baseAddress, $0.count) } == 1
            if isProject {
                failed.append("\(r.name): a zslice project. Open it on its own.")
                continue
            }
            do {
                if loaded == 0, startEmpty {
                    try model.load(name: r.name, data: data)
                } else {
                    try model.add(name: r.name, data: data)
                }
                loaded += 1
            } catch {
                failed.append("\(r.name): \(error.localizedDescription)")
            }
        }
        var plates = loaded > 0 ? 1 : 0
        if loaded > 0 {
            let more = zs_set_spill(model.set, model.active)
            if more > 0 { plates += more }
            model.readPlates()
            model.onPlates?()
            fitAfterSlice = true
            showNote("Added \(loaded) \(loaded == 1 ? "file" : "files") on \(plates) \(plates == 1 ? "plate" : "plates").")
        }
        importChoice = nil
        if ProcessInfo.processInfo.environment["ZSLICE_IMPORT_YES"] != nil {
            NSLog("zslice import: loaded %ld, failed %ld, new plates %ld, plates %@", loaded, failed.count, max(0, plates - 1), model.plates.map { String($0.parts) }.joined(separator: " "))
        }
        if !failed.isEmpty {
            showImportError(loaded == 0 ? "The files did not load" : "Some files did not load", failed.joined(separator: "\n"))
        }
    }

    private func showImportError(_ title: String, _ text: String) {
        if ProcessInfo.processInfo.environment["ZSLICE_IMPORT_YES"] != nil {
            NSLog("zslice import: %@: %@", title, text)
            return
        }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let w = canvas.window { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}

/// The text of a char array of the core.
private func arrayText<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// The address of a model page: how to get its ZIP file.
struct ModelPageSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    /// The site and the clean address, or nil.
    private var page: (site: Int32, url: String)? {
        var p = zs_import_page()
        guard zs_import_page_check(text.trimmingCharacters(in: .whitespacesAndNewlines), &p) == Int32(ZS_IMPORT_OK.rawValue) else { return nil }
        return (p.site, arrayText(p.url))
    }

    var body: some View {
        let found = page
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from a Model Page").font(.title3.weight(.semibold))
            TextField("Address", text: $text, prompt: Text("https://www.printables.com/model/…"))
                .textFieldStyle(.roundedBorder)
            Group {
                if let found {
                    Text(coreText(zs_import_page_text(found.site)))
                } else if text.isEmpty {
                    Text("Paste the address of a Printables or Thingiverse model.").foregroundStyle(.secondary)
                } else {
                    Text(coreText(zs_import_message(Int32(ZS_IMPORT_NOT_A_PAGE.rawValue)))).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open a ZIP File…") { chooseZip() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open the Page") {
                    if let u = found.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(u) }
                }
                .disabled(found == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { text = workspace.importPageText }
    }

    private func chooseZip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose the ZIP file of the model."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dismiss()
        DispatchQueue.main.async { workspace.openZip(url) }
    }
}

/// The files of a ZIP file, with a check box for each file that loads.
struct ImportSheet: View {
    let workspace: Workspace
    let choice: ImportChoice
    @Environment(\.dismiss) private var dismiss

    /// The rows by kind, in the order of the list.
    private var groups: [(title: String, rows: [ImportChoice.Row])] {
        var out: [(title: String, rows: [ImportChoice.Row])] = []
        for r in choice.rows {
            if out.last?.title == r.group { out[out.count - 1].rows.append(r) } else { out.append((r.group, [r])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title).font(.title3.weight(.semibold))
                Text(choice.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            if !choice.note.isEmpty {
                Text(choice.note).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach(groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.rows) { r in
                            Toggle(isOn: Binding(get: { r.checked }, set: { choice.set(r.id, on: $0) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.name).foregroundStyle(r.canLoad ? .primary : .secondary)
                                    if !r.detail.isEmpty {
                                        Text(r.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(!r.canLoad)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Text(choice.sum)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                // Cancel is the default: Return does not start a load.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button("Load") { workspace.loadImport(choice) }
                    .disabled(!choice.ready)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }
}

/// Save and Save As in the responder chain of a window: a project with no
/// parts is not worth a file, so with each plate empty they say so and
/// write nothing (issue #42).
final class SaveGuard: NSResponder, NSMenuItemValidation {
    private weak var workspace: Workspace?
    private weak var document: NSDocument?

    init(workspace: Workspace, document: NSDocument) {
        self.workspace = workspace
        self.document = document
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts the guard after the window, before its document.
    @MainActor static func install(in window: NSWindow, workspace: Workspace, document: NSDocument) -> SaveGuard {
        let g = SaveGuard(workspace: workspace, document: document)
        g.nextResponder = window.nextResponder
        window.nextResponder = g
        return g
    }

    /// False: every plate is empty, and the user has the reason.
    @MainActor private func canSave() -> Bool {
        guard let workspace, workspace.model.plates.allSatisfy({ $0.parts == 0 }) else { return true }
        workspace.showNote("There is nothing to save: every plate is empty. Add a model first.")
        if ProcessInfo.processInfo.environment["ZSLICE_SAVE_GUARD"] != nil { NSLog("zslice save guard: nothing to save") }
        return false
    }

    @objc(saveDocument:) func saveTheDocument(_ sender: Any?) {
        if MainActor.assumeIsolated({ canSave() }) { document?.save(sender) }
    }

    @objc(saveDocumentAs:) func saveTheDocumentAs(_ sender: Any?) {
        if MainActor.assumeIsolated({ canSave() }) { document?.saveAs(sender) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        document?.validateMenuItem(item) ?? false
    }
}
