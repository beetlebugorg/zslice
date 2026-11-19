//! The card of a selected line (docs/internals/one-view.md,
//! web/app/linecard.js, linux/src/ui/line-card.c). A click on a line opens
//! it in a corner of the view, clear of the whole line and the click. It
//! keeps its corner from click to click while that corner stays clear.
//!
//! It shows what helps to decide what to change: what the line is (the
//! feature, the layer, and the z), then two short lines of numbers (the
//! speed and the flow; the size of the line, the time of its layer, and
//! the fan). Notes say why it is slow, when the flow limit sets its speed,
//! what a support line holds up, and the warnings of the check at the line
//! (only a check that has run: zs_app_checks_ready). Then up to 5 settings
//! that matter for it, as the core picks them (zs_app_inspect_picks), each
//! with the reason and a live editor. A change slices at once. The rows
//! keep their identity across slices, so an editor keeps the focus and the
//! arrow keys keep stepping. "Fade the others" shows the line solid and
//! the other lines as ghosts. "All Settings…" opens the drawer on all the
//! settings of the line.
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.label)
                                if !p.why.isEmpty {
                                    Text(p.why).font(.caption).foregroundStyle(.secondary)
                                }
                            }
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
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .position(place)
        .offset(drag)
        .onKeyPress(.escape) {
            workspace.closeCard()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The selected line")
    }

    private var head: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title).font(.headline)
                Text(String(format: "Layer %d · z %.2f mm", info.layer + 1, info.z))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                workspace.closeCard()
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

    /// The notes of the line: why it is slow, the flow limit, what a
    /// support line holds up, and the warnings of the check at the line.
    private var notes: [(text: String, symbol: String, warn: Bool)] {
        var out: [(text: String, symbol: String, warn: Bool)] = []
        if !info.slowText.isEmpty { out.append((info.slowText, "tortoise", true)) }
        if info.flowLimited, info.maxFlow > 0 {
            out.append((String(format: "The flow limit (%.0f mm³/s) sets the speed of this line, not the printer.", info.maxFlow), "gauge.with.dots.needle.100percent", true))
        }
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

    /// The center of the card: in a corner of the view, clear of the
    /// clicked line (a card that the user moved stays there).
    private var place: CGPoint {
        if let m = workspace.cardMoved { return m }
        let box = workspace.selection.flatMap { workspace.lineRect($0.path) }
        let (c, corner) = cardCorner(avoiding: box, near: workspace.cardAt, size: cardSize, in: area,
                                     bottom: workspace.dockHeight, keep: workspace.cardCorner, panels: workspace.panels)
        workspace.cardCorner = corner
        return c
    }
}

/// "6.2 s", "1 min 05 s".
func layerTimeText(_ s: Double) -> String {
    guard s > 0 else { return "–" }
    if s < 60 { return String(format: "%.1f s", s) }
    let r = Int(s.rounded())
    return String(format: "%d min %02d s", r / 60, r % 60)
}

/// The frames of the panels over the view (the print card, the check
/// panel, the cards of the tools): a card never covers one (web/app/
/// place.js, freeArea). Each panel marks itself with `.panel()`.
struct PanelFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// A panel that the cards keep out of.
    func panel() -> some View {
        background(GeometryReader { g in Color.clear.preference(key: PanelFramesKey.self, value: [g.frame(in: .global)]) })
    }
}

/// The overlap of a card at `r` with the box (and its margin) and the
/// panels, in square points: 0 when it is clear of all of them.
private func coverage(_ r: CGRect, box: CGRect?, margin: CGFloat, panels: [CGRect]) -> CGFloat {
    var sum: CGFloat = 0
    if let b = box?.insetBy(dx: -margin, dy: -margin) {
        let i = r.intersection(b)
        if !i.isNull { sum += i.width * i.height }
    }
    for p in panels {
        let i = r.intersection(p.insetBy(dx: -8, dy: -8))
        if !i.isNull { sum += i.width * i.height }
    }
    return sum
}

/// The center of a card in a corner of the view, away from the box of the
/// clicked line and the click (web/app/place.js, placeCorner). The card
/// keeps its corner `keep` while that corner stays clear, so it does not
/// jump from click to click. Else it takes the first clear corner, or the
/// one with the least overlap. Corners: 0 top left, 1 top right, 2 bottom
/// left, 3 bottom right. The area leaves out the tool strip (64 points),
/// the toolbar (60), the layer slider with its label (124), and the bottom
/// bar.
func cardCorner(avoiding box: CGRect?, near at: CGPoint, size: CGSize, in area: CGSize, bottom: CGFloat, keep: Int?,
                panels: [CGRect] = []) -> (CGPoint, Int) {
    let clear: CGFloat = 24, gap: CGFloat = 16
    let b = (box ?? CGRect(origin: at, size: .zero)).union(CGRect(origin: at, size: .zero)).insetBy(dx: -clear, dy: -clear)
    let x0: CGFloat = 72, y0: CGFloat = 60, x1 = area.width - 124, y1 = area.height - bottom - 12
    let w = size.width, h = size.height
    func origin(_ c: Int) -> CGPoint {
        CGPoint(x: c % 2 == 0 ? x0 : max(x0, x1 - w), y: c < 2 ? y0 : max(y0, y1 - h))
    }
    // The box of the line and the panels over the view.
    func overlap(_ c: Int) -> CGFloat {
        coverage(CGRect(origin: origin(c), size: size), box: b, margin: gap, panels: panels)
    }
    let order = keep.map { k in [k] + [0, 1, 2, 3].filter { $0 != k } } ?? [0, 1, 2, 3]
    let best = order.first { overlap($0) == 0 } ?? order.min { overlap($0) < overlap($1) }!
    let o = origin(best)
    return (CGPoint(x: o.x + w / 2, y: o.y + h / 2), best)
}
/// The center of a card for a click at `at`: to the side, with a gap of
/// 120 points, so the card does not cover the click and the lines around
/// it. The side with room wins (the right first); with room on neither,
/// the side farther from the click. Inside the view, under the toolbar.
func cardPlace(near at: CGPoint, size: CGSize, in area: CGSize) -> CGPoint {
    let w = size.width, h = size.height, gap: CGFloat = 120
    var x: CGFloat
    if at.x + gap + w <= area.width - 8 {
        x = at.x + gap
    } else if at.x - gap - w >= 8 {
        x = at.x - gap - w
    } else {
        x = at.x < area.width / 2 ? area.width - w - 8 : 8
    }
    x = max(8, min(area.width - w - 8, x))
    let y = max(60, min(area.height - h - 8, at.y - h / 2))
    return CGPoint(x: x + w / 2, y: y + h / 2)
}

