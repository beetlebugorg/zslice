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
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.state {
            case .slicing:
                ProgressView(value: model.progress) { Text("Slicing") }
                    .frame(width: 200)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: 260, alignment: .leading)
            case .done:
                if let s = model.stats {
                    Text(duration(s.print_time_s)).font(.title2.weight(.semibold))
                    Text(String(format: "%.1f g · %.2f m", s.filament_g, s.filament_mm / 1000))
                    Text("\(s.layer_count) layers").foregroundStyle(.secondary)
                    Button("Export G-code…") {
                        workspace.exportGcode(from: NSApp.keyWindow)
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            default:
                EmptyView()
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(model.state == .empty || model.state == .ready ? 0 : 1)
    }

    private func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }
}
