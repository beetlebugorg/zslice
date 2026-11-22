//! The macOS app of zslice: a SwiftUI shell over the Zig core.
//!
//! Each window is one document: a project file, or an STL or 3MF file
//! that the window imports. The document holds the bytes of the file. The window makes a SliceModel (one zs_app of the
//! core) and loads the bytes into it, and the core slices. The shell only
//! draws, reads files, and moves the events of the core to the main
//! thread. The app logic is in the core (see docs/app/README.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let stl = UTType(importedAs: "public.standard-tesselated-geometry-format", conformingTo: .threeDContent)
    static let threeMF = UTType(importedAs: "org.3mf.3mf", conformingTo: .threeDContent)
    static let gcode = UTType(filenameExtension: "gcode", conformingTo: .plainText) ?? .plainText
    /// STEP (.step, .stp) and OBJ models: the core reads them by their
    /// bytes, as STL (zs_app_load_stl sniffs the format).
    static let step = UTType(importedAs: "org.iso.step", conformingTo: .threeDContent)
    static let obj = UTType(importedAs: "public.geometry-definition-format", conformingTo: .threeDContent)

    /// The model files that zslice opens: its own types, and the type that
    /// macOS gives each extension now. Another slicer can claim .3mf or
    /// .step with a type of its own (Bambu Studio: com.bambulab.3mf and
    /// com.bambulab.step), and macOS then types the files with it, so a
    /// list of zslice's types alone refuses them.
    static let models: [UTType] = {
        var out: [UTType] = [.threeMF, .stl, .step, .obj]
        for e in ["3mf", "stl", "step", "stp", "obj"] {
            if let t = UTType(filenameExtension: e), !out.contains(t) { out.append(t) }
        }
        return out
    }()

    /// A 3MF file, of zslice's type or of another slicer's.
    var isThreeMF: Bool { self == .threeMF || preferredFilenameExtension == "3mf" || tags[.filenameExtension]?.contains("3mf") == true }
}

/// The document of a window: a project file (all plates, ProjectFile.swift),
/// or a model file that the window imports. It holds the bytes of the file
/// until the window loads them into its plates. A save writes the plates of
/// the window as a project file (zs_set_project_save): snapshot runs on the
/// main thread, where the plates are, and the write runs on another thread.
/// A model file (STL, STEP, OBJ, or a 3MF that is not a project) becomes an untitled
/// document after the load, so a save never writes over the model.
final class ProjectDocument: ReferenceFileDocument, @unchecked Sendable {
    static let readableContentTypes: [UTType] = UTType.models
    static let writableContentTypes: [UTType] = [.threeMF]

    let data: Data
    /// The plates of the window, for a save.
    nonisolated(unsafe) weak var model: SliceModel?

    init() { data = Data() }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    /// A zslice project file (all plates), not a model.
    var isProject: Bool { data.withUnsafeBytes { zs_project_file_is($0.bindMemory(to: UInt8.self).baseAddress, $0.count) } == 1 }

    /// The bytes of the plates, made on the main thread after each change
    /// (SliceModel.scheduleSaveBytes). SwiftUI calls snapshot on another
    /// thread, and takes the last copy.
    func snapshot(contentType: UTType) throws -> Data {
        let make: @MainActor () -> Data? = { [weak self] in
            guard let model = self?.model else { return nil }
            model.refreshSaveBytes()
            return model.saveBytes.current
        }
        // Never wait for the main thread here: during a save the main thread
        // waits for this thread, so a sync to it is a deadlock. The bytes of
        // the last change come when the window is idle (SaveBytes); a save
        // of older bytes marks the document changed again.
        if Thread.isMainThread, let bytes = MainActor.assumeIsolated({ make() }) { return bytes }
        guard let bytes = model?.saveBytes.forSave() else { throw CocoaError(.fileWriteUnknown) }
        return bytes
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        // A save: the count of the history button starts again.
        DispatchQueue.main.async { [weak model] in
            MainActor.assumeIsolated { model?.markSaved() }
        }
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

/// The app delegate: the last write of the session at a quit, before
/// the windows close.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The Quit event of the Dock and of a logout goes through the session
    /// too (SessionStore.quit).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        // zslice://open?file=…: a model link of a web page (OpenLink.swift).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(urlEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func urlEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        MainActor.assumeIsolated { LinkRouter.receive(text) }
    }

    @objc func quitEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { SessionStore.shared.quit() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { SessionStore.shared.terminate() }
        return .terminateNow
    }
}

