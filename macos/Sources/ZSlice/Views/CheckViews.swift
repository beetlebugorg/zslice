//! The views of Gaps and Check (Checks.swift): the buttons of the tool
//! strip, the count of the gaps, the card of a gap, and the list of the
//! issues of the print.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The two toggles at the end of the tool strip: Gaps (⇧⌘G) and Check.
struct CheckButtons: View {
    let workspace: Workspace

    var body: some View {
        Button { workspace.toggleGaps() } label: {
            StripIcon(glyph: "gaps", on: workspace.gapsOn)
        }
        .buttonStyle(.plain)
        .help("Gaps (⇧⌘G): the areas of the top layer that should be solid and that no line covers, in red. Click a gap for the settings that can close it.")
        .accessibilityLabel("Gaps")
        Button { workspace.checkOpen.toggle() } label: {
            StripIcon(glyph: "check", on: workspace.checkOpen)
                .overlay(alignment: .topTrailing) {
                    let n = workspace.checkProblems
                    if n > 0 {
                        Text("\(n)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Color.orange, in: Capsule())
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(workspace.checkProblems > 0
            ? "Check the print (⇧⌘K): \(workspace.checkProblems) \(workspace.checkProblems == 1 ? "problem" : "problems") to look at"
            : "Check the print (⇧⌘K): what can make it fail, the worst first: overhangs with no support, bridges, shapes in the air, lines over the flow of the hot end, layers that cool too little, and parts that can tip over.")
        .accessibilityLabel("Check the print")
    }
}

/// The count and the area of the gaps of the top layer.
struct GapSummary: View {
    let workspace: Workspace

    var body: some View {
        if workspace.gapsOn, let s = workspace.gapSummary {
            Label(s.count == 0 ? "No gaps on layer \(workspace.hi + 1)"
                               : String(format: "%d gaps on layer %d · %.2f mm²", s.count, workspace.hi + 1, s.area),
                  systemImage: s.count == 0 ? "checkmark.circle" : "square.dashed")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(s.count == 0 ? Color.green : Color.red)
        }
    }
}

/// The card of a selected gap: its size, and the settings that can close it.
struct GapCard: View {
    let workspace: Workspace
    let gap: GapInfo
    /// The height of the free area of the view: a taller card scrolls, so
    /// it stays clear of the bars and the gap.
    var maxHeight: CGFloat = .infinity

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(width: 320)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var content: some View {
        let model = workspace.model
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Gap · layer \(gap.layer + 1)").font(.headline)
                Spacer()
                Button { workspace.gapCard = nil } label: {
                    CloseMark()
                }
                .buttonStyle(.borderless)
            }
            Text(String(format: "%.3f mm² · %.2f mm wide", gap.area, gap.width)).foregroundStyle(.secondary)
            if gap.steps.isEmpty {
                Text("No setting closes this gap.").foregroundStyle(.secondary)
            }
            ForEach(Array(gap.steps.enumerated()), id: \.offset) { _, st in
                let info = SettingInfo.byName[st.name]
                let now = model.entry(st.name).value
                Divider()
                Text("\(info?.label ?? st.name): \(info.map { ValueText.withUnit($0, now) } ?? now) → \(info.map { ValueText.withUnit($0, st.value) } ?? st.value)")
                Text(st.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Apply") { workspace.applyGapStep(st.name, st.value, layerOnly: false) }
                        .help("Change the setting for all layers, and slice again")
                    if info?.perLayer == true {
                        Button("This Layer") { workspace.applyGapStep(st.name, st.value, layerOnly: true) }
                            .help("Change the setting only for this layer, and slice again")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

/// The issues of the print, the worst first.
struct CheckPanel: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Check the Print").font(.headline)
                Spacer()
                Button { workspace.checkOpen = false } label: {
                    CloseMark()
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            if workspace.issues.isEmpty {
                Label("Nothing to fix: the print has no known problem.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(workspace.issues) { issue in
                            Button { workspace.show(issue) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: issue.symbol)
                                        .foregroundStyle(issue.severity >= 2 ? Color.red : issue.severity == 1 ? .orange : .secondary)
                                        .frame(width: 18)
                                    Text(issue.text).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Go to layer \(issue.layer + 1) and select the line")
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
