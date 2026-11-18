//! The window of one document: the 3D view of the plate, with the floating
//! controls over it (docs/internals/one-view.md): the layer slider at the
//! right, the scrub bar at the bottom, and the print card at the bottom
//! right.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct DocumentWindow: View {
    /// The file of the window, or nil for a window with an empty plate.
    let document: ModelDocument?
    let name: String
    @State private var workspace = Workspace()
    @State private var loadError: String?
    @State private var dropping = false

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
                    if workspace.checkOpen {
                        CheckPanel(workspace: workspace)
                    } else if workspace.layerCount > 0 {
                        Legend(workspace: workspace)
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .top) {
                Timeline(history: workspace.model.history).padding(.top, 12)
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
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        PlateBar(workspace: workspace)
                        if workspace.layerCount > 0 {
                            ScrubBar(workspace: workspace)
                        }
                    }
                    Spacer(minLength: 0)
                    PrintCard(workspace: workspace)
                        .fixedSize()
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
        .sheet(isPresented: Bindable(workspace).shortcutsOpen) { ShortcutSheet() }
        .sheet(isPresented: Bindable(workspace).pickerOpen) { PrinterPicker(workspace: workspace) }
        .inspector(isPresented: Bindable(workspace).showSettings) {
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
                Picker("Colors", selection: Bindable(workspace).colorMode) {
                    ForEach(Workspace.colorModes.indices, id: \.self) { i in
                        Text(Workspace.colorModes[i]).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("The colors of the lines: the filament, one color for each line type, or the speed, the flow, the layer time, or the line width")
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
        .task {
            guard let document else { return }
            do {
                try workspace.model.load(name: name, data: document.data)
            } catch {
                loadError = error.localizedDescription
            }
        }
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

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: Bindable(workspace).drawerPage) {
                Text("Settings").tag(Workspace.DrawerPage.settings)
                Text("History").tag(Workspace.DrawerPage.history)
                if workspace.model.project != nil {
                    Text("Project").tag(Workspace.DrawerPage.project)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            switch workspace.drawerPage {
            case .settings: SettingsInspector(workspace: workspace)
            case .history: HistoryPage(history: workspace.model.history)
            case .project: ProjectPage(workspace: workspace)
            }
        }
    }
}

extension FocusedValues {
    /// The model of the window in front, for the menu commands.
    @Entry var workspace: Workspace?
}

/// The scrub bar: play, the time in the top layer, and the replay speed.
struct ScrubBar: View {
    let workspace: Workspace

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
                .frame(minWidth: 60, maxWidth: 320)
                .help("Moves the nozzle through the top layer")
            Text("Layer \(workspace.hi + 1) · \(clock(inLayer)) / \(clock(t1 - t0))")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
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
    var body: some View {
        let slicing = model.state == .slicing
        VStack(alignment: .leading, spacing: 8) {
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
                        Text(String(format: "%.1f g · %.2f m · %d layers", s.filament_g, s.filament_mm / 1000, s.layer_count))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
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
                        Text("Print")
                    } primaryAction: {
                        workspace.send(print: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(model.state != .done)
                    .help("Print on \(p.name) (⌘P). Its menu: Upload Only, Export G-code.")
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
