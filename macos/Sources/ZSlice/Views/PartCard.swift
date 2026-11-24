//! The page of a selected part in the Inspector (InspectorDock.swift,
//! docs/user/getting-started.md, web/app/partcard.js). A click on a part
//! with the Move or the Turn tool, or Command and a click with any tool,
//! selects it. The page has its name and size, then groups that the user
//! can collapse: Position and turn, Size and mirror, Filament, Actions, and
//! Settings of this part. The values of the part and the values of its
//! regions show apart. The scale shows with no sign, and a Mirrored mark
//! says that the part is a mirror image.
//!
//! With several parts selected (Shift and a click), the page shows how
//! many, and the actions for all of them: Duplicate, Arrange the Plate, To
//! a New Plate, and Remove (web/app/partcard.js, linux/src/ui/part-card.c).
//! A drag of one of them with the Move tool (or Command), or the arrow
//! keys, moves them all.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct PartCard: View {
    let workspace: Workspace
    let index: Int
    @State private var count = 10

    var body: some View {
        if !workspace.moreParts.isEmpty {
            many
        } else if let p = workspace.part(index) {
            let own = workspace.partSettings(index)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(coreText(p.name).isEmpty ? "Part \(index + 1)" : coreText(p.name))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { workspace.selectPart(nil) } label: {
                        CloseMark()
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the selection (Esc)")
                }
                Text(String(format: "%.1f × %.1f × %.1f mm", p.size_x, p.size_y, p.size_z))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                InspectorGroup(workspace: workspace, title: "Position and turn") {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            PoseField(label: "X", value: p.x, help: "The place of the center of the part along X of the bed, mm") { workspace.setPose(index, "x", $0) }
                            PoseField(label: "Y", value: p.y, help: "The place of the center of the part along Y of the bed, mm") { workspace.setPose(index, "y", $0) }
                            PoseField(label: "Z", value: p.z, help: "The lift: the bottom of the part over the bed, mm. Over 0 it floats, and prints on support") { workspace.setPose(index, "z", $0) }
                        }
                        GridRow {
                            PoseField(label: "↻X", value: p.angle_x, help: "The turn about the X axis of the bed, degrees") { workspace.setPose(index, "ax", $0) }
                            PoseField(label: "↻Y", value: p.angle_y, help: "The turn about the Y axis of the bed, degrees") { workspace.setPose(index, "ay", $0) }
                            PoseField(label: "↻Z", value: p.angle_z, help: "The turn about the Z axis of the bed, degrees") { workspace.setPose(index, "az", $0) }
                        }
                    }
                }
                InspectorGroup(workspace: workspace, title: "Size and mirror") {
                    ScaleField(workspace: workspace, index: index, part: p)
                    HStack {
                        Button("Mirror X") { workspace.mirrorParts(axis: 0) }.help("Mirror the part from left to right")
                        Button("Mirror Y") { workspace.mirrorParts(axis: 1) }.help("Mirror the part from front to back")
                        Button("Reset") { workspace.resetPart() }.help("The orientation and the scale of the file again")
                    }
                    .controlSize(.small)
                }
                if SettingInfo.byName["project.filament"] != nil {
                    InspectorGroup(workspace: workspace, title: "Filament") {
                        FilamentChips(model: workspace.model,
                                      value: own.first { $0.info.name == "project.filament" }?.value ?? workspace.model.entry("project.filament").value) { v in
                            for i in workspace.selectedParts { workspace.setPartSetting(i, "project.filament", v) }
                        }
                    }
                }
                InspectorGroup(workspace: workspace, title: "Actions") { actions }
                let labels = workspace.partLabels(index)
                if !labels.isEmpty {
                    InspectorGroup(workspace: workspace, title: "Labels") {
                        ForEach(labels) { l in
                            Button { workspace.openLabel(part: index, id: l.id) } label: {
                                Label(l.title, systemImage: "character.textbox").fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.borderless)
                            .help("Select this label in the Label tool (E)")
                        }
                    }
                }
                InspectorGroup(workspace: workspace, title: "Settings of this part") {
                    let rest = own.filter { $0.info.name != "project.filament" }
                    ForEach(rest, id: \.info.name) { s in
                        PartSettingRow(workspace: workspace, index: index, info: s.info, value: s.value)
                    }
                    // A region has its own values: they are not values of the part.
                    ForEach(workspace.partRegions(index), id: \.name) { r in
                        Text("Region: \(r.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(r.rows, id: \.info.name) { row in
                            HStack {
                                Text(row.info.label)
                                Spacer()
                                Text(ValueText.withUnit(row.info, row.value)).foregroundStyle(.secondary)
                            }
                            .help("This value is for this region only. Drag over its layers to change it.")
                        }
                    }
                    Button("Part Settings…") { workspace.editScope(.part(index)) }
                        .buttonStyle(.link)
                    Menu("Add a Setting for This Part") {
                        ForEach(sections, id: \.self) { section in
                            Menu(section.isEmpty ? "General" : section) {
                                ForEach(SettingInfo.all.filter { s in s.perPart && s.section == section && !own.contains(where: { $0.info.name == s.name }) }) { info in
                                    Button(info.label) {
                                        workspace.setPartSetting(index, info.name, workspace.model.entry(info.name).value)
                                    }
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            Button("Duplicate") { workspace.duplicatePart() }.help("A copy at a free place (D)")
            Button("Split") { workspace.splitPart() }.help("Split to parts: each separate body of the part becomes a part of its own")
            Button("Cut…") { workspace.cutOpen = true }
                .help("Cut the part with a level plane into two parts, with pegs to line them up")
                .popover(isPresented: Binding(get: { workspace.cutOpen }, set: { workspace.cutOpen = $0 }), arrowEdge: .bottom) {
                    CutPopover(workspace: workspace, index: index, open: Binding(get: { workspace.cutOpen }, set: { workspace.cutOpen = $0 }))
                }
            Menu("Orient") {
                Button("Best Orientation") { workspace.placePart(Int32(ZS_PLACE_SMART.rawValue)) }
                Button("Less Support") { workspace.placePart(Int32(ZS_PLACE_LESS_SUPPORT.rawValue)) }
            }
            .fixedSize()
        }
        .controlSize(.small)
        // One part at a time: the place of the part in the order.
        if let o = workspace.printOrder(index) {
            HStack {
                Text("Prints \(o.index + 1) of \(o.count)").font(.callout)
                Spacer()
                Button("Print Earlier") { workspace.reorderPart(index, by: -1) }
                    .disabled(o.index == 0)
                    .help("Print this part before the part before it in the plate list")
                Button("Print Later") { workspace.reorderPart(index, by: 1) }
                    .disabled(o.index >= o.count - 1)
                    .help("Print this part after the part after it in the plate list")
            }
            .controlSize(.small)
        }
        HStack(spacing: 6) {
            Text("Make")
            TextField("Count", value: $count, format: .number)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .onSubmit { workspace.fillPart(count) }
            Stepper("", value: $count, in: 2 ... 9999).labelsHidden()
            Text("in all")
            Spacer()
            Button("Make") { workspace.fillPart(count) }
                .controlSize(.small)
        }
        .help("Copies of the part until there are this many in all: on this plate while they fit, then on new plates with the same settings")
        HStack {
            Button("To a New Plate") { workspace.movePartToNewPlate() }
                .help("The part goes to a new plate with the settings of this one")
            Spacer()
            Button(role: .destructive) { workspace.removePart() } label: { Label("Remove", systemImage: "trash") }
                .help("Remove the part (Delete)")
        }
        .controlSize(.small)
    }

    /// The page of several parts (Shift and a click): how many, their
    /// extent on the bed, and the actions for all of them.
    private var many: some View {
        let list = workspace.selectedParts
        let parts = list.compactMap { workspace.part($0) }
        let x0 = parts.map { $0.x - $0.size_x / 2 }.min() ?? 0, x1 = parts.map { $0.x + $0.size_x / 2 }.max() ?? 0
        let y0 = parts.map { $0.y - $0.size_y / 2 }.min() ?? 0, y1 = parts.map { $0.y + $0.size_y / 2 }.max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(list.count) parts").font(.headline)
                Spacer()
                Button { workspace.selectPart(nil) } label: {
                    CloseMark()
                }
                .buttonStyle(.borderless)
                .help("Clear the selection (Esc)")
            }
            Text(String(format: "%.1f × %.1f mm on the bed", x1 - x0, y1 - y0))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack {
                Button("Duplicate") { workspace.duplicatePart() }.help("A copy of each part at a free place on the bed (D)")
                Button("Arrange the Plate") { workspace.plateAction(zs_app_plate_arrange, fits: true) }
                    .help("Put all parts of the plate in rows, apart from each other")
            }
            HStack {
                Button("To a New Plate") { workspace.movePartsToNewPlate() }
                    .help("Move these parts to one new plate, with the settings of this plate")
                Button("Remove", role: .destructive) { workspace.removePart() }
                    .help("Remove these parts from the plate (Delete). Command-Z brings them back.")
            }
            Text("To move them all: drag one of them with the Move tool (or Command and a drag), or press the arrow keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sections: [String] {
        var seen = Set<String>()
        return SettingInfo.all.filter(\.perPart).compactMap { seen.insert($0.section).inserted ? $0.section : nil }
    }
}

/// One number of the pose of a part. Return or leaving the field applies.
private struct PoseField: View {
    let label: String
    let value: Double
    let help: String
    let apply: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            TextField(label, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 48)
                .focused($focused)
                .onSubmit(send)
        }
        .help(help)
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { if !focused { text = Self.format(value) } }
        .onChange(of: focused) { if !focused { send() } }
    }

    private func send() {
        guard text != Self.format(value), let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite else {
            text = Self.format(value)
            return
        }
        apply(v)
    }

    private static func format(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return ValueText.number(r == 0 ? 0 : r)
    }
}