/// The center of a card that must never cover `box` (the screen box of the
/// thing that was clicked, in points): the first side of the box where the
/// card fits whole, in the order right, left, below, above, with a gap of
/// 12 points; under the toolbar (60) and in the view. With no side where
/// it fits, the side with the most room. With no box, `cardPlace(near:)`.
/// bottom: the room to keep at the bottom (the bottom bar).
func cardPlace(avoiding box: CGRect?, near at: CGPoint, size: CGSize, in area: CGSize, bottom: CGFloat = 8,
               panels: [CGRect] = []) -> CGPoint {
    guard let b = box, b.width > 0 || b.height > 0 else {
        let c = cardPlace(near: at, size: size, in: area)
        return clearOfPanels(c, size: size, in: area, bottom: bottom, panels: panels)
    }
    // The tool strip is at the left (64 points) and the layer slider at
    // the right (84): a card keeps out of them too.
    let w = size.width, h = size.height, gap: CGFloat = 12, top: CGFloat = 60, edge = max(8, bottom)
    let left: CGFloat = 64, right = area.width - 84
    func clampY(_ y: CGFloat) -> CGFloat { max(top, min(area.height - h - edge, y)) }
    func clampX(_ x: CGFloat) -> CGFloat { max(left, min(right - w, x)) }
    let sides: [(fits: Bool, origin: CGPoint, room: CGFloat)] = [
        (b.maxX + gap + w <= right, CGPoint(x: b.maxX + gap, y: clampY(b.midY - h / 2)), right - b.maxX),
        (b.minX - gap - w >= left, CGPoint(x: b.minX - gap - w, y: clampY(b.midY - h / 2)), b.minX - left),
        (b.maxY + gap + h <= area.height - edge, CGPoint(x: clampX(b.midX - w / 2), y: b.maxY + gap), area.height - b.maxY),
        (b.minY - gap - h >= top, CGPoint(x: clampX(b.midX - w / 2), y: b.minY - gap - h), b.minY - top),
    ]
    // A side where the card fits whole, clear of the panels; else a corner
    // of the free area that is clear of the box and the panels; else the
    // side with the most room.
    func clear(_ o: CGPoint) -> Bool { coverage(CGRect(origin: o, size: size), box: b, margin: gap, panels: panels) == 0 }
    let fit = sides.map { (s: $0, o: CGPoint(x: clampX($0.origin.x), y: clampY($0.origin.y))) }
    if let s = fit.first(where: { $0.s.fits && clear($0.o) }) { return CGPoint(x: s.o.x + w / 2, y: s.o.y + h / 2) }
    let corners = [CGPoint(x: left, y: top), CGPoint(x: right - w, y: top), CGPoint(x: left, y: area.height - h - edge), CGPoint(x: right - w, y: area.height - h - edge)]
        .map { CGPoint(x: clampX($0.x), y: clampY($0.y)) }
    if let c = corners.first(where: clear) { return CGPoint(x: c.x + w / 2, y: c.y + h / 2) }
    let all = fit.map(\.o) + corners
    let o = all.min { coverage(CGRect(origin: $0, size: size), box: b, margin: gap, panels: panels) < coverage(CGRect(origin: $1, size: size), box: b, margin: gap, panels: panels) }!
    return CGPoint(x: o.x + w / 2, y: o.y + h / 2)
}

/// A card at `center` that covers a panel moves to the first corner of the
/// free area that is clear of the panels.
private func clearOfPanels(_ center: CGPoint, size: CGSize, in area: CGSize, bottom: CGFloat, panels: [CGRect]) -> CGPoint {
    let w = size.width, h = size.height
    let here = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    guard coverage(here, box: nil, margin: 0, panels: panels) > 0 else { return center }
    let top: CGFloat = 60, edge = max(8, bottom), left: CGFloat = 64, right = area.width - 84
    let corners = [CGPoint(x: left, y: top), CGPoint(x: right - w, y: top), CGPoint(x: left, y: area.height - h - edge), CGPoint(x: right - w, y: area.height - h - edge)]
    let o = corners.first { coverage(CGRect(origin: $0, size: size), box: nil, margin: 0, panels: panels) == 0 }
        ?? corners.min { coverage(CGRect(origin: $0, size: size), box: nil, margin: 0, panels: panels) < coverage(CGRect(origin: $1, size: size), box: nil, margin: 0, panels: panels) }!
    return CGPoint(x: o.x + w / 2, y: o.y + h / 2)
}
