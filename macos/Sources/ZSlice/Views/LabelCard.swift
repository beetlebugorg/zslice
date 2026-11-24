//! The card of the selected label of the Label tool (LabelTool.swift), as
//! web/app/labelcard.js. A spatial card (SpatialCards.swift, the kind
//! "label"): it goes to the place where the user put it last, else beside
//! the label, and never covers the label or its handle.
//!
//! The card has the shapes of the label, each with its chips (Text, Line,
//! Bar, Ring, Ticks, Free) and its fields, and "Add a Shape"; the turn of
//! the label, its filament, and its depth; the stroke check and the cost
//! (zs_app_label_info); and Delete. Each field changes the preview at
//! once; the label goes to the core after a short pause.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct LabelCard: View {
    let workspace: Workspace
    @FocusState private var textFocus: Int?

    /// The number fields of each shape: field, label, unit, min, max, tip.
    static let fields: [String: [(String, String, String, Double, Double, String)]] = [
        "text": [("size", "Size", "mm", 0.5, 200, "The height of the capitals"),
                 ("weight", "Weight", "mm", 0, 0.3, "Makes each stroke wider: small text prints better, small holes close")],
        "line": [("length", "Length", "mm", 0.1, 500, ""), ("width", "Width", "mm", 0.1, 100, "")],
        "bar": [("width", "Width", "mm", 0.1, 500, ""), ("height", "Height", "mm", 0.1, 500, ""),
                ("radius", "Corners", "mm", 0, 100, "The radius of the corners")],
        "ring": [("outer", "Outer radius", "mm", 0.1, 250, ""), ("inner", "Inner radius", "mm", 0, 250, "0 makes a disk")],
        "ticks": [("count", "Count", "", 1, 360, "The number of ticks"),
                  ("radius", "Radius", "mm", 0, 250, "The distance from the center to the inner end of each tick"),
                  ("length", "First length", "mm", 0.1, 100, "The length of the first tick"),
                  ("length_end", "Last length", "mm", 0, 100, "The length of the last tick (0: the same as the first). The ticks between grow evenly."),
                  ("width", "Width", "mm", 0.1, 20, "The width of each tick"),
                  ("start", "Start", "°", -360, 360, "The angle of the first tick (0: to the right, 90: up)"),
                  ("sweep", "Sweep", "°", -360, 360, "The angle from the first tick to the last (negative: clockwise)")],
        "polyline": [("width", "Width", "mm", 0, 100, "The width of the line (0 with Filled)")],
        "svg": [("size", "Height", "mm", 0.5, 500, "The height of the picture")],
    ]

    private var st: LabelState { workspace.labelState }

    var body: some View {
        if let l = st.label {
            card(l)
                .onChange(of: workspace.labelFocusText) { textFocus = 0 }
        }
    }

    @ViewBuilder
    private func card(_ l: PartLabel) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                head(l)
                notices(l)
                ForEach(Array(l.items.enumerated()), id: \.offset) { i, it in
                    itemBox(l, it, i)
                    Divider()
                }
                Menu("Add a Shape…") {
                    ForEach(LabelItem.shapes, id: \.self) { k in
                        Button(LabelItem.shapeNames[k] ?? k) { workspace.addLabelItem(k) }
                    }
                }
                .help("Add a shape to this label: it shares the place, the turn, and the filament. Ticks go around the center, under the text.")
                .fixedSize()
                Button("Place an SVG…") { pickSVG() }
                    .help("Put the filled shapes of an SVG file on the label. You can also drop an SVG file on a part.")
                HStack {
                    Text("Turn").frame(width: 70, alignment: .leading)
                    LabelNumberField(value: (l.angle * 10).rounded() / 10, min: -180, max: 180) { workspace.setLabelAngle($0); return true }
                    Text("°").foregroundStyle(.secondary)
                }
                .help("The turn of the label on the face (0: level). The wheel over the label turns it 1° (Shift: 15°).")
                Text("Filament").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FilamentChips(model: workspace.model, value: String(l.filament)) { workspace.setLabelFilament(Int($0) ?? 1) }
                depthRow(l)
                modeRow(l)
                Text("Print").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                info
                Button("Delete the Label", role: .destructive) { workspace.removeLabel() }
                    .help("Remove the label from the part (Delete)")
            }
        }
        .controlSize(.small)
    }

    private func head(_ l: PartLabel) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Label \(l.title)").font(.headline).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { workspace.selectLabel(nil) } label: {
                CloseMark()
            }
            .buttonStyle(.borderless)
            .help("Clear the selection (Esc). The label stays.")
        }
    }

    @ViewBuilder
    private func notices(_ l: PartLabel) -> some View {
        // A label in the filament of the part does not show.
        if l.filament == st.base {
            if workspace.model.filaments.count <= 1 {
                HStack {
                    Text("The plate has one filament, so this label does not show.")
                    Button("Add a Filament") { workspace.addLabelFilament() }
                        .help("Add a second filament to the plate, and print the label with it")
                }
                .font(.callout).foregroundStyle(.orange)
            } else {
                Text("The label has the filament of the part, so it does not show. Pick another filament.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        if st.curve > LabelPlace.curveLimit {
            Text(LabelPlace.curveText).font(.callout).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func itemBox(_ l: PartLabel, _ it: LabelItem, _ i: Int) -> some View {
        if it.kind == "svg" {
            HStack {
                Text("SVG picture").font(.callout.weight(.medium))
                Spacer()
                if l.items.count > 1 {
                    Button { workspace.removeLabelItem(i) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Remove this shape from the label")
                }
            }
        } else {
        HStack(spacing: 2) {
            ForEach(LabelItem.shapes, id: \.self) { k in
                ChoiceButton(title: LabelItem.shapeNames[k] ?? k, on: it.kind == k) { workspace.setLabelShape(i, k) }
                    .help(k == "polyline" ? "A free line: click points on the face" : "Make this shape a \((LabelItem.shapeNames[k] ?? k).lowercased())")
            }
            if l.items.count > 1 {
                Button { workspace.removeLabelItem(i) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Remove this shape from the label")
            }
        }
        }
        if it.kind == "text" {
            TextField("Text", text: Binding(get: { it.text ?? "" }, set: { t in _ = workspace.editLabelItem(i) { $0.text = String(t.utf8.prefix(256)) ?? t } }))
                .focused($textFocus, equals: i)
                .accessibilityLabel("The text of the label")
        }
        let fields: [(String, String, String, Double, Double, String)] = Self.fields[it.kind] ?? []
        ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
            HStack {
                Text(f.1).frame(width: 90, alignment: .leading)
                LabelNumberField(value: it[f.0] ?? 0, min: f.3, max: f.4) { v in
                    workspace.editLabelItem(i) { $0[f.0] = f.0 == "count" ? v.rounded() : v }
                }
                Text(f.2).foregroundStyle(.secondary)
            }
            .help(f.5.isEmpty ? f.1 : f.5)
        }
        if it.kind == "polyline" {
            HStack {
                Toggle("Closed", isOn: Binding(get: { it.closed ?? false }, set: { v in _ = workspace.editLabelItem(i, commit: true) { $0.closed = v } }))
                Toggle("Filled", isOn: Binding(get: { it.filled ?? false }, set: { v in _ = workspace.editLabelItem(i, commit: true) { $0.filled = v } }))
            }
            let drawing = st.drawing == i
            Button(drawing ? "Done" : "Draw Points") { drawing ? workspace.stopLabelDrawing() : workspace.startLabelDrawing(i) }
                .help(drawing ? "Stop: the line keeps its points" : "Click points on the face, one after the other")
            if drawing { Text("Click points on the face. Click Done at the end.").font(.caption).foregroundStyle(.secondary) }
        }
        HStack {
            Text("Offset").frame(width: 90, alignment: .leading)
            LabelNumberField(value: it.at?.first ?? 0, min: -500, max: 500) { v in workspace.editLabelItem(i) { $0.at = [v, $0.at?.last ?? 0] } }
                .help("Right of the center of the label, mm")
            LabelNumberField(value: it.at?.last ?? 0, min: -500, max: 500) { v in workspace.editLabelItem(i) { $0.at = [$0.at?.first ?? 0, v] } }
                .help("Up from the center of the label, mm")
            Text("mm").foregroundStyle(.secondary)
        }
    }

    /// Ink, Raised, or Cut in, and the relief of a raised or cut label.
    @ViewBuilder
    private func modeRow(_ l: PartLabel) -> some View {
        let mode = l.mode ?? "ink"
        HStack {
            Text("Print").frame(width: 70, alignment: .leading)
            ForEach(PartLabel.modes, id: \.self) { m in
                ChoiceButton(title: PartLabel.modeNames[m] ?? m, on: mode == m) { workspace.setLabelMode(m) }
                    .help(m == "ink" ? "Flush with the surface, in the filament of the label" : m == "raised" ? "Out of the surface by the relief" : "Cut into the surface by the relief")
            }
        }
        if mode != "ink" {
            HStack {
                Text("Relief").frame(width: 70, alignment: .leading)
                LabelNumberField(value: (l.relief ?? 0) > 0 ? l.relief! : PartLabel.defaultRelief, min: 0.1, max: 10) { workspace.setLabelRelief($0); return true }
                    .help("The height of a raised label, or the depth of a cut, mm")
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }

    /// Place an SVG…: an open panel for an .svg file (at most 512 KiB).
    private func pickSVG() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let d = try? Data(contentsOf: url), d.count <= 512 * 1024, let text = String(data: d, encoding: .utf8) else {
            workspace.showNote("The SVG did not read: a text file of at most 512 KiB.")
            return
        }
        workspace.placeLabelSVG(text, name: url.lastPathComponent)
    }

    private func depthRow(_ l: PartLabel) -> some View {
        let lw = st.info?.line_width ?? 0.42
        let d = l.depth ?? 0
        return HStack {
            Text("Depth").frame(width: 70, alignment: .leading)
            ChoiceButton(title: "1 Line", on: d <= 0) { workspace.setLabelDepth(0) }
                .help("The color is one line deep (the outer wall)")
            ChoiceButton(title: "2 Lines", on: abs(d - 2 * lw) < 1e-6) { workspace.setLabelDepth(2 * lw) }
                .help("The color is two lines deep: more color for a light filament over a dark part")
            LabelNumberField(value: d, min: 0, max: 10) { workspace.setLabelDepth($0); return true }
                .help("The depth of the color from the surface, mm (0: one line)")
            Text("mm").foregroundStyle(.secondary)
        }
    }

    /// The stroke check and the cost (zs_app_label_info).
    @ViewBuilder
    private var info: some View {
        if let info = st.info {
            let lw = info.line_width ?? 0.42
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                if let t = info.thinnest, t > 0 {
                    GridRow {
                        Text("Thinnest stroke").foregroundStyle(.secondary)
                        Text(String(format: "%.2f mm", t)).foregroundStyle(t < 2 * lw ? Color.orange : .primary)
                    }
                }
                if let c = info.clean_size, c > 0 {
                    GridRow {
                        Text("Text size").foregroundStyle(.secondary)
                        Text(String(format: "clean from %.1f mm, fair from %.1f mm", c, info.fair_size ?? 0))
                    }
                }
                if info.same_filament != true {
                    let n = (info.sliced == true ? info.changes : info.estimate_changes) ?? 0
                    GridRow {
                        Text(info.sliced == true ? "Adds" : "Adds about").foregroundStyle(.secondary)
                        Text("\(n) filament \(n == 1 ? "change" : "changes")")
                    }
                    GridRow { Text("Time").foregroundStyle(.secondary); Text("\(Int((info.minutes ?? 0).rounded())) min") }
                    GridRow { Text("Flush").foregroundStyle(.secondary); Text(String(format: "%.1f g", info.grams ?? 0)) }
                    if let layers = info.layers, layers > 0 {
                        GridRow {
                            Text("Layers").foregroundStyle(.secondary)
                            Text(String(format: "%d (%.1f to %.1f mm)", layers, info.z_min ?? 0, info.z_max ?? 0))
                        }
                    }
                }
            }
            .font(.callout.monospacedDigit())
            if let a = info.advice, !a.isEmpty { Text(a).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if info.same_filament != true {
                if info.sliced != true { Text("An estimate. The slice gives the count.").font(.caption).foregroundStyle(.secondary) }
                let n = (info.sliced == true ? info.changes : info.estimate_changes) ?? 0
                if info.kind == "side", n > 10, let top = info.top_changes, top >= 0 {
                    Text("On the top face, this label costs \(top) \(top == 1 ? "change" : "changes").").font(.callout)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Counting").foregroundStyle(.secondary)
            }
        }
    }
}

/// A number of the card: live as it is typed, in its range. `send`
/// returns false when the label cannot take the value (the field shows
/// red).
struct LabelNumberField: View {
    let value: Double
    let min: Double
    let max: Double
    let send: (Double) -> Bool
    @State private var text = ""
    @State private var bad = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            .focused($focused)
            .foregroundStyle(bad ? Color.red : Color.primary)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { if !focused { text = Self.format(value) } }
            .onChange(of: text) {
                guard focused else { return }
                guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite, v >= min, v <= max else {
                    bad = true
                    return
                }
                bad = !send(v)
            }
            .onChange(of: focused) { if !focused { text = Self.format(value); bad = false } }
    }

    static func format(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}

/// A button of a choice: the one that is on has the prominent style.
private struct ChoiceButton: View {
    let title: String
    let on: Bool
    let action: () -> Void

    /// Its own fill: AppKit draws a prominent button gray in a window that
    /// is not the key window.
    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color(nsColor: .controlColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.clear : Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The corner handle of the selected label: a drag scales it.
/// The handles of the selected label, drawn in its plane on the screen:
/// the frame around its box, a square at each corner (a drag resizes the
/// label about the opposite corner; Shift: each axis on its own), and the
/// round turn handle over the frame (Shift: steps of 15°). The guides of
/// the snap show as thin lines during a drag. The view of the slice takes
/// the presses (Workspace.labelPress), so this view draws only.
struct LabelHandles: View {
    let workspace: Workspace

    private static let ink = Color(red: 0.98, green: 0.78, blue: 0.1)
    private static let guide = Color(red: 1, green: 0.18, blue: 0.58)

    var body: some View {
        let st = workspace.labelState
        Canvas { ctx, _ in
            func path(_ pts: [CGPoint]) -> Path {
                var p = Path()
                guard let first = pts.first else { return p }
                p.move(to: first)
                for q in pts.dropFirst() { p.addLine(to: q) }
                p.closeSubpath()
                return p
            }
            for (a, b) in st.guides {
                var p = Path()
                p.move(to: a)
                p.addLine(to: b)
                ctx.stroke(p, with: .color(Self.guide), lineWidth: 1)
            }
            if st.frame.count == 4 {
                ctx.stroke(path(st.frame), with: .color(Self.ink.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            for c in st.corners where c.count == 4 {
                ctx.fill(path(c), with: .color(.white))
                ctx.stroke(path(c), with: .color(Self.ink), lineWidth: 1.5)
            }
            if st.turnRing.count > 2 {
                ctx.fill(path(st.turnRing), with: .color(Self.ink))
                ctx.stroke(path(st.turnRing), with: .color(.black.opacity(0.4)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
