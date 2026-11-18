//! The card of a selected line, next to it in the view
//! (docs/internals/one-view.md, web/app/linecard.js,
//! linux/src/ui/line-card.c). A click on a line opens it at the click.
//!
//! It shows what the line is (the feature and the layer), its three
//! numbers (the planned speed, the real speed, the flow), why it is slow,
//! its size, and the settings that matter for it, as the core picks them
//! (zs_app_inspect_picks), each with the reason and a live editor. A change
//! slices at once. "Fade the others" shows the line solid and the other
//! lines as ghosts. "All Settings…" opens the drawer on all the settings of
//! the line.
//!
//! The card follows the line after a new slice, and closes with Esc, with
//! a click on no line, or with the close button. A drag of its head moves
//! it, and it keeps that place for the next lines until it closes.
//! A second row edits the line itself (zs_app_edit_add): Don't Print This
//! Line (also Delete), and 10 % less or more plastic. Undo takes an edit back.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct LineCard: View {
    let workspace: Workspace
    let info: LineInfo
    /// The size of the area of the card, to keep it inside.
    let area: CGSize
    @State private var drag: CGSize = .zero
    @State private var cardSize = CGSize(width: 320, height: 260)

    private var model: SliceModel { workspace.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            head
            numbers
            if !info.slowText.isEmpty {
                Label(info.slowText, systemImage: "tortoise")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let size = sizeText {
                Text(size).font(.callout).foregroundStyle(.secondary)
            }
            if !info.picks.isEmpty {
                Divider()
                ForEach(info.picks, id: \.name) { p in
                    if let s = SettingInfo.byName[p.name] {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.label)
                                if !p.why.isEmpty {
                                    Text(p.why).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .help(s.doc)
                            Spacer(minLength: 8)
                            SettingEditor(model: model, info: s, entry: model.entry(s.name), compact: true)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Fade the Others", isOn: Binding(get: { workspace.isolate }, set: { _ in workspace.toggleIsolate() }))
                    .toggleStyle(.button)
                    .help("Show this line solid, and the other lines as faint ghosts")
                Spacer()
                Button("All Settings…") { workspace.showLineSettings() }
                    .help("All the settings that change this line")
            }
            HStack {
                Button("Don't Print This Line") { workspace.editLine(kind: 0) }
                    .help("The line does not print (Delete). Undo brings it back.")
                Spacer()
                Button("−10 %") { workspace.editLine(kind: 1, value: 0.9) }
                    .help("10 % less plastic in this line")
                Button("+10 %") { workspace.editLine(kind: 1, value: 1.1) }
                    .help("10 % more plastic in this line")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .position(place)
        .offset(drag)
        .onKeyPress(.escape) {
            workspace.clearSelection()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The selected line")
    }

    private var head: some View {
        HStack {
            Text("\(info.title) · layer \(info.layer + 1)").font(.headline)
            Spacer()
            Button {
                workspace.clearSelection()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .contentShape(Rectangle())
        .help("Drag to move the card")
        .gesture(DragGesture(coordinateSpace: .global)
            .onChanged { drag = $0.translation }
            .onEnded { g in
                let c = place
                workspace.cardMoved = CGPoint(x: c.x + g.translation.width, y: c.y + g.translation.height)
                drag = .zero
            })
    }

    private var numbers: some View {
        HStack(spacing: 0) {
            stat(String(format: "%.0f mm/s", info.plannedSpeed), "planned", warn: false)
            stat(String(format: "%.0f mm/s", info.speed), "real", warn: info.slowReason != 0)
            stat(String(format: "%.1f mm³/s", info.flow), "flow", warn: false)
        }
    }

    private func stat(_ value: String, _ caption: String, warn: Bool) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(warn ? .orange : .primary)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sizeText: String? {
        guard let m = info.measure else { return nil }
        var s = ""
        if m.shape == 1 { s = String(format: "Circle ⌀ %.2f mm · ", 2 * m.radius) }
        if m.shape == 2 { s = String(format: "Arc r %.2f mm · ", m.radius) }
        return s + String(format: "segment %.2f mm · %@ %.1f mm", m.segment_length, m.closed != 0 ? "loop" : "path", m.path_length)
    }

    /// The center of the card: next to the click, inside the view (a card
    /// that the user moved stays there).
    private var place: CGPoint {
        let w = cardSize.width, h = cardSize.height
        if let m = workspace.cardMoved { return m }
        let at = workspace.cardAt
        var x = at.x + 18
        if x + w > area.width - 60 { x = at.x - w - 18 }
        x = max(8, min(area.width - w - 8, x))
        let y = max(60, min(area.height - h - 8, at.y - 24))
        return CGPoint(x: x + w / 2, y: y + h / 2)
    }
}
