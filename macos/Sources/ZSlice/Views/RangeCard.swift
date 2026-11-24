//! The card of a range of layers (LayerRange.swift; web/app/rangecard.js,
//! linux/src/ui/range-card.c): the layers, their z, and the settings that
//! people change most for some layers, each with an editor in the scope
//! of those layers. A change slices at once.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct RangeCard: View {
    let workspace: Workspace
    let lo: Int, hi: Int

    /// The settings of the card, in order, when the setting can change for
    /// some layers (RANGE_SETTINGS of web/app/rangecard.js).
    static let settings = [
        // The filament of the layers: a change at the first layer, and back
        // after the last.
        "project.filament",
        "project.infill_density", "project.infill_pattern", "project.wall_count", "project.top_thickness",
        "project.outer_wall_speed", "project.infill_speed", "filament.fan_speed", "filament.nozzle_temp",
    ]

    var body: some View {
        let model = workspace.model
        let a = workspace.layerTopBottom(lo), b = workspace.layerTopBottom(hi)
        let n = hi - lo + 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(lo == hi ? "Layer \(lo + 1)" : "Layers \(lo + 1)–\(hi + 1)").font(.headline)
                Spacer()
                Button { workspace.closeRangeCard() } label: {
                    CloseMark()
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
            }
            if let a, let b {
                Text(String(format: "z %.2f to %.2f mm · %d %@", a.bottom, b.top, n, n == 1 ? "layer" : "layers"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Changes here are for these layers of this print.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            // The lit body of a drag from a line: its own filament.
            if workspace.rangeLine != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("This body")
                        .help("The filament of the lit body only, on these layers. The paint of the part keeps it. The filament of the part takes the paint away.")
                    Spacer(minLength: 8)
                    FilamentChips(model: model, value: String(workspace.rangeBodyFilament > 0 ? workspace.rangeBodyFilament : Int(Double(model.entry("project.filament").value) ?? 1))) { v in
                        if let f = Int(v), let why = workspace.paintBody(f) { workspace.showNote(why) }
                    }
                }
            }
            ForEach(Self.settings.compactMap { SettingInfo.byName[$0] }.filter(\.perLayer)) { s in
                HStack(alignment: .firstTextBaseline) {
                    Text(s.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(s.doc)
                    Spacer(minLength: 8)
                    SettingEditor(model: model, info: s, entry: model.entry(s.name), compact: true)
                }
            }
        }
        .onKeyPress(.escape) {
            workspace.closeRangeCard()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The selected layers")
    }
}
