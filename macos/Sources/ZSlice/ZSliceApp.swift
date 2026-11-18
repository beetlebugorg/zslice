//! The macOS app of zslice: a SwiftUI shell over the Zig core.
//!
//! Each window is one document: an STL or 3MF file. The document holds the
//! bytes of the file. The window makes a SliceModel (one zs_app of the
//! core) and loads the bytes into it, and the core slices. The shell only
//! draws, reads files, and moves the events of the core to the main
//! thread. The app logic is in the core (see docs/app/README.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let stl = UTType(importedAs: "public.standard-tesselated-geometry-format", conformingTo: .threeDContent)
    static let threeMF = UTType(importedAs: "org.3mf.3mf", conformingTo: .threeDContent)
    static let gcode = UTType(filenameExtension: "gcode", conformingTo: .plainText) ?? .plainText
}

/// A model file. The bytes go to the core when the window opens.
struct ModelDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.stl, .threeMF]
    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@main
struct ZSliceApp: App {
    var body: some Scene {
        DocumentGroup(viewing: ModelDocument.self) { file in
            DocumentWindow(document: file.document, name: file.fileURL?.lastPathComponent ?? "model.stl")
        }
        .commands {
            ViewCommands()
            UndoCommands()
            CommandGroup(after: .newItem) { PlateCommands() }
            CommandGroup(after: .help) {
                HelpCommands()
            }
        }
        Settings {
            TabView {
                PrintersSettings()
                    .tabItem { Label("Printers", systemImage: "printer") }
            }
            .frame(minWidth: 680, minHeight: 460)
        }
    }
}

/// Edit > Undo and Redo. A text field that edits keeps its own undo (the
/// field editor of AppKit). Else they undo and redo the steps of the plate
/// (History, on its UndoManager), with the name of the step in the title.
struct UndoCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    private var history: History? { workspace?.model.history }

    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            let u = history?.undoManager
            let _ = history?.generation
            Button(u?.undoMenuItemTitle ?? "Undo") {
                if editingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { u?.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(editingText || u?.canUndo == true))
            Button(u?.redoMenuItemTitle ?? "Redo") {
                if editingText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { u?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(editingText || u?.canRedo == true))
        }
    }
}

/// File > New Plate and Add Models.
struct PlateCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Divider()
        Button("New Plate") { workspace?.model.addPlate() }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(workspace == nil)
        Button("Add Models to the Plate…") { workspace?.addModels() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(workspace == nil)
        Button("Open Project Folder…") { workspace?.openProject() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(workspace == nil)
    }
}

/// Help > Keyboard Shortcuts.
struct HelpCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button("Keyboard Shortcuts") { workspace?.shortcutsOpen = true }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(workspace == nil)
    }
}

/// The View menu: the page of the view.
struct ViewCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("3D View") { workspace?.page = .threeD }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(workspace == nil)
            Button("2D Layer View") { workspace?.page = .twoD }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(workspace == nil)
            Button("Fit the Part") { workspace?.fit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(workspace == nil)
            Divider()
            Button("Show Gaps") { workspace?.toggleGaps() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("Check the Print") { workspace?.checkOpen.toggle() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Divider()
            Button("Search Settings and Actions…") { workspace?.searchOpen = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace == nil)
            Button(workspace?.showSettings == true ? "Hide Settings" : "Show Settings") { workspace?.showSettings.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Divider()
        }
    }
}