/// One setting of a part: its label, its value, and × for the value of the
/// plate again.
private struct PartSettingRow: View {
    let workspace: Workspace
    let index: Int
    let info: SettingInfo
    let value: String
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        HStack {
            Text(info.label).help(info.doc)
            Spacer()
            switch info.kind {
            case .boolean:
                Toggle(info.label, isOn: Binding(get: { value == "true" }, set: { workspace.setPartSetting(index, info.name, $0 ? "true" : "false") }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            case .choice:
                Picker(info.label, selection: Binding(get: { value }, set: { workspace.setPartSetting(index, info.name, $0) })) {
                    ForEach(info.choices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
            default:
                TextField(info.label, text: $text)
                    .labelsHidden()
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(error != nil ? Color.red : .primary)
                    .help(error ?? info.doc)
                    .onSubmit { error = workspace.setPartSetting(index, info.name, ValueText.toCore(info, text)) }
                if !info.unit.isEmpty { Text(info.unit).foregroundStyle(.secondary) }
            }
            Button { workspace.setPartSetting(index, info.name, nil) } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("The value of the plate again")
        }
        .onAppear { text = ValueText.display(info, value) }
        .onChange(of: value) { text = ValueText.display(info, value) }
    }
}

/// The size of a part in % of its file, with no sign. A new size keeps the
/// sign of each axis, and a Mirrored mark shows a mirror image (an odd count
/// of negative axes).
private struct ScaleField: View {
    let workspace: Workspace
    let index: Int
    let part: zs_part
    @State private var text = ""

    private var size: Double { abs(part.scale_x) }
    private var mirrored: Bool { [part.scale_x, part.scale_y, part.scale_z].filter { $0 < 0 }.count % 2 == 1 }
    private var even: Bool { pct(part.scale_x) == pct(part.scale_y) && pct(part.scale_y) == pct(part.scale_z) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Scale")
                TextField("Scale", text: $text)
                    .labelsHidden()
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0, size > 0 else {
                            text = pct(part.scale_x)
                            return
                        }
                        workspace.scaleParts([index], by: v / 100 / size)
                    }
                Text("%").foregroundStyle(.secondary)
                if mirrored {
                    Text("Mirrored")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .help("This part is a mirror image of its file. Mirror X or Mirror Y again, or Reset, removes the mirror.")
                }
            }
            if !even {
                Text("Each axis has its own size: X \(pct(part.scale_x)) %, Y \(pct(part.scale_y)) %, Z \(pct(part.scale_z)) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("The size of the part, in % of the file. A mirrored part stays mirrored.")
        .onAppear { text = pct(part.scale_x) }
        .onChange(of: part.scale_x) { text = pct(part.scale_x) }
    }

    private func pct(_ s: Double) -> String { ValueText.number((abs(s) * 10000).rounded() / 100) }
}
