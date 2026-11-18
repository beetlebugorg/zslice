//! The card of a selected part (docs/user/getting-started.md, "The part
//! card"; web/app/partcard.js). A click on a part with the Move or the Turn
//! tool, or Command and a click with any tool, selects it, and the card
//! opens at the top right of the view: its name, its size, and its turn; Duplicate (D), Best
//! Orientation, Less Support, Reset, and Remove (Delete); and the settings
//! that the part has of its own, each with an editor and a button that
//! gives it the value of the plate again. "Add a Setting" lists the
//! settings that a part can have of its own.
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

    var body: some View {
        if let p = workspace.part(index) {
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
                Text(String(format: "%.1f × %.1f × %.1f mm · turned %.0f°", p.size_x, p.size_y, p.size_z, p.rotation))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Duplicate") { workspace.duplicatePart() }.help("A copy at a free place (D)")
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
                if !own.isEmpty {
                    Divider()
                    Text("Settings of this part").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(own, id: \.info.name) { s in
                        PartSettingRow(workspace: workspace, index: index, info: s.info, value: s.value)
                    }
                }
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
            .position(place)
            .offset(drag)
        }
    }

    private var sections: [String] {
        var seen = Set<String>()
        return SettingInfo.all.filter(\.perPart).compactMap { seen.insert($0.section).inserted ? $0.section : nil }
    }

    /// At the top right of the view, left of the layer slider, so it does
    /// not cover the part and its rings; a card that the user moved stays.
    private var place: CGPoint {
        if let moved { return moved }
        let w = 300.0
        return CGPoint(x: area.width - w / 2 - 92, y: 190)
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
