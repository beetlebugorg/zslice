//! The card of the Support tool (Support.swift): the kind of the selected
//! area, or of the next one (Grid, Tree, Block), "See through the support",
//! what to do next, and Delete for a selected area. With tree support:
//! Add a Branch, Reset Support, Delete Branch, and what to do with the
//! trees (SupportTrees.swift).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
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
            // The help of the trees replaces it while a tree is in use.
            if area != nil || !(workspace.treeAdding || workspace.treeSelection != nil) {
                Text(info(area))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if area != nil {
                Button("Delete Area", role: .destructive) { workspace.removeSupportArea() }
                    .help("Delete this area (Delete)")
            }
            if !workspace.supportTrees.isEmpty || workspace.treeAdding {
                Divider()
                trees
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The trees: the buttons and the text.
    @ViewBuilder private var trees: some View {
        HStack(spacing: 6) {
            Toggle("Add Branch", isOn: Binding(get: { workspace.treeAdding }, set: { workspace.setTreeAdding($0) }))
                .toggleStyle(.button)
                .help("Click the bed for the foot of a new branch, then the part where it needs support")
            if workspace.treeResetPart != nil {
                Button("Reset") { workspace.resetTrees() }
                    .help("Plan the trees of this part again, with no edits")
            }
            if workspace.treeSelection != nil {
                Button("Delete Branch", role: .destructive) { workspace.deleteTreeBranch() }
                    .help("Delete this branch and the branches over it (Delete)")
            }
        }
        .controlSize(.small)
        Text(workspace.treeInfo)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let limit = workspace.treeLimit {
            Text(limit)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func info(_ area: SupportArea?) -> String {
        if let area {
            return String(format: "%d points, z %.2f to %.2f mm. Drag a point to move it.", area.points.count, area.zLo, area.zHi)
        }
        let n = workspace.supportDraft.count
        switch n {
        case 0: return "Click a lit overhang to support it. Option-click: draw an area."
        case 1, 2: return "\(n) point\(n == 1 ? "" : "s"). Click more points (at least 3). Delete removes the last one; Esc stops."
        default: return "\(n) points. Click the first point, or press Return, to close the area."
        }
    }
}

/// The card of a support that the Select tool picked (SupportPick.swift):
/// what it is, and Delete Branch for a tree, or Remove This Support for a
/// grid support.
struct PickedSupportCard: View {
    let workspace: Workspace

    /// The kinds of "Make it", with their tips.
    static let kinds: [(label: String, kind: zs_mark_kind, tip: String)] = [
        ("Grid", ZS_MARK_GRID, "Grid support: lines under all of the overhang"),
        ("Tree", ZS_MARK_TREE, "Tree support: branches to points under the overhang"),
        ("Pad", ZS_MARK_BRIDGE, "A bridge pad: one layer of support under the overhang"),
    ]

    var body: some View {
        let tree = workspace.supportPick?.tree == true
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(tree ? "Support Tree" : "Support").font(.headline)
                Spacer()
                Button { workspace.clearSupportPick() } label: {
                    CloseMark()
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
            }
            Text(workspace.supportPickInfo)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let limit = workspace.treeLimit {
                Text(limit).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if tree, workspace.treeSelection != nil {
                Button("Delete Branch", role: .destructive) { workspace.removePickedSupport() }
                    .help("Delete this branch and the branches over it (Delete)")
            } else if workspace.supportPick?.overhang != nil {
                Button("Remove This Support", role: .destructive) { workspace.removePickedSupport() }
                    .help("No support under this overhang (Delete)")
            }
            HStack(spacing: 6) {
                Text("Make it:").font(.callout).foregroundStyle(.secondary)
                ForEach(Self.kinds, id: \.label) { k in
                    Button(k.label) { workspace.kindPickedSupport(k.kind) }
                        .help(k.tip)
                        .disabled(workspace.supportPick?.overhang == nil || (tree ? 1 : 0) == k.kind.rawValue)
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
