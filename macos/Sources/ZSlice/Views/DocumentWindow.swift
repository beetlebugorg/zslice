//! The window of one document: the 3D view of the plate, with the floating
//! controls over it (docs/internals/one-view.md): the layer slider at the
//! right, the scrub bar at the bottom, and the print card at the bottom
//! right.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct DocumentWindow: View {
    /// The file of the window, or nil for a window with an empty plate.
    let document: ProjectDocument
    let name: String
    var url: URL? = nil
    @State private var workspace = Workspace()
    @State private var loadError: String?
    @State private var dropping = false

    /// Loads the file of the document into the plates, and gives the
    /// NSDocument of the window to the model.
    /// Puts a session of the last run into this window, and gives the
    /// document its file and its unsaved changes.
    private func restore(_ session: SessionStore.Pending, into doc: NSDocument, window w: NSWindow) {
        let state = workspace.restoreSession(session)
        workspace.model.history.commit()
        if let path = state?.file, FileManager.default.fileExists(atPath: path) {
            doc.fileURL = URL(fileURLWithPath: path)
            doc.fileType = UTType.threeMF.identifier
        } else if let name = state?.name, !name.isEmpty {
            doc.displayName = name
        }
        for c in doc.windowControllers { c.synchronizeWindowTitleWithDocumentName() }
        doc.updateChangeCount(state?.edited == true ? .changeDone : .changeCleared)
        if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
            NSLog("zslice session: window restored %.0f ms after the start", (CACurrentMediaTime() - SessionStore.launch) * 1000)
        }
        openPendingSessions()
    }

    /// A new window for each session of the last run that is left.
    private func openPendingSessions() {
        guard !SessionStore.shared.pending.isEmpty else { return }
        DispatchQueue.main.async {
            NSDocumentController.shared.newDocument(nil)
        }
    }

    private func open() async {
        document.model = workspace.model
        // A session of the last run: the window comes back as it was.
        let session = document.data.isEmpty ? SessionStore.shared.takePending() : nil
        // After the restore, or if the window never comes: the session
        // files may be written again.
        defer { if session != nil { SessionStore.shared.restoreDone() } }
        let timing = ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil
        if timing { NSLog("zslice session: open at %.0f ms", (CACurrentMediaTime() - SessionStore.launch) * 1000) }
        if !document.data.isEmpty {
            do {
                try workspace.model.load(name: name, data: document.data)
                // The open is a step of the history, at once.
                workspace.model.history.commit()
            } catch {
                loadError = error.localizedDescription
            }
        }
        // The NSDocument of the window: its UndoManager takes the steps.
        for _ in 0 ..< 50 where workspace.canvas.window == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let w = workspace.canvas.window, let doc = NSDocumentController.shared.document(for: w) else { return }
        if timing { NSLog("zslice session: window at %.0f ms", (CACurrentMediaTime() - SessionStore.launch) * 1000) }
        // ZSLICE_WIDTH=points: the width of the window (0: its narrowest),
        // for tests of the toolbar.
        if let wd = ProcessInfo.processInfo.environment["ZSLICE_WIDTH"].flatMap(Double.init) {
            var f = w.frame
            f.size.width = max(wd, w.minSize.width, 1)
            w.setFrame(f, display: true)
        }
        workspace.model.document = doc
        let ws = workspace
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { SessionStore.shared.closed(ws) }
        }
        if let session {
            // ZSLICE_RESTORE_DELAY=s: a slow window, for the test of the
            // writes before a restore; it asks for writes at the start of
            // the wait, and logs the index of the session after 2 s.
            if let s = ProcessInfo.processInfo.environment["ZSLICE_RESTORE_DELAY"].flatMap(Double.init) {
                SessionStore.shared.changed()
                try? await Task.sleep(for: .seconds(2))
                NSLog("zslice session: index during the restore: %@", SessionStore.shared.indexText())
                try? await Task.sleep(for: .seconds(max(0, s - 2)))
            }
            restore(session, into: doc, window: w)
            return
        }
        // The other sessions of the last run: a window for each.
        openPendingSessions()
        // A file opens in place of the empty window of the start (or of
        // File > New), at its place: no second window.
        // A project 3MF that macOS typed as another slicer's 3MF: zslice
        // saves it as its own type, so a save writes it in place.
        if document.isProject, let t = doc.fileType.flatMap({ UTType($0) }), t != .threeMF, t.isThreeMF {
            doc.fileType = UTType.threeMF.identifier
        }
        if document.data.isEmpty {
            EmptyWindows.note(doc, workspace)
        } else {
            EmptyWindows.replace(with: w, keeping: doc)
        }
        // A model file: the window imports it, as an untitled project
        // with the name of the model, so a save asks where to save and
        // never writes over the model.
        if !document.data.isEmpty, !document.isProject {
            doc.fileURL = nil
            doc.fileType = UTType.threeMF.identifier
            doc.displayName = ((url?.lastPathComponent ?? name) as NSString).deletingPathExtension
            for c in doc.windowControllers { c.synchronizeWindowTitleWithDocumentName() }
            w.title = doc.displayName
        }
        doc.updateChangeCount(.changeCleared)
        workspace.model.markSaved()
        // For tests: ZSLICE_DOC_SAVE=path saves through the NSDocument, and
        // ZSLICE_DOC_AUTOSAVE=1 autosaves, after a change of the wall count.
        let env = ProcessInfo.processInfo.environment
        if !document.data.isEmpty, env["ZSLICE_DOC_SAVE"] != nil || env["ZSLICE_DOC_AUTOSAVE"] != nil {
            NSLog("zslice doc: start, edited %d, url %@, name %@", doc.isDocumentEdited ? 1 : 0, doc.fileURL?.path ?? "none", doc.displayName)
            try? await Task.sleep(for: .seconds(1))
            workspace.model.set("project.wall_count", "3")
            workspace.model.history.commit()
            NSLog("zslice doc: edited %d, url %@, name %@", doc.isDocumentEdited ? 1 : 0, doc.fileURL?.path ?? "none", doc.displayName)
            if let path = env["ZSLICE_DOC_SAVE"] {
                doc.save(to: URL(fileURLWithPath: path), ofType: UTType.threeMF.identifier, for: .saveToOperation) { e in
                    NSLog("zslice doc: saved %@", e?.localizedDescription ?? "ok")
                }
            }
            workspace.model.history.undoManager.undo()
            NSLog("zslice doc: after undo, edited %d", doc.isDocumentEdited ? 1 : 0)
            workspace.model.history.undoManager.redo()
            NSLog("zslice doc: after redo, edited %d", doc.isDocumentEdited ? 1 : 0)
            if env["ZSLICE_DOC_AUTOSAVE"] != nil {
                doc.autosave(withImplicitCancellability: false) { e in
                    NSLog("zslice doc: autosaved to %@ (%@)", doc.autosavedContentsFileURL?.path ?? "none", e?.localizedDescription ?? "ok")
                }
            }
        }
    }

    /// Under the title: the project, and the plate of the view.
    private var subtitle: String {
        let m = workspace.model
        var parts: [String] = []
        if m.project != nil, !m.name.isEmpty { parts.append(m.name) }
        if m.plates.count > 1 { parts.append("Plate \(m.active + 1) of \(m.plates.count)") }
        return parts.joined(separator: " · ")
    }

    /// The 3D view fills the window down to the bottom bar, under the
    /// toolbar too. Each control
    /// is an overlay on an edge of the content area, so no control can make
    /// the window wider than it is: a narrow window shrinks the scrub bar.
    var body: some View {
        Color.clear
            // The view ends at the top of the bottom bar, so the signs of
            // the plates are never under it.
            .background { SliceView(canvas: workspace.canvas).padding(.bottom, workspace.dockHeight).ignoresSafeArea() }
            // The work bar: the draft, the exact slice, and the simulation.
            .overlay(alignment: .top) { WorkBar(work: workspace.model.work) }
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 10) {
                    ToolStrip(workspace: workspace)
                    // The legend is in the Colors popover of the tool strip.
                    if workspace.checkOpen {
                        CheckPanel(workspace: workspace)
                            .panel()
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                // Left of the layer slider and its number.
                GapSummary(workspace: workspace)
                    .panel()
                    .padding(.top, 12)
                    .padding(.trailing, 92)
            }
            .overlay(alignment: .trailing) {
                if workspace.layerCount > 0 {
                    LayerSlider(workspace: workspace)
                        .padding(.top, 40)
                        .padding(.bottom, 86)
                        .padding(.trailing, 12)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if workspace.detailsOpen, workspace.model.state != .empty {
                        HStack {
                            Spacer()
                            PrintCard(workspace: workspace)
                                .fixedSize()
                                .panel()
                                .overlay(alignment: .topTrailing) {
                                    Button { workspace.detailsOpen = false } label: { CloseMark() }
                                    .buttonStyle(.borderless)
                                    .padding(6)
                                    .help("Close the details")
                                }
                        }
                        .padding(.trailing, 84)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    BottomBar(workspace: workspace)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { workspace.dockHeight = $0 }
                }
                .animation(.easeOut(duration: 0.15), value: workspace.detailsOpen)
            }
            // The cards and the tape float over all the controls, in the coordinates
            // of the view (from the top of the window).
            .overlay {
                GeometryReader { geo in
                    TapeOverlay(workspace: workspace, area: geo.size)
                    OpenPlateButton(workspace: workspace)
                    // The Label tool: the handle of the selected label, and
                    // its card.
                    if workspace.tool == .label, workspace.page == .threeD {
                        LabelHandles(workspace: workspace)
                        LabelCard(workspace: workspace, area: geo.size)
                    }
                    // The 2D view says so at the top; a click goes back to 3D.
                    if workspace.page == .twoD {
                        Button { workspace.page = .threeD } label: {
                            Text("2D View")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.separator))
                        }
                        .buttonStyle(.plain)
                        .help("The 2D view of one layer. Click, or press 3, for the 3D view (2 switches between them).")
                        .position(x: geo.size.width / 2, y: 66)
                    }
                    if let l = workspace.ringLabel {
                        Text(l.text)
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .position(x: l.at.x + 60, y: l.at.y - 24)
                            .allowsHitTesting(false)
                    }
                    if let gap = workspace.gapCard {
                        // Its measured size: a gap with many steps makes a tall
                        // card, and the card must keep clear of the gap.
                        GapCard(workspace: workspace, gap: gap, maxHeight: max(160, geo.size.height - 60 - workspace.dockHeight - 24))
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { workspace.gapCardSize = $0 }
                            .position(cardPlace(avoiding: workspace.gapScreenBox() ?? CGRect(x: workspace.cardAt.x - 12, y: workspace.cardAt.y - 12, width: 24, height: 24),
                                                near: workspace.cardAt, size: workspace.gapCardSize, in: geo.size,
                                                bottom: workspace.dockHeight + 12, panels: workspace.panels))
                    }
                    if workspace.tool == .support, workspace.supportPaneOpen, workspace.page == .threeD {
                        // Beside the tool strip, clear of the details at the right.
                        // Its top is at the top of the tool strip, under the toolbar: the
                        // card grows down with the trees.
                        SupportCard(workspace: workspace)
                            .fixedSize()
                            .panel()
                            .padding(.leading, 95)
                            .padding(.top, 50)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if workspace.tool != .support, workspace.supportPick != nil, workspace.page == .threeD {
                        // Where the card of the Support tool goes.
                        PickedSupportCard(workspace: workspace)
                            .fixedSize()
                            .panel()
                            .padding(.leading, 95)
                            .padding(.top, 50)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if let p = workspace.paint, workspace.page == .threeD {
                        // At the left, next to the tools, so it never covers the part.
                        PaintCard(workspace: workspace, paint: p)
                            .fixedSize()
                            .panel()
                            .padding(.leading, 95)
                            .padding(.top, 50)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    // The Turn, Grab, and Paint tools work on the part itself: no card.
                    if let i = workspace.selectedPart, workspace.tool != .turn, workspace.tool != .grab, workspace.tool != .paint {
                        PartCard(workspace: workspace, index: i, area: geo.size)
                            .id(i)
                    }
                    if let r = workspace.rangeCard, workspace.page == .threeD {
                        RangeCard(workspace: workspace, lo: r.lo, hi: r.hi, area: geo.size)
                    }
                    if workspace.cardOpen, let info = workspace.lineInfo {
                        LineCard(workspace: workspace, info: info, area: geo.size)
                    }
                }
                .ignoresSafeArea()
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { o in
                    if workspace.cardsOrigin != o { workspace.cardsOrigin = o }
                }
            }
            // The panels that the cards keep out of.
            .onPreferenceChange(PanelFramesKey.self) { frames in
                if workspace.panelFrames != frames { workspace.panelFrames = frames }
            }
            // The search last, over the other controls: the results under
            // the field of the toolbar, or the card of the search.
            .overlay(alignment: .topLeading) {
                let search = workspace.search
                // The results show when the field has the focus, also
                // before the first letter.
                if search.open {
                    GeometryReader { geo in
                        if search.docked {
                            SearchOverlay(workspace: workspace, area: geo.size)
                                .padding(.leading, max(8, min(geo.size.width - min(SearchOverlay.dockedWidth, geo.size.width - 16) - 8, search.fieldMinX - 8)))
                                .padding(.top, 6)
                        } else {
                            SearchOverlay(workspace: workspace, area: geo.size)
                        }
                    }
                }
            }
        .frame(minWidth: 720, minHeight: 480)
        .navigationSubtitle(subtitle)
        // Model files dropped on the window go on the active plate; an SVG
        // file on a part becomes a label on its face there.
        .dropDestination(for: URL.self) { urls, _ in
            let models = urls.filter { ["stl", "3mf", "step", "stp", "obj"].contains($0.pathExtension.lowercased()) }
            for url in models { workspace.addModel(url) }
            let svgs = urls.filter { $0.pathExtension.lowercased() == "svg" }
            if let url = svgs.first, let p = workspace.pointerInView {
                if let d = try? Data(contentsOf: url), d.count <= 512 * 1024, let text = String(data: d, encoding: .utf8) {
                    workspace.dropLabelSVG(text, at: p, name: url.lastPathComponent)
                } else {
                    workspace.showNote("The SVG did not read: a text file of at most 512 KiB.")
                }
            }
            return !models.isEmpty || !svgs.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(12)
                    .overlay(Text("Drop to add to the plate").font(.title2).padding(14).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
        // The note is a toast over the dock, as in the web app.
        .overlay(alignment: .bottom) {
            if let note = workspace.note {
                Label {
                    Text(note)
                } icon: {
                    if workspace.busy { ProgressView().controlSize(.small) } else { Image(systemName: "info.circle") }
                }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 90)
                    .padding(.bottom, workspace.dockHeight + 14)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: workspace.note)
        // The Printers page covers the window; the settings pane hides.
        .overlay {
            if workspace.farmOpen { FarmPage(workspace: workspace) }
        }
        .sheet(isPresented: Bindable(workspace).projectOpen) {
            VStack(spacing: 0) {
                ProjectPage(workspace: workspace)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { workspace.projectOpen = false }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(minWidth: 560, minHeight: 520)
        }
        .sheet(isPresented: Bindable(workspace).shortcutsOpen) { ShortcutSheet() }
        .sheet(isPresented: Bindable(workspace).pickerOpen) { PrinterPicker(workspace: workspace) }
        .sheet(isPresented: Bindable(workspace).connectDeckOpen) { ConnectDeckSheet(workspace: workspace) }
        .sheet(item: Binding(get: { workspace.calibration }, set: { workspace.calibration = $0 })) { c in
            CalibrationSheet(workspace: workspace, cal: c)
        }
        .sheet(item: Binding(get: { workspace.importReport }, set: { workspace.importReport = $0 })) { r in
            ImportReportSheet(report: r)
        }
        .sheet(isPresented: Binding(get: { workspace.pairing != nil && !workspace.pickerOpen && !workspace.connectDeckOpen }, set: { if !$0 { workspace.pairing = nil } })) {
            if let id = workspace.pairing { PairSheet(workspace: workspace, printerID: id) }
        }
        .inspector(isPresented: Binding(get: { workspace.showSettings && !workspace.farmOpen }, set: { workspace.showSettings = $0 })) {
            InspectorPanel(workspace: workspace)
                .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
        }
        // The slice is the UI: a small toolbar, as in the web app. The file
        // at the left, the search in the center, and the printer, the
        // filament, the quality, and three icons at the right. At a narrow
        // width, AppKit moves whole items to the » menu; no label is cut
        // with "…".
        .toolbar {
            ToolbarItem(placement: .navigation) {
                FileButton(workspace: workspace)
            }
            // The search is always in the toolbar (or a Search button while
            // it is a card). The 2D view has no button: the keys 2 and 3,
            // and View > 2D View.
            ToolbarItem(placement: .principal) {
                SearchToolbarItem(workspace: workspace)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                PrinterMenu(workspace: workspace)
                FilamentMenu(workspace: workspace)
                QualityMenu(workspace: workspace)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.farmOpen.toggle() } label: { Label("Printers", systemImage: "printer.dotmatrix.filled.and.paper") }
                    .help("The printers and their jobs, and the plates to print (⌥⌘P)")
                Button { workspace.showSettings.toggle() } label: { Label("Settings", systemImage: "sidebar.right") }
                    .help("Show or hide the settings (N)")
                MoreMenu(workspace: workspace)
            }
        }
        .hiddenToolbarTitle()
        .focusedSceneValue(\.workspace, workspace)
        .task { await open() }
        .overlay {
            if workspace.model.state == .empty && workspace.model.plates.count <= 1 && workspace.model.project == nil {
                WelcomeCard(workspace: workspace)
            }
        }
        .alert("The file did not open", isPresented: .constant(loadError != nil)) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }
}

/// The drawer: the settings, or the history of the plate.
struct InspectorPanel: View {
    let workspace: Workspace

    /// Only the settings: the history, the project, and the printers have
    /// places of their own (a popover, a sheet, and a page).
    var body: some View {
        SettingsInspector(workspace: workspace)
            .padding(.top, 8)
    }
}

extension FocusedValues {
    /// The model of the window in front, for the menu commands.
    @Entry var workspace: Workspace?
}

/// The scrub bar: play, the time in the top layer, and the replay speed.
struct ScrubBar: View {
    let workspace: Workspace
    /// In the dock: no capsule of its own.
    var bare = false

    var body: some View {
        let (t0, t1) = workspace.layerTimes(workspace.hi)
        let inLayer = workspace.scrubFraction * (t1 - t0)
        HStack(spacing: 10) {
            Button {
                workspace.togglePlay()
            } label: {
                Image(systemName: workspace.playing ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(workspace.playing ? "Pause the replay" : "Play the print from the top layer")
            Slider(value: Binding(get: { workspace.scrubFraction }, set: { workspace.scrub(to: $0) }))
                // In the bottom bar the replay has the width of the bar.
                .frame(minWidth: bare ? 110 : 60, maxWidth: bare ? .infinity : 320)
                .help("Moves the nozzle through the top layer")
            // A layer with no lines has no time to show.
            let times = t1 > t0 ? "\(clock(inLayer))/\(clock(t1 - t0))" : "no lines"
            Text(bare ? times : "Layer \(workspace.hi + 1) · \(times)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            Menu("\(Int(workspace.speed))×") {
                ForEach(Workspace.speeds, id: \.self) { s in
                    Toggle("\(Int(s))×", isOn: Binding(get: { workspace.speed == s }, set: { _ in workspace.speed = s }))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The speed of the replay")
        }
        .padding(.horizontal, bare ? 0 : 14)
        .padding(.vertical, bare ? 0 : 8)
        .background(bare ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial), in: Capsule())
    }
}

/// The time as m:ss, or h:mm:ss.
func clock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds).rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// The floating card with the facts of the print, and Export.
struct PrintCard: View {
    let workspace: Workspace
    @Environment(\.self) private var env

    private var model: SliceModel { workspace.model }

    /// The card keeps the facts of the last slice while a new one runs, so
    /// an editor of the card stays open, and shows the progress under them.
    /// It is small: the time, the plastic, Export, and the main settings.
    /// The sums of the core (zs_set_totals) for one plate, or for all
    /// plates with nil.
    private func totals(_ plate: Int?) -> zs_totals? {
        _ = model.plates
        _ = model.stats
        var t = zs_totals()
        let rc = plate.map { zs_set_plate_totals(model.set, $0, &t) } ?? zs_set_totals(model.set, &t)
        return rc == 0 ? t : nil
    }

    /// "All 2 plates: 1h 13m · 30.0 g · 0.75", with the plates that have
    /// no slice yet.
    private func allText(_ t: zs_totals) -> String {
        var text = "All \(t.plates) plates: \(duration(t.time_s)) · " + String(format: "%.1f g", t.filament_g)
        // The cost is in the money of the filament price: no sign, a word.
        if t.cost > 0 { text += String(format: " · cost %.2f", t.cost) }
        if t.missing > 0 { text += " (\(t.missing) slicing)" }
        return text
    }

    private func costHelp(_ t: zs_totals) -> String {
        guard t.cost > 0 else { return "Set the price of the filament (filament.price_per_kg) and the hour rate of the printer (machine.hour_rate) to see the cost." }
        return String(format: "The cost: %.2f of filament and %.2f of printer time.", t.cost_filament, t.cost_machine)
    }

    var body: some View {
        let slicing = model.state == .slicing
        VStack(alignment: .leading, spacing: 8) {
            if !workspace.plateFits, model.state == .done {
                Label(Workspace.offBed, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.state == .done, !workspace.tinyParts.isEmpty {
                let tiny = workspace.tinyParts
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(format: "%@ is only %.2f mm. Was the file in inches or in meters?",
                                 tiny.count == 1 ? tiny[0].name : "\(tiny.count) parts", tiny.map(\.size).max() ?? 0),
                          systemImage: "ruler")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Inches (×25.4)") { workspace.scaleParts(tiny.map(\.index), by: 25.4) }
                        Button("Meters (×1000)") { workspace.scaleParts(tiny.map(\.index), by: 1000) }
                    }
                    .controlSize(.small)
                }
                .font(.callout)
                .padding(8)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            } else if model.state == .done, let text = workspace.simResult?.checkText {
                // The simulated print ran: it replaces the estimate from the
                // area that hangs in the air.
                let off = model.setting("project.support") == "off"
                VStack(alignment: .leading, spacing: 6) {
                    Label(text + (off ? "Turn on support or turn the part." : "Turn the part, or add support there."),
                          systemImage: "exclamationmark.triangle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                    if off {
                        Button("Turn On Support") { model.set("project.support", "everywhere") }
                            .controlSize(.small)
                    }
                }
                .font(.callout)
                .padding(8)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            } else if model.state == .done, let area = workspace.unsupportedArea {
                // The red warning of a part off the bed wins over this one.
                VStack(alignment: .leading, spacing: 6) {
                    Label("About \(Int(area.rounded())) mm² of the part hangs in the air with no support. It can droop or fail.",
                          systemImage: "exclamationmark.triangle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Turn On Support") { model.set("project.support", "everywhere") }
                        .controlSize(.small)
                        .help("Support everywhere a part hangs over the air (Support > Support)")
                }
                .font(.callout)
                .padding(8)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            if case .failed(let why) = model.state {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let s = model.stats {
                        Text(duration(s.print_time_s))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        let plate = totals(model.active)
                        Text(String(format: "%.1f g · %.2f m · %d layers", s.filament_g, s.filament_mm / 1000, s.layer_count)
                            + (plate.map { $0.cost > 0 ? String(format: " · cost %.2f", $0.cost) : "" } ?? ""))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .minimumScaleFactor(0.75)
                            .help(plate.map(costHelp) ?? "")
                        if let all = totals(nil), all.plates >= 2 {
                            Text(allText(all))
                                .font(.callout.monospacedDigit())
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.75)
                                .help("\(all.parts) parts on \(all.plates) plates. " + costHelp(all))
                        }
                    } else {
                        Text("Slicing…").font(.title3.weight(.semibold))
                    }
                }
                .opacity(slicing && model.stats != nil ? 0.5 : 1)
                Spacer(minLength: 0)
            }
            // The progress of a slice, or the time of the last one, in one
            // line of the same height, so the card does not jump.
            Group {
                if slicing {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                } else if let s = workspace.sendState {
                    Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let t = model.sliceSeconds {
                    Text(t < 1 ? String(format: "Sliced in %.0f ms", t * 1000) : String(format: "Sliced in %.1f s", t))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 12, alignment: .leading)
            if let p = workspace.connectedPrinter, workspace.printerStatus != nil || workspace.printerEstimate != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let e = workspace.printerEstimate {
                        Text("\(p.name): \(duration(e.total))" + (e.prep > 0 ? " (\(Int((e.prep / 60).rounded())) min start)" : ""))
                            .font(.callout)
                    }
                    if let s = workspace.printerStatus {
                        Label(s.line, systemImage: "printer").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !workspace.refinements.isEmpty {
                Divider()
                RefinementList(workspace: workspace)
            }
            if model.state != .empty {
                Divider()
                PrintFacts(workspace: workspace)
                Divider()
                FilamentList(model: model)
            }
        }
        .frame(width: 250)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
        .opacity(model.state == .empty ? 0 : 1)
    }

    private func duration(_ seconds: Double) -> String { Self.duration(seconds) }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }
}

/// The usual refinements of the user (Refinements.swift), in the details
/// of the print: each with Apply (one undo step) and a button that hides
/// it for good.
struct RefinementList: View {
    let workspace: Workspace

    var body: some View {
        let list = workspace.refinements
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(list.count == 1 ? "Your usual refinement" : "Your usual refinements: \(list.count)")
                    .font(.callout.weight(.semibold))
                Spacer()
                if list.count > 1 {
                    Button("Apply All") {
                        for r in list { workspace.applyRefinement(r, refresh: false) }
                        workspace.refreshRefinementsSoon()
                    }
                    .controlSize(.small)
                    .help("Apply each refinement (one undo step each)")
                }
            }
            ForEach(list) { r in
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.whereText): \(r.what)").font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("You made this change in \(r.count) other prints.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Apply") { workspace.applyRefinement(r) }.controlSize(.small)
                    Button { workspace.hideRefinement(r) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Do not offer this again")
                }
            }
        }
    }
}

/// Export, or Print on the printer of the plate (with Upload Only and
/// Export in its menu): the button at the right end of the bottom bar.
struct PrintAction: View {
    let workspace: Workspace
    private var model: SliceModel { workspace.model }

    var body: some View {
        if let p = PrinterStore.shared.current, p.kind != .none {
            Menu {
                Button("Upload Only") { workspace.send(print: false) }
                Button("Export G-code…") { workspace.exportGcode(from: NSApp.keyWindow) }
                    .keyboardShortcut("e", modifiers: .command)
            } label: {
                Text(p.kind == .printdeck ? "Print to Printdeck" : "Print")
            } primaryAction: {
                workspace.send(print: true)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(!model.canExport)
            .help(p.kind == .printdeck
                ? "Print on \(p.name) (⌘P), after you confirm that its bed is clear. A deck set to ask waits for a press of Print on it. Its menu: Upload Only, Export G-code."
                : "Print on \(p.name) (⌘P), after you confirm that its bed is clear. Its menu: Upload Only, Export G-code.")
            .keyboardShortcut("p", modifiers: .command)
        } else {
            Button("Export…") { workspace.exportGcode(from: NSApp.keyWindow) }
                .keyboardShortcut("e", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport)
                .help(model.draft ? "The exact slice comes in a moment" : "Export the G-code (⌘E)")
        }

    }
}

/// The one bar at the bottom of the window (the slice is the UI, so the
/// chrome stays small), in one row: the plates | undo, redo, and the
/// history | the replay, which fills the row | the time, a badge of the
/// notes, and Export or Print. A thin line comes before each group. In a
/// narrow window the replay goes to a second row. A click on the time
/// opens the details above the bar (PrintCard): the notes, the totals, and
/// the settings.
struct BottomBar: View {
    let workspace: Workspace
    private var model: SliceModel { workspace.model }
    /// The width of the bar: under it the replay has a row of its own.
    @State private var width: CGFloat = 1200
    static let oneRowWidth: CGFloat = 940

    private var scrub: some View {
        ScrubBar(workspace: workspace, bare: true)
            .opacity(workspace.layerCount > 0 ? 1 : 0)
            .disabled(workspace.layerCount == 0)
    }

    private var line: some View { Divider().frame(height: 26) }

    var body: some View {
        let narrow = width < Self.oneRowWidth
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                PlateBar(workspace: workspace, bare: true)
                    .fixedSize()
                line
                HistoryTools(workspace: workspace)
                if narrow {
                    Spacer(minLength: 0)
                } else {
                    line
                    scrub
                }
                if model.state != .empty {
                    line
                    summary
                }
            }
            if narrow { scrub }
        }
        .padding(.horizontal, 14)
        .frame(height: narrow ? 84 : 56)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .top) {
            if model.state == .slicing {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .offset(y: -3)
            }
        }
        // A note does not open the details: they cover the part. The badge
        // in the warning color is the sign, and a click opens them.
    }

    /// "34.9 g · cost 0.87 · 169 layers": the cost of the active plate
    /// counts the hour rate of the printer.
    private func detail(_ s: zs_stats) -> String {
        var t = zs_totals()
        let cost = zs_set_plate_totals(model.set, model.active, &t) == 0 && t.cost > 0 ? String(format: " · cost %.2f", t.cost) : ""
        return String(format: "%.1f g", s.filament_g) + cost + " · \(s.layer_count) layers"
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Button {
                workspace.detailsOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    if model.failure == nil, let s = model.stats {
                        // The time, and under it the plastic, the cost, and
                        // the layers (the web dock).
                        VStack(alignment: .leading, spacing: 0) {
                            Text(PrintCard.duration(s.print_time_s))
                                .font(.title3.weight(.semibold).monospacedDigit())
                            Text(detail(s))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .opacity(model.state == .slicing ? 0.5 : 1)
                    } else if let why = model.failure {
                        // A slice that failed says why in the bar, not only
                        // in the details.
                        VStack(alignment: .leading, spacing: 0) {
                            Label("Did not slice", systemImage: "exclamationmark.triangle.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color(red: 0xb4 / 255, green: 0x23 / 255, blue: 0x18 / 255))
                            // The short line (else the first sentence); the
                            // details and the tip have all of it.
                            let lines = why.split(separator: "\n", maxSplits: 1)
                            let short = lines.count > 1 ? String(lines[0]) : String(why.split(separator: ".", maxSplits: 1).first ?? "")
                            if !short.isEmpty {
                                Text(short)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help(why.replacingOccurrences(of: "\n", with: ". "))
                    } else {
                        Text("Slicing…").font(.title3.weight(.semibold))
                    }
                    // The problems of the Check (the same count as the Check
                    // button), else the notes of the card, else the usual
                    // refinements.
                    let p = workspace.checkProblems
                    let n = workspace.noteCount
                    let tips = workspace.refinements.count
                    if p > 0 || n > 0 || tips > 0 {
                        // Red (#b42318) for the problems and the warnings, as
                        // on the web and in the GTK app; the refinements in the
                        // accent color.
                        Text(p > 0 ? "\(p) to check" : n > 0 ? "Check" : tips == 1 ? "1 refinement" : "\(tips) refinements")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 18)
                            .background(p == 0 && n == 0 ? Color.accentColor : Color(red: 0xb4 / 255, green: 0x23 / 255, blue: 0x18 / 255), in: Capsule())
                            .help(p > 0 ? "\(p) \(p == 1 ? "problem" : "problems") of the Check to look at"
                                : n > 0 ? "\(n) note\(n == 1 ? "" : "s") on this print" : "\(tips) of your usual refinement\(tips == 1 ? "" : "s")")
                    }
                    Image(systemName: workspace.detailsOpen ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("The details of the print: the notes, the totals, and the settings")
            PrintAction(workspace: workspace)
        }
        .fixedSize()
    }
}

/// The card of an empty plate: what to do first.
struct WelcomeCard: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Drop an STL or 3MF file here").font(.title2.weight(.semibold))
            Text("Or open a model, a project folder, or a project on GitHub.").foregroundStyle(.secondary)
            HStack {
                Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                    .buttonStyle(.borderedProminent)
                Button("Add Models…") { workspace.addModels() }
                Button("Open Project…") { workspace.openProject() }
                Button("From GitHub…") { workspace.askGitHub() }
            }
            if PrinterStore.shared.printers.isEmpty {
                Button("Add Your Printer…") { workspace.pickerOpen = true }
                    .buttonStyle(.link)
            }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The colors of the lines, in the toolbar: a button with the mode, and a
/// popover with the modes and the legend (the line types to show or fade,
/// or the range of a ramp).
struct ColorsButton: View {
    let workspace: Workspace
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            StripIcon(glyph: "colors", on: open)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colors: \(Workspace.colorModes[workspace.colorMode])")
        .help("The colors of the lines, and the legend: the filament, one color for each line type, or the speed, the flow, the layer time, or the line width")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Colors", selection: Bindable(workspace).colorMode) {
                    ForEach(Workspace.colorModes.indices, id: \.self) { i in
                        Text(Workspace.colorModes[i]).tag(i)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Divider()
                Button(workspace.simulated ? "Show the Plan" : "Show the Print as It Forms") {
                    open = false
                    workspace.toggleSimulation()
                }
                .help("The plastic of the slice as it would form: it sags and droops where nothing holds it. It shows after each slice; this switches between it and the plan.")
                .disabled(workspace.model.state != .done)
                if workspace.layerCount > 0 {
                    Divider()
                    Legend(workspace: workspace, bare: true)
                }
            }
            .padding(14)
            .frame(minWidth: 220)
        }
    }
}

/// The windows that opened empty and have nothing yet: a file that opens
/// next takes the place of one, so the start window does not stay behind.
@MainActor
enum EmptyWindows {
    private struct Entry {
        weak var document: NSDocument?
        weak var workspace: Workspace?
    }

    private static var list: [Entry] = []
    /// A file opened in the first seconds of the app with no empty window
    /// to replace: the empty window of the start comes just after it.
    private static var fileAtLaunch: NSWindow?

    static func note(_ doc: NSDocument, _ ws: Workspace) {
        // A launch with a file opens the empty window and the window of the
        // file at once; the empty one goes, and the file takes its place.
        if let w = fileAtLaunch, CACurrentMediaTime() - SessionStore.launch < 5 {
            fileAtLaunch = nil
            if let frame = doc.windowControllers.first?.window?.frame { w.setFrame(frame, display: true) }
            doc.close()
            return
        }
        list.append(Entry(document: doc, workspace: ws))
    }

    /// Closes an empty, unchanged, untitled window, and puts the new
    /// window where it was.
    static func replace(with window: NSWindow, keeping keep: NSDocument) {
        list.removeAll { $0.document == nil || $0.workspace == nil }
        let empty = list.indices.filter { i in
            guard let d = list[i].document, let ws = list[i].workspace, d !== keep else { return false }
            return d.fileURL == nil && !d.isDocumentEdited && ws.model.plates.allSatisfy { $0.parts == 0 } && ws.model.project == nil
        }
        // The window that the user looks at first.
        let front = empty.first { list[$0].document?.windowControllers.first?.window?.isMainWindow == true }
        guard let i = front ?? empty.last, let old = list[i].document else {
            if CACurrentMediaTime() - SessionStore.launch < 5 { fileAtLaunch = window }
            return
        }
        list.remove(at: i)
        if let frame = old.windowControllers.first?.window?.frame { window.setFrame(frame, display: true) }
        old.close()
    }
}

/// The file button of the toolbar: the name of the document (with a dot
/// for unsaved changes), and a menu of the file: open, add models, save,
/// export.
struct FileButton: View {
    let workspace: Workspace

    var body: some View {
        // The generation of the history: the name and the dot follow each step.
        let _ = workspace.model.history.generation
        let doc = workspace.model.document
        let name = doc?.displayName ?? "Untitled"
        Menu {
            Button("New Window") { NSDocumentController.shared.newDocument(nil) }
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
            Divider()
            Button("Add Models to the Plate…") { workspace.addModels() }
            Button("Open Project Folder…") { workspace.openProject() }
            Button("Open Project from GitHub…") { workspace.askGitHub() }
            Divider()
            Button("Save") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
            Button("Save As…") { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) }
            Button("Rename…") { NSApp.sendAction(#selector(NSDocument.rename(_:)), to: nil, from: nil) }
            if let url = doc?.fileURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Export G-code…") { workspace.exportGcode(from: NSApp.keyWindow) }
                .disabled(workspace.model.state != .done)
        } label: {
            HStack(spacing: 5) {
                Text(name).fontWeight(.semibold).fixedSize()
                if doc?.isDocumentEdited == true {
                    Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved changes")
                }
            }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("The file: open, add models, save, and export")
    }
}

/// The menu of the more rare actions, at the right end of the toolbar.
struct MoreMenu: View {
    let workspace: Workspace

    var body: some View {
        Menu {
            Button("Smart Placement") { workspace.smartPlace() }
            Button("Arrange the Plate") { workspace.plateAction(zs_app_plate_arrange, fits: true) }
            Button("Clear the Plate") { workspace.plateAction(zs_app_plate_clear) }
            Divider()
            Button("Show Gaps") { workspace.toggleGaps() }
            Button("Check the Print") { workspace.checkOpen.toggle() }
            Button("History") { workspace.historyOpen = true }
            Divider()
            Button("Keyboard Shortcuts") { workspace.shortcutsOpen = true }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More: placement, checks, the history, and the keys")
    }
}

extension View {
    /// The toolbar shows the file button, not the title of the window
    /// (macOS 15 and later; the Window menu keeps the title).
    @ViewBuilder func hiddenToolbarTitle() -> some View {
        if #available(macOS 15.0, *) { toolbar(removing: .title) } else { self }
    }
}
