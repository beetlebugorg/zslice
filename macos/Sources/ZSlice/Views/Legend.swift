//! The legend of the colors of the view, at the top left.
//!
//! With the line type colors, it lists the line types of the print (the
//! features that the slice has, and the marks), each with its color. A
//! click on a line type shows it or fades it: the lines that do not show
//! become faint ghosts (zs_view_focus), so a line type inside the part
//! shows. Option-click shows only that line type. With a ramp of a value
//! (speed, flow, layer time, line width), it shows the range of the ramp.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct Legend: View {
    let workspace: Workspace

    private static let stops = [(0.19, 0.29, 0.86), (0.10, 0.70, 0.85), (0.25, 0.75, 0.30), (0.95, 0.80, 0.15), (0.85, 0.20, 0.15)]
        .map { Color(red: $0.0, green: $0.1, blue: $0.2) }

    var body: some View {
        let mode = workspace.colorMode
        VStack(alignment: .leading, spacing: 6) {
            if mode == 1 || workspace.shownTypes != 0 {
                types
            }
            if let lg = workspace.legend {
                ramp(lg, mode: mode)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .opacity(mode == 1 || workspace.shownTypes != 0 || workspace.legend != nil ? 1 : 0)
    }

    /// The line types that the print has (with a time in the slice), and
    /// the marks.
    private var present: [Int] {
        let stats = workspace.model.state == .done ? workspace.model.featureStats() : nil
        let features = (0 ..< Feature.count).filter { f in stats.map { $0[f].paths > 0 } ?? true }
        return features + [Feature.count, Feature.count + 1, Feature.count + 2]
    }

    private var types: some View {
        let shown = workspace.shownTypes
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Line Types").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if shown != 0 {
                    Button("Show All") { workspace.shownTypes = 0 }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            ForEach(present, id: \.self) { f in
                let on = shown == 0 ? f < Feature.count : (shown >> UInt32(f)) & 1 != 0
                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        workspace.shownTypes = UInt32(1) << UInt32(f)
                    } else {
                        workspace.toggleType(f)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Feature.colors[f]).frame(width: 9, height: 9).opacity(on ? 1 : 0.3)
                        Text(Feature.titles[f]).foregroundStyle(on ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(on ? "Click to fade the \(Feature.titles[f]) lines. Option-click to show only them."
                         : "Click to show the \(Feature.titles[f]) lines. Option-click to show only them.")
            }
        }
        .frame(width: 170)
    }

    private func ramp(_ lg: (lo: Double, hi: Double), mode: Int) -> some View {
        let unit = Workspace.legendUnits[min(mode, Workspace.legendUnits.count - 1)]
        let digits = mode == 5 ? 2 : 0
        let lo = String(format: "%.\(digits)f", lg.lo), hi = String(format: "%.\(digits)f", lg.hi)
        return VStack(alignment: .leading, spacing: 3) {
            Text(Workspace.colorModes[mode]).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            // The stops of the ramp of the core (ramp in src/render/view.zig);
            // the layer time goes the other way (red: short).
            LinearGradient(colors: mode == 4 ? Self.stops.reversed() : Self.stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 170, height: 8)
                .clipShape(Capsule())
            HStack {
                Text("\(lo) \(unit)")
                Spacer()
                Text("\(hi) \(unit)")
            }
            .font(.caption.monospacedDigit())
            if mode == 4 { Text("Red: a short layer").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(width: 170)
    }
}
