//! The view of the card of a history step (Core/HistoryCard.swift).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A bubble of the timeline: the color of its kind, a white ring, and the
/// glyph of its kind; the step now is larger, with a ring of the accent.
struct StepBubble: View {
    let kind: String
    let now: Bool
    let later: Bool

    var body: some View {
        let look = History.look(kind)
        Circle()
            .fill(look.color)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
            .overlay(HistoryGlyph(kind: kind, size: now ? 18 : 15))
            .frame(width: now ? 26 : 22, height: now ? 26 : 22)
            .background(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-2).opacity(now ? 1 : 0))
            .opacity(later ? 0.4 : 1)
    }
}

struct HistoryCard: View {
    let workspace: Workspace
    let state: HistoryCardState
    /// The global origin of the layer of the cards, and its size.
    let origin: CGPoint
    let area: CGSize
    @State private var size = CGSize(width: 300, height: 200)

    private var model: SliceModel { workspace.model }

    var body: some View {
        let history = model.history
        let i = state.step
        if let s = history.step(i) {
            let kind = i == 0 ? "start" : s.kind
            let look = History.look(kind)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(look.color).frame(width: 24, height: 24)
                        .overlay(HistoryGlyph(kind: kind, size: 16))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i == 0 ? "Start" : "Change \(i)").font(.headline)
                        Text("\(look.label) · \(s.time.formatted(date: .omitted, time: .standard))" + (i == history.current ? " · now" : ""))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if i == 0 {
                    Text("The settings and the plate when the history started.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(s.words.enumerated()), id: \.offset) { _, w in
                            let parts = w.split(separator: "\t", maxSplits: 1).map(String.init)
                            if parts.count == 2 { Text("\(parts[0]): \(parts[1])").font(.callout) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    let keys = workspace.historyCardKeys(i)
                    if !keys.isEmpty {
                        Divider()
                        Text("The value now:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(keys, id: \.self) { key in
                            if let info = SettingInfo.byName[key] {
                                HStack(alignment: .firstTextBaseline) {
                                    Button(info.label) { workspace.openSetting(key) }
                                        .buttonStyle(.plain)
                                        .help("\(info.doc)\n\nClick to show this setting in the panel.")
                                    Spacer(minLength: 8)
                                    SettingEditor(model: model, info: info, entry: model.entry(key), compact: true)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button(i == history.current ? "This Is the Step Now" : "Go to This Step") {
                    workspace.closeHistoryCard()
                    history.go(to: i)
                }
                .disabled(i == history.current)
            }
            .controlSize(.small)
            .padding(14)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onHover { workspace.historyCardHover($0) }
            // An editor that loses the focus: the card closes when the
            // pointer is gone too.
            .onChange(of: history.focusKey) { if history.focusKey == nil, !workspace.historyCardHovered { workspace.historyCardLater() } }
            .position(place)
        }
    }

    /// Over the bubble, with a gap of 10, inside the window.
    private var place: CGPoint {
        let a = state.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
        let x = max(8 + size.width / 2, min(area.width - 8 - size.width / 2, a.midX))
        let y = max(8 + size.height / 2, a.minY - 10 - size.height / 2)
        return CGPoint(x: x, y: y)
    }
}
