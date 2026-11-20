//! The main settings of the print on the print card (web/app/app.js,
//! fillFacts): the layer height, the walls, the infill, the support, the
//! brim or skirt, the temperatures, and the nozzle. Each is a small button.
//! A click opens a popover with the editors of its settings (and a slider
//! for a number), so a change slices at once and the view shows it.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct PrintFacts: View {
    let workspace: Workspace

    private var model: SliceModel { workspace.model }

    /// One button: its text, and the settings of its popover.
    private struct Fact: Identifiable {
        let text: String
        let help: String
        let settings: [String]
        var id: String { settings[0] }
    }

    private var facts: [Fact] {
        let v = { (n: String) in model.entry(n).value }
        let num = { (n: String) in Double(v(n)) ?? 0 }
        let mm = { (x: Double) in "\(ValueText.number((x * 1000).rounded() / 1000)) mm" }
        var out: [Fact] = []
        let lh = num("project.layer_height"), first = num("project.first_layer_height")
        out.append(Fact(text: "\(mm(lh)) layers" + (first > 0 && abs(first - lh) > 1e-6 ? " (first \(mm(first)))" : ""),
                        help: "The layer height, and the height of the first layer",
                        settings: ["project.layer_height", "project.first_layer_height"]))
        out.append(Fact(text: "\(Int(num("project.wall_count"))) walls", help: "The number of walls",
                        settings: ["project.wall_count"]))
        let density = num("project.infill_density")
        out.append(Fact(text: density > 0 ? "\(Int((density * 100).rounded())) % \(v("project.infill_pattern"))" : "no infill",
                        help: "The infill density and pattern", settings: ["project.infill_density", "project.infill_pattern"]))
        let support = v("project.support")
        let tree = v("project.support_style") == "tree" ? ", tree" : ""
        out.append(Fact(text: support.isEmpty || support == "off" ? "no support" : "support: \(support == "buildplate" ? "on the bed" : support)\(tree)",
                        help: "Support under overhangs, and its filaments", settings: ["project.support", "project.support_style"]
                            + (model.filaments.count > 1 ? ["project.support_filament", "project.support_interface_filament"] : [])))
        let brim = num("project.brim_width"), skirt = num("project.skirt_loops")
        out.append(Fact(text: brim > 0 ? "brim \(mm(brim))" : skirt > 0 ? "skirt \(Int(skirt))" : "no skirt",
                        help: "The brim, or the skirt", settings: ["project.brim_width", "project.skirt_loops"]))
        let nozzle = num("filament.nozzle_temp"), bed = num("filament.bed_temp")
        out.append(Fact(text: "\(Int(nozzle)) °C" + (bed > 0 ? " / bed \(Int(bed)) °C" : ""),
                        help: "The temperatures of the nozzle and the bed", settings: ["filament.nozzle_temp", "filament.bed_temp"]))
        let nd = num("machine.nozzle_diameter")
        if nd > 0 {
            out.append(Fact(text: "\(mm(nd)) nozzle", help: "The diameter of the nozzle (printer settings)",
                            settings: ["machine.nozzle_diameter"]))
        }
        return out.map { f in Fact(text: f.text, help: f.help, settings: f.settings.filter { SettingInfo.byName[$0] != nil }) }
            .filter { !$0.settings.isEmpty }
    }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(facts) { f in
                FactButton(model: model, text: f.text, help: f.help, settings: f.settings)
            }
        }
        .frame(width: 250, alignment: .leading)
    }
}

private struct FactButton: View {
    let model: SliceModel
    let text: String
    let help: String
    let settings: [String]
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(open ? 1 : 0.6), in: Capsule())
                .contentShape(Capsule())
        }
            .buttonStyle(.plain)
            .help("\(help). Click to change it.")
            .popover(isPresented: $open, arrowEdge: .leading) {
                Form {
                    ForEach(settings, id: \.self) { name in
                        if let info = SettingInfo.byName[name] {
                            QuickSetting(model: model, info: info)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
    }
}

/// The editor of one setting, with a slider for a number that has one.
struct QuickSetting: View {
    let model: SliceModel
    let info: SettingInfo
    @State private var throttle = Throttle()

    var body: some View {
        let entry = model.entry(info.name)
        Section {
            LabeledContent(info.label) {
                SettingEditor(model: model, info: info, entry: entry)
            }
            .help(info.doc)
            if info.hasSlider, let v = Double(entry.value) {
                let k = info.isRatio ? 100.0 : 1
                Slider(value: Binding(get: { v * k }, set: { slide(($0 / k / info.step).rounded() * info.step) }),
                       in: info.sliderMin * k ... info.sliderMax * k)
                    .labelsHidden()
            }
        }
    }

    private func slide(_ v: Double) {
        let text = ValueText.number(v)
        throttle.run { model.set(info.name, text) }
    }
}

/// Lays out its views in rows, as text wraps.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (i, x) in row.items {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width > 0 && rows[rows.count - 1].width + spacing + s.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            let x = r.width > 0 ? r.width + spacing : 0
            r.items.append((i, x))
            r.width = x + s.width
            r.height = max(r.height, s.height)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
