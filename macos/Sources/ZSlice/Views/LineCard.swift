//! The page of a selected line in the Inspector (InspectorDock.swift,
//! docs/internals/one-view.md, web/app/linecard.js, linux/src/ui/line-card.c).
//!
//! It shows what helps to decide what to change: what the line is (the
//! feature, the layer, and the z), then two short lines of numbers (the
//! speed and the flow; the size of the line, the time of its layer, and
//! the fan). Notes say what a support line holds up, and the warnings of
//! the check at the line (only a check that has run: zs_app_checks_ready).
//! Then up to 5 settings that matter for it, as the core picks them
//! (zs_app_inspect_picks), each with a live editor. How the values come
//! about is at the foot of All Settings (LineSettings), not on the card.
//! A change slices at once. The rows
//! keep their identity across slices, so an editor keeps the focus and the
//! arrow keys keep stepping. "Fade the others" shows the line solid and
//! the other lines as ghosts. "All Settings…" opens the drawer on all the
//! settings of the line.
//!
//! The page follows the line after a new slice. Esc, a click on no line,
//! or the close button clears the selection.
//! A second row edits the line itself (zs_app_edit_add): Don't Print This
//! Line (also Delete), and 10 % less or more plastic. Undo takes an edit back.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct LineCard: View {
    let workspace: Workspace
    let info: LineInfo

    private var model: SliceModel { workspace.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            head
            numbers
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                Label(n.text, systemImage: n.symbol)
                    .font(.callout)
                    .foregroundStyle(n.warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !info.picks.isEmpty {
                Divider()
                ForEach(info.picks, id: \.name) { p in
                    if let s = SettingInfo.byName[p.name] {
                        HStack(alignment: .firstTextBaseline) {
                            Text(s.label)
                                .fixedSize(horizontal: false, vertical: true)
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
        .onKeyPress(.escape) {
            workspace.clearSelection()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The selected line")
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title).font(.headline)
                Text(String(format: "Layer %d · z %.2f mm", info.layer + 1, info.z))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                workspace.clearSelection()
            } label: {
                CloseMark()
            }
            .buttonStyle(.borderless)
            .help("Clear the selection (Esc)")
        }
    }

    /// Two short lines: the speed and the flow, then the size of the line,
    /// the time of its layer, and the fan. The room goes to the settings.
    private var numbers: some View {
        let slow = info.slowReason != 0
        let use = info.maxFlow > 0 ? Int((info.flow / info.maxFlow * 100).rounded()) : 0
        let speed = slow ? String(format: "%.0f of %.0f mm/s", info.speed, info.plannedSpeed) : String(format: "%.0f mm/s", info.speed)
        let flow = String(format: "%.1f mm³/s", info.flow) + (info.maxFlow > 0 ? " (\(use) %)" : "")
        return VStack(alignment: .leading, spacing: 2) {
            (part(speed, slow) + dot + part(flow, use >= 95))
                .help("The speed of the line (and the planned speed when it is slower), and its flow (and its share of the most that the hot end melts)")
            (part(String(format: "%.2f × %.2f mm", info.lineWidth, info.height), false) + dot
                + part("layer " + layerTimeText(info.layerTime), info.slowReason == 1) + dot
                + part("fan \(Int((info.fan * 100).rounded())) %", false))
                .help("The width and the height of the line, the time of its layer, and the fan" + (sizeText.map { ".\n" + $0 } ?? ""))
        }
        .font(.callout.monospacedDigit())
    }

    private func part(_ text: String, _ warn: Bool) -> Text {
        Text(text).foregroundStyle(warn ? .orange : .primary)
    }

    private var dot: Text { Text(" · ").foregroundStyle(.secondary) }

    /// The notes of the line: its nozzle, what a support line holds up,
    /// and the warnings of the check at the line.
    private var notes: [(text: String, symbol: String, warn: Bool)] {
        var out: [(text: String, symbol: String, warn: Bool)] = []
        if !info.nozzleText.isEmpty { out.append((info.nozzleText, "circle.circle", false)) }
        if let h = info.holds {
            let f = h.feature >= 0 && h.feature < Feature.titles.count ? Feature.titles[h.feature] : "Part"
            let up = h.layer - info.layer
            out.append(("Holds up: \(f.lowercased()) on layer \(h.layer + 1), \(up) \(up == 1 ? "layer" : "layers") up.", "arrow.up.to.line", false))
        } else if info.feature == Int32(ZS_FEATURE_SUPPORT.rawValue) || info.feature == Int32(ZS_FEATURE_SUPPORT_INTERFACE.rawValue) {
            out.append(("Holds up: no part line over it on the next layers.", "arrow.up.to.line", false))
        }
        // Flow, cooling, overhang, island, and bridge: two kinds at most.
        let kinds: Set<UInt8> = [ZS_ISSUE_FLOW, ZS_ISSUE_COOLING, ZS_ISSUE_OVERHANG, ZS_ISSUE_ISLAND, ZS_ISSUE_BRIDGE].map { UInt8($0.rawValue) }.reduce(into: []) { $0.insert($1) }
        var seen = Set<UInt8>()
        for i in info.issues where i.severity >= 1 && kinds.contains(i.kind) && !seen.contains(i.kind) && seen.count < 2 {
            seen.insert(i.kind)
            out.append((i.text, "exclamationmark.triangle", true))
        }
        return out
    }

    private var sizeText: String? {
        guard let m = info.measure else { return nil }
        var s = ""
        if m.shape == 1 { s = String(format: "Circle ⌀ %.2f mm · ", 2 * m.radius) }
        if m.shape == 2 { s = String(format: "Arc r %.2f mm · ", m.radius) }
        return s + String(format: "segment %.2f mm · %@ %.1f mm", m.segment_length, m.closed != 0 ? "loop" : "path", m.path_length)
    }

}

/// "6.2 s", "1 min 05 s".
func layerTimeText(_ s: Double) -> String {
    guard s > 0 else { return "–" }
    if s < 60 { return String(format: "%.1f s", s) }
    let r = Int(s.rounded())
    return String(format: "%d min %02d s", r / 60, r % 60)
}
