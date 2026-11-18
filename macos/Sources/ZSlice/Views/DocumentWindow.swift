//! The window of one document: the 3D view of the plate, with the floating
//! controls over it (docs/internals/one-view.md): the layer slider at the
//! right, the scrub bar at the bottom, and the print card at the bottom
//! right.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct DocumentWindow: View {
    let document: ModelDocument
    let name: String
    @State private var workspace = Workspace()
    @State private var loadError: String?

    var body: some View {
        ZStack {
            SliceView(canvas: workspace.canvas)
                .ignoresSafeArea()
            // The cards float over the view, in the coordinates of the view.
            GeometryReader { geo in
                if workspace.cardOpen, let info = workspace.lineInfo {
                    LineCard(workspace: workspace, info: info, area: geo.size)
                }
            }
            .ignoresSafeArea()
            VStack {
                HStack {
                    Legend(workspace: workspace)
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
            if workspace.layerCount > 0 {
                HStack {
                    Spacer()
                    LayerSlider(workspace: workspace)
                        .padding(.vertical, 40)
                        .padding(.trailing, 12)
                }
                .padding(.bottom, 120)
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    if workspace.layerCount > 0 { ScrubBar(workspace: workspace) }
                    Spacer()
                    PrintCard(workspace: workspace)
                        // Clear of the layer slider at the right edge.
                        .padding(.trailing, 36)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .inspector(isPresented: Bindable(workspace).showSettings) {
            InspectorPanel(workspace: workspace)
                .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
        }
        .toolbar {
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
            do {
                try workspace.model.load(name: name, data: document.data)
            } catch {
                loadError = error.localizedDescription
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
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            switch workspace.drawerPage {
            case .settings: SettingsInspector(workspace: workspace)
            case .history: HistoryPage(history: workspace.model.history)
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
                .frame(minWidth: 160, maxWidth: 320)
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
    /// an editor of the card stays open, and shows the progress over them.
    var body: some View {
        let slicing = model.state == .slicing
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let why) = model.state {
                Label(why, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: 260, alignment: .leading)
            }
            if slicing {
                ProgressView(value: model.progress) { Text("Slicing…").font(.caption) }
                    .frame(width: 260)
            }
            if let s = model.stats {
                Group {
                    Text(duration(s.print_time_s)).font(.title2.weight(.semibold))
                    Text(String(format: "%.1f g · %.2f m", s.filament_g, s.filament_mm / 1000))
                    Text("\(s.layer_count) layers").foregroundStyle(.secondary)
                }
                .opacity(slicing ? 0.5 : 1)
            }
            if model.state != .empty {
                PrintFacts(workspace: workspace).padding(.top, 2)
            }
            if model.stats != nil {
                Button("Export G-code…") {
                    workspace.exportGcode(from: NSApp.keyWindow)
                }
                .keyboardShortcut("e", modifiers: .command)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.state != .done)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(model.state == .empty ? 0 : 1)
    }

    private func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }
}