@main
struct ZSliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        _ = SessionStore.launch
        // At launch with no file, a new window with an empty plate (the
        // whole app, with "Drop an STL or 3MF file here"), not the Open
        // panel that a document app shows by default.
        // No restore of the windows of the last session: they came back as
        // empty windows (an untitled import has no file to read again).
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false,
                                                  "NSQuitAlwaysKeepsWindows": false])
        // ZSLICE_QUIT_AFTER=s quits as Command-Q does, s seconds after the
        // start, and logs the quit (for tests of the session).
        if let s = ProcessInfo.processInfo.environment["ZSLICE_QUIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                NSLog("zslice quit: terminate")
                SessionStore.shared.quit()
            }
        }
        // ZSLICE_OPEN_AFTER=path opens a file 3 s after the start, as File >
        // Open does, and logs the windows 3 s later (for tests).
        if let path = ProcessInfo.processInfo.environment["ZSLICE_OPEN_AFTER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
                    if let error { NSLog("zslice open: %@", error.localizedDescription) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    NSLog("zslice windows: %@", NSApp.windows.filter(\.isVisible).map(\.title).joined(separator: ", "))
                }
            }
        }
    }

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            DocumentWindow(document: file.document, name: file.fileURL?.lastPathComponent ?? "", url: file.fileURL)
                // The printers of the farm: read for the Printers page and
                // for the notifications, once for the app.
                .onAppear { FarmMonitor.shared.start() }
        }
        .commands {
            ViewCommands()
            UndoCommands()
            ClipboardCommands()
            // Command-Q keeps the session (SessionStore.quit).
            CommandGroup(replacing: .appTermination) {
                Button("Quit zslice") { SessionStore.shared.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(after: .newItem) { PlateCommands() }
            CommandGroup(after: .help) {
                HelpCommands()
            }
        }
        Window("Licenses", id: "licenses") {
            LicensesView()
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

/// Edit > Cut, Copy, Paste, Paste as a New Plate, Duplicate, and Select
/// All. A text field that edits keeps its own (the field editor of
/// AppKit). Else they act on the selection of the view (Clipboard.swift).
struct ClipboardCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func text(_ action: String) { NSApp.sendAction(Selector(action), to: nil, from: nil) }

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { if editingText { text("cut:") } else { workspace?.clipCut() } }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!editingText && workspace == nil)
            Button("Copy") { if editingText { text("copy:") } else { workspace?.clipCopy() } }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!editingText && workspace == nil)
            Button("Paste") { if editingText { text("paste:") } else { workspace?.clipPaste() } }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!editingText && workspace == nil)
            Button("Paste as a New Plate") { workspace?.pasteAsPlate() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(workspace == nil || editingText)
            Button("Duplicate") { workspace?.clipDuplicate() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(workspace == nil || editingText)
            Button("Select All") { text("selectAll:") }
                .keyboardShortcut("a", modifiers: .command)
        }
    }
}

/// File > New Plate and Add Models.
struct PlateCommands: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button("New Plate") { workspace?.model.addPlate() }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(workspace == nil)
        Button("Add Models to the Plate…") { workspace?.addModels() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(workspace == nil)
        Button("Smart Placement") { workspace?.smartPlace() }
            .help("Turns each part to need less support, then arranges the plate")
            .disabled(workspace == nil)
        Button("Arrange the Plate") { workspace?.plateAction(zs_app_plate_arrange, fits: true) }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(workspace == nil)
        Button("Clear the Plate") { workspace?.plateAction(zs_app_plate_clear) }
            .disabled(workspace == nil)
        Menu("Calibrate") {
            ForEach(CalibrationInfo.kinds, id: \.kind) { c in
                Button(c.name) { workspace?.calibrate(c.kind) }
                    .help("\(c.tip), on a new plate")
            }
            Divider()
            Button("Use a Value of This Test…") { workspace?.showCalibration() }
                .help("How to read the test of this plate, and a button for each of its values")
        }
        .disabled(workspace == nil)
        Divider()
        Button("Add Printers from a Fleet File…") { FarmMonitor.shared.askFleet() }
        Divider()
        Button("Show Project…") { workspace?.projectOpen = true }
            .disabled(workspace?.model.project == nil)
        Button("Close the Project") { workspace?.closeProject() }
            .disabled(workspace?.model.project == nil)
        Button("Open Project Folder…") { workspace?.openProject() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(workspace == nil)
        Button("Open Project from GitHub…") { workspace?.askGitHub() }
            .disabled(workspace == nil)
    }
}

/// Help > Keyboard Shortcuts.
struct HelpCommands: View {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Licenses") { openWindow(id: "licenses") }
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
            // A check item: the 2D view of one layer, or the 3D view (the
            // keys 2 and 3 in the view too).
            Toggle("2D View", isOn: Binding(get: { workspace?.page == .twoD }, set: { workspace?.page = $0 ? .twoD : .threeD }))
                .keyboardShortcut("2", modifiers: .command)
                .disabled(workspace == nil)
            Button("Fit the Part") { workspace?.fit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(workspace == nil)
            Toggle("Hide the Bed", isOn: Binding(get: { workspace?.bedHidden == true }, set: { _ in workspace?.toggleBed() }))
                .help("The bed and its grid do not draw, so the bottom of a part shows from below (B)")
                .disabled(workspace == nil)
            Divider()
            // Gaps has no key (the user's choice): the menu item and the
            // button of the tool strip.
            Button("Show Gaps") { workspace?.toggleGaps() }
                .disabled(workspace == nil)
            Button("Check the Print") { workspace?.checkOpen.toggle() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Divider()
            Button("History") { workspace?.historyOpen.toggle() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(workspace == nil)
            Button("Printers") { workspace?.farmOpen.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("Search Settings and Actions…") { workspace?.openSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace == nil)
            Button(workspace?.showSettings == true ? "Hide Settings" : "Show Settings") { workspace?.showSettings.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Divider()
        }
    }
}
