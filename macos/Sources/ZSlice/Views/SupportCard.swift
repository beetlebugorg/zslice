//! The card of the Support tool (Support.swift): the kind of the selected
//! area, or of the next one (Grid, Tree, Block), "See through the support",
//! what to do next, and Delete for a selected area.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct SupportCard: View {
    let workspace: Workspace

    var body: some View {
        let sel = workspace.supportSelected.flatMap { $0 < workspace.supportAreas.count ? $0 : nil }
        let area = sel.map { workspace.supportAreas[$0] }
        VStack(alignment: .leading, spacing: 10) {
            Text(sel.map { "Support Area \($0 + 1)" } ?? "Draw Support").font(.headline)
            Picker("Kind", selection: Binding(get: { area?.kind ?? workspace.supportKind }, set: { workspace.setSupportKind($0) })) {
                ForEach(Workspace.supportKinds, id: \.kind) { k in Text(k.name).tag(k.kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Grid or Tree: support under all of the part in the area that faces down, also where the support angle gives none. Block: no support there.")
            Toggle("See through the support", isOn: Bindable(workspace).supportSee)
                .help("The support lines are faint, so the outlines of the areas show through them")
            Text(info(area))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if area != nil {
                Button("Delete Area", role: .destructive) { workspace.removeSupportArea() }
                    .help("Delete this area (Delete)")
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func info(_ area: SupportArea?) -> String {
        if let area {
            return String(format: "%d points, z %.2f to %.2f mm. Drag a point to move it.", area.points.count, area.zLo, area.zHi)
        }
        let n = workspace.supportDraft.count
        switch n {
        case 0: return "Click points on the part to draw an area. The points snap to the lines; Shift: no snap. Click an outline to select its area."
        case 1, 2: return "\(n) point\(n == 1 ? "" : "s"). Click more points (at least 3). Delete removes the last one; Esc stops."
        default: return "\(n) points. Click the first point, or press Return, to close the area."
        }
    }
}
