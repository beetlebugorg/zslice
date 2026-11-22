//! The Project page of the drawer (docs/user/projects.md): the plates of
//! the open project, with their states, and its parts by group, each with
//! a check box and a count. A change plans the plates again and loads them
//! (zs_set_project_load with the counts). A click on a plate goes to it.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct ProjectPage: View {
    let workspace: Workspace

    private var model: SliceModel { workspace.model }

    var body: some View {
        if let project = model.project {
            List {
                Section("Plates") {
                    ForEach(model.plates.indices.map { "plate-\($0)" }, id: \.self) { key in
                        let i = Int(key.dropFirst(6))!
                        let p = model.plates[i]
                        Button { workspace.selectPlate(i) } label: {
                            HStack {
                                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name.isEmpty ? "Plate \(i + 1)" : p.name).fixedSize(horizontal: false, vertical: true)
                                    Text(state(p)).font(.caption).foregroundStyle(p.status == ZS_PLATE_STATUS_FAILED.rawValue ? .red : .secondary)
                                }
                                Spacer()
                                if i == model.active { Image(systemName: "eye").foregroundStyle(Color.accentColor) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Each row has an id of its own kind: a plate and a part with
                // the same index are two rows.
                ForEach(groups(project), id: \.self) { g in
                    Section(g.isEmpty ? "Parts" : g) {
                        ForEach(project.parts.filter { $0.group == g }, id: \.rowID) { part in
                            PartRow(workspace: workspace, project: project, part: part)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No Project", systemImage: "folder",
                                   description: Text("File > Open Project Folder opens a repository with a printdeck.yml."))
        }
    }

    private func groups(_ p: ProjectState) -> [String] {
        var seen = Set<String>()
        return p.parts.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    private func state(_ p: PlateInfo) -> String {
        let parts = "\(p.parts) part\(p.parts == 1 ? "" : "s")"
        switch Int(p.status) {
        case Int(ZS_PLATE_STATUS_SLICING.rawValue): return "\(parts) · slicing"
        case Int(ZS_PLATE_STATUS_STALE.rawValue): return "\(parts) · waits to slice"
        case Int(ZS_PLATE_STATUS_FAILED.rawValue): return p.message.isEmpty ? "failed" : p.message
        case Int(ZS_PLATE_STATUS_CANNOT.rawValue): return "\(parts) · zslice cannot slice it (resin)"
        case Int(ZS_PLATE_STATUS_EMPTY.rawValue): return "empty"
        default: return "\(parts) · sliced"
        }
    }
}

private struct PartRow: View {
    let workspace: Workspace
    let project: ProjectState
    let part: Project.Part

    var body: some View {
        let n = project.count(part.id)
        HStack {
            Toggle(isOn: Binding(get: { n > 0 }, set: { set($0 ? 1 : 0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.name)
                    if !part.printer.isEmpty {
                        Text(part.printer).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .help(part.description)
            Spacer()
            Stepper("\(n)", value: Binding(get: { n }, set: { set($0) }), in: 0 ... 99)
                .monospacedDigit()
                .fixedSize()
        }
    }

    private func set(_ count: Int) {
        var counts = project.counts
        while counts.count < project.parts.count { counts.append(nil) }
        counts[part.id] = count
        workspace.openProject(project.source, counts: counts)
    }
}
