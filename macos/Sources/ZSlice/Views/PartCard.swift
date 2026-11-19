//! The card of a selected part (docs/user/getting-started.md, "The part
//! card"; web/app/partcard.js). A click on a part with the Move or the Turn
//! tool, or Command and a click with any tool, selects it, and the card
//! opens at the top right of the view: its name, its size, and its turn; Duplicate (D),
//! Split, Cut (CutPopover.swift), Best
//! Orientation, Less Support, Reset, and Remove (Delete); and the settings
//! that the part has of its own, each with an editor and a button that
//! gives it the value of the plate again. "Add a Setting" lists the
//! settings that a part can have of its own.
//!
//! With several parts selected (Shift and a click), the card shows how
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
    let area: CGSize
    @State private var drag: CGSize = .zero
    @State private var moved: CGPoint?
    @State private var count = 10

    var body: some View {
        if !workspace.moreParts.isEmpty {
            many
        } else if let p = workspace.part(index) {
            let own = workspace.partSettings(index)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(coreText(p.name).isEmpty ? "Part \(index + 1)" : coreText(p.name))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button { workspace.selectPart(nil) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
                }
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { g in
                        let c = place
                        moved = CGPoint(x: c.x + g.translation.width, y: c.y + g.translation.height)
                        drag = .zero
                    })
                HStack {
                    Text(String(format: "%.1f × %.1f × %.1f mm · turned %.0f°", p.size_x, p.size_y, p.size_z, p.rotation))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    ScaleField(workspace: workspace, index: index, scale: p.scale_x)
                }
                // The filament of the part: a chip for each filament.
                if SettingInfo.byName["project.filament"] != nil {
                    HStack {
                        Text("Filament").font(.callout)
                        Spacer()
                        FilamentChips(model: workspace.model,
                                      value: own.first { $0.info.name == "project.filament" }?.value ?? workspace.model.entry("project.filament").value) { v in
                            for i in workspace.selectedParts { workspace.setPartSetting(i, "project.filament", v) }
                        }
                    }
                }
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
                        Divider()
                        Button("Reset the Orientation and Scale") { workspace.resetPart() }
                    }
                    .fixedSize()
                    Spacer()
                    Button(role: .destructive) { workspace.removePart() } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove the part (Delete)")
                }
                .controlSize(.small)
                let rest = own.filter { $0.info.name != "project.filament" }
                if !rest.isEmpty {
                    Divider()
                    Text("Settings of this part").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(rest, id: \.info.name) { s in
                        PartSettingRow(workspace: workspace, index: index, info: s.info, value: s.value)
                    }
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
                .help("Copies of the part until there are this many in all: on this plate while they fit, then on new plates with the settings of this one")
                HStack {
                    Button("Part Settings…") { workspace.editScope(.part(index)) }
                    Spacer()
                    Button("To a New Plate") { workspace.movePartToNewPlate() }
                        .help("The part goes to a new plate with the settings of this one")
                }
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
            .padding(14)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
            .position(place)
            .offset(drag)
        }
    }

    /// The card of several parts (Shift and a click): how many, their
    /// extent on the bed, and the actions for all of them.
    private var many: some View {
        let list = workspace.selectedParts
        let parts = list.compactMap { workspace.part($0) }
        let x0 = parts.map { $0.x - $0.size_x / 2 }.min() ?? 0, x1 = parts.map { $0.x + $0.size_x / 2 }.max() ?? 0
        let y0 = parts.map { $0.y - $0.size_y / 2 }.min() ?? 0, y1 = parts.map { $0.y + $0.size_y / 2 }.max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(list.count) parts").font(.headline)
                Spacer()
                Button { workspace.selectPart(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
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
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .position(place)
        .offset(drag)
    }

    private var sections: [String] {
        var seen = Set<String>()
        return SettingInfo.all.filter(\.perPart).compactMap { seen.insert($0.section).inserted ? $0.section : nil }
    }

    /// Beside the part and its turn rings, never over them (cardPlace); a
    /// card that the user moved stays.
    @State private var cardSize = CGSize(width: 300, height: 220)

    private var place: CGPoint {
        if let moved { return moved }
        let at = CGPoint(x: area.width - 92 - cardSize.width / 2, y: 236)
        // Clear of all selected parts.
        let box = workspace.selectedParts.compactMap { workspace.partRect($0) }.reduce(nil as CGRect?) { acc, r in acc.map { $0.union(r) } ?? r }
        return cardPlace(avoiding: box, near: at, size: cardSize, in: area, bottom: workspace.dockHeight + 12, panels: workspace.panels)
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

/// The scale of a part in %, the same along each axis.
private struct ScaleField: View {
    let workspace: Workspace
    let index: Int
    let scale: Double
    @State private var text = ""

    var body: some View {
        HStack(spacing: 2) {
            TextField("Scale", text: $text)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .onSubmit {
                    guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0, scale > 0 else {
                        text = format(scale)
                        return
                    }
                    workspace.scaleParts([index], by: v / 100 / scale)
                }
            Text("%").foregroundStyle(.secondary)
        }
        .help("The scale of the part, the same along each axis")
        .onAppear { text = format(scale) }
        .onChange(of: scale) { text = format(scale) }
    }

    private func format(_ s: Double) -> String {
        let v = s * 100
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
