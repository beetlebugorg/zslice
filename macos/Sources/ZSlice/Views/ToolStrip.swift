//! The tool strip at the left of the view, and the measure tape over it
//! (docs/internals/one-view.md). Each tool has a key, shown in its button
//! and its help (Tools.swift).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ToolStrip: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Tool.allCases, id: \.self) { t in
                Button {
                    workspace.setTool(t)
                } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 34)
                        .overlay(alignment: .bottomTrailing) {
                            Text(t.key.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(2)
                        }
                        .background(workspace.tool == t ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(workspace.tool == t ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.help)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(workspace.tool == t ? .isSelected : [])
            }
            Divider().frame(width: 26)
            // The colors of the lines and the legend.
            ColorsButton(workspace: workspace)
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The measure tape: in 2D a gold line between its points (the core draws
/// it in 3D), and the readout over the middle of the tape, or the hint of
/// the tool with fewer than two points.
struct TapeOverlay: View {
    let workspace: Workspace
    let area: CGSize

    private static let gold = Color(red: 0.95, green: 0.72, blue: 0.1)

    var body: some View {
        let pts = workspace.tapeScreen
        ZStack(alignment: .topLeading) {
            if workspace.page == .twoD && !pts.isEmpty {
                Path { p in
                    if pts.count == 2 {
                        p.move(to: pts[0])
                        p.addLine(to: pts[1])
                    }
                }
                .stroke(Self.gold, lineWidth: 2)
                ForEach(pts.indices, id: \.self) { i in
                    Circle().fill(Self.gold).frame(width: 10, height: 10).position(pts[i])
                }
            }
            if pts.count == 2, workspace.tape.count == 2 {
                readout
                    .position(x: min(max((pts[0].x + pts[1].x) / 2, 120), area.width - 120),
                              y: max(min(pts[0].y, pts[1].y) - 36, 40))
            } else if workspace.tool == .measure {
                Text(hint)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: area.width / 2, y: 70)
            }
        }
        .allowsHitTesting(false)
    }

    private var hint: String {
        let m = workspace.tape
        guard let first = m.first else {
            return "Click a point of the print, or a circle or an arc for its size and center. Shift: no snap."
        }
        if first.r > 0 {
            return String(format: "%@, center %.2f, %.2f mm: click a second point to measure from its center.", shape(first), first.x, first.y)
        }
        return String(format: "From %.2f, %.2f, %.2f mm: click a second point.", first.x, first.y, first.z)
    }

    private func shape(_ p: TapePoint) -> String {
        p.shape == 1 ? String(format: "circle ⌀ %.2f mm (radius %.2f)", 2 * p.r, p.r) : String(format: "arc radius %.2f mm", p.r)
    }

    private var readout: some View {
        let a = workspace.tape[0], b = workspace.tape[1]
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let centers = a.r > 0 || b.r > 0
        return VStack(spacing: 2) {
            Text(String(format: "%.2f mm", (dx * dx + dy * dy + dz * dz).squareRoot()))
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(String(format: "ΔX %.2f · ΔY %.2f · ΔZ %.2f", abs(dx), abs(dy), abs(dz))
                 + (abs(dz) > 0.005 ? String(format: " · bed %.2f", (dx * dx + dy * dy).squareRoot()) : ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if centers {
                Text("between the centers · " + [a, b].filter { $0.r > 0 }.map(shape).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}
