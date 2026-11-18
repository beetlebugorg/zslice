//! The window of one document: the 3D view of the plate, with the floating
//! controls over it (docs/internals/one-view.md): the layer slider at the
//! right, the scrub bar at the bottom, and the print card at the bottom
//! right.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
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
    private func open() async {
        document.model = workspace.model
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
        workspace.model.document = doc
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

    /// The 3D view fills the window, under the toolbar too. Each control
    /// is an overlay on an edge of the content area, so no control can make
    /// the window wider than it is: a narrow window shrinks the scrub bar.
    var body: some View {
        Color.clear
            .background { SliceView(canvas: workspace.canvas).ignoresSafeArea() }
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 8) {
                        ToolStrip(workspace: workspace)
                        CheckButtons(workspace: workspace)
                    }
                    // The legend is in the Colors popover of the toolbar.
                    if workspace.checkOpen {
                        CheckPanel(workspace: workspace)
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                // Left of the layer slider and its number.
                GapSummary(workspace: workspace)
                    .padding(.top, 12)
                    .padding(.trailing, 92)
            }
            .overlay(alignment: .trailing) {
                if workspace.layerCount > 0 {
                    LayerSlider(workspace: workspace)
                        .padding(.top, 40)
                        .padding(.bottom, 24)
                        .padding(.trailing, 12)
                }
            }
            .overlay(alignment: .bottom) {
                // The dock and the print card side by side when they fit;
                // else the card above the dock. An empty plate has no card.
                let card = workspace.model.state != .empty
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 12) {
                        Dock(workspace: workspace).fixedSize()
                        Spacer(minLength: 0)
                        if card { PrintCard(workspace: workspace).fixedSize() }
                    }
                    VStack(alignment: .trailing, spacing: 10) {
                        if card { PrintCard(workspace: workspace).fixedSize() }
                        HStack {
                            Dock(workspace: workspace).fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 64)
                // Clear of the layer slider and its number at the right edge.
                .padding(.trailing, 84)
                .padding(.bottom, 16)
            }
            // The cards and the tape float over all the controls, in the coordinates
            // of the view (from the top of the window).
            .overlay {
                GeometryReader { geo in
                    TapeOverlay(workspace: workspace, area: geo.size)
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
                        GapCard(workspace: workspace, gap: gap)
                            .position(x: min(workspace.cardAt.x + 180, geo.size.width - 170), y: min(max(workspace.cardAt.y, 160), geo.size.height - 160))
                    }
                    if workspace.tool == .support, workspace.page == .threeD {
                        SupportCard(workspace: workspace)
                            .position(x: geo.size.width - 145 - 92, y: 200)
                    }
                    if let i = workspace.selectedPart {
                        PartCard(workspace: workspace, index: i, area: geo.size)
                            .id(i)
                    }
                    if workspace.cardOpen, let info = workspace.lineInfo {
                        LineCard(workspace: workspace, info: info, area: geo.size)
                    }
                }
                .ignoresSafeArea()
            }
            // The search last, over the other controls.
            .overlay(alignment: .topLeading) {
                if workspace.searchOpen {
                    SearchOverlay(workspace: workspace)
                        .padding(.leading, 64)
                        .padding(.top, 12)
                }
            }
        .frame(minWidth: 720, minHeight: 480)
        .navigationSubtitle(subtitle)
        // STL and 3MF files dropped on the window go on the active plate.
        .dropDestination(for: URL.self) { urls, _ in
            let models = urls.filter { ["stl", "3mf"].contains($0.pathExtension.lowercased()) }
            for url in models { workspace.addModel(url) }
            return !models.isEmpty
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
        .overlay(alignment: .top) {
            if let note = workspace.note {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 46)
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
        .inspector(isPresented: Binding(get: { workspace.showSettings && !workspace.farmOpen }, set: { workspace.showSettings = $0 })) {
            InspectorPanel(workspace: workspace)
                .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                PrinterMenu(workspace: workspace)
                FilamentMenu(workspace: workspace)
                QualityMenu(workspace: workspace)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspace.showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "sidebar.right")
                }
                .help("Show or hide the settings (N)")
            }
            ToolbarItem(placement: .principal) {
                ColorsButton(workspace: workspace)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { workspace.addModels() } label: { Label("Add Models", systemImage: "plus") }
                    .help("Add models to the plate (⇧⌘I)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { workspace.searchOpen = true } label: { Label("Search", systemImage: "magnifyingglass") }
                    .help("Search the settings and the actions (/ or ⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { workspace.farmOpen.toggle() } label: { Label("Printers", systemImage: "printer.dotmatrix.filled.and.paper") }
                    .help("The printers and their jobs, and the plates to print (⌥⌘P)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Bindable(workspace).page) {
                    Text("3D").tag(MetalSliceView.Page.threeD)
                    Text("2D").tag(MetalSliceView.Page.twoD)
                }
                .pickerStyle(.segmented)
                .help("3D: the layers up to the slider. 2D: one layer from the top. A drag pans, the wheel zooms, a double click fits the part.")
            }
        }
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
                .frame(minWidth: bare ? 110 : 60, idealWidth: bare ? 110 : nil, maxWidth: bare ? 110 : 320)
                .help("Moves the nozzle through the top layer")
            Text(bare ? "\(clock(inLayer))/\(clock(t1 - t0))" : "Layer \(workspace.hi + 1) · \(clock(inLayer)) / \(clock(t1 - t0))")
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
        if t.cost > 0 { text += String(format: " · %.2f", t.cost) }
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
                            + (plate.map { $0.cost > 0 ? String(format: " · %.2f", $0.cost) : "" } ?? ""))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .help(plate.map(costHelp) ?? "")
                        if let all = totals(nil), all.plates >= 2 {
                            Text(allText(all))
                                .font(.callout.monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .help("\(all.parts) parts on \(all.plates) plates. " + costHelp(all))
                        }
                    } else {
                        Text("Slicing…").font(.title3.weight(.semibold))
                    }
                }
                .opacity(slicing && model.stats != nil ? 0.5 : 1)
                Spacer(minLength: 12)
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
                    .disabled(model.state != .done)
                    .help(p.kind == .printdeck
                        ? "Print on \(p.name) (⌘P), after you confirm that its bed is clear. A deck set to ask waits for a press of Print on it. Its menu: Upload Only, Export G-code."
                        : "Print on \(p.name) (⌘P), after you confirm that its bed is clear. Its menu: Upload Only, Export G-code.")
                    .keyboardShortcut("p", modifiers: .command)
                } else {
                    Button("Export…") { workspace.exportGcode(from: NSApp.keyWindow) }
                        .keyboardShortcut("e", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.state != .done)
                        .help("Export the G-code (⌘E)")
                }
            }
            // The progress of a slice, or the time of the last one, in one
            // line of the same height, so the card does not jump.
            Group {
                if slicing {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                } else if let s = workspace.sendState {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                        Label(s.line, systemImage: "printer").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if model.state != .empty {
                Divider()
                PrintFacts(workspace: workspace)
            }
        }
        .frame(width: 250)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
        .opacity(model.state == .empty ? 0 : 1)
    }

    private func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
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

/// The one bar at the bottom of the view: the plates, the replay, and the
/// history, as three groups. It ends where the print card starts.
struct Dock: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            PlateBar(workspace: workspace, bare: true)
            if workspace.layerCount > 0 {
                Divider().frame(height: 18)
                ScrubBar(workspace: workspace, bare: true)
            }
            Divider().frame(height: 18)
            Timeline(history: workspace.model.history, bare: true) { workspace.historyOpen = true }
                .popover(isPresented: Bindable(workspace).historyOpen, arrowEdge: .top) {
                    HistoryPage(history: workspace.model.history, workspace: workspace)
                        .frame(width: 400, height: 480)
                }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
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
            HStack(spacing: 4) {
                Text(Workspace.colorModes[workspace.colorMode])
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .help("The colors of the lines, and the legend: the filament, one color for each line type, or the speed, the flow, the layer time, or the line width")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Colors", selection: Bindable(workspace).colorMode) {
                    ForEach(Workspace.colorModes.indices, id: \.self) { i in
                        Text(Workspace.colorModes[i]).tag(i)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
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
