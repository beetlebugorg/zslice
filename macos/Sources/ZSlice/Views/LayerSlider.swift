//! LayerSlider: the vertical slider with two knobs for the layers that
//! show (linux/src/ui/layer-range.c, web/app/layers.js). The top knob is the
//! top layer. The bottom knob is the lowest layer that shows, so the inside
//! of the part at that layer is visible.
//!
//! A drag of a knob moves it. A click on the trough moves the nearer knob
//! there. The number of the top layer is next to its knob (with a snowflake
//! for a layer that slows down to cool), and the number of the bottom layer
//! when the range does not start at the first layer. The arrow keys of the
//! 3D view move the knobs (Workspace.sliceViewKey).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct LayerSlider: View {
    let workspace: Workspace
    @State private var dragging: Knob?

    private enum Knob { case hi, lo }
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - knob
            let top = max(1, workspace.layerCount - 1)
            let y = { (layer: Int) in knob / 2 + h * (1 - CGFloat(layer) / CGFloat(top)) }
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, knob / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: max(0, y(workspace.lo) - y(workspace.hi)))
                    .offset(y: y(workspace.hi))
                knobView.offset(y: y(workspace.hi) - knob / 2)
                knobView.offset(y: y(workspace.lo) - knob / 2)
                bubble(workspace.hi, slowed: workspace.isSlowed(workspace.hi))
                    .offset(x: -36, y: y(workspace.hi) - 10)
                if workspace.lo > 0 && workspace.lo < workspace.hi {
                    bubble(workspace.lo, slowed: false)
                        .offset(x: -36, y: max(y(workspace.lo), y(workspace.hi) + 22) - 10)
                }
            }
            .frame(width: geo.size.width)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = 1 - (g.location.y - knob / 2) / max(1, h)
                let v = Int((min(1, max(0, f)) * CGFloat(top)).rounded())
                if dragging == nil {
                    dragging = abs(v - workspace.hi) <= abs(v - workspace.lo) ? .hi : .lo
                }
                if dragging == .hi {
                    workspace.setRange(lo: min(workspace.lo, v), hi: v)
                } else {
                    workspace.setRange(lo: v, hi: max(workspace.hi, v))
                }
            }.onEnded { _ in dragging = nil })
        }
        .frame(width: 24)
        .help(help)
        .accessibilityElement()
        .accessibilityLabel("Layers")
        .accessibilityValue("Layer \(workspace.hi + 1) of \(workspace.layerCount)")
        .accessibilityAdjustableAction { dir in
            workspace.moveTop(dir == .increment ? 1 : -1)
        }
    }

    private var knobView: some View {
        Circle()
            .fill(.background)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: knob, height: knob)
            .shadow(radius: 1, y: 0.5)
    }

    private func bubble(_ layer: Int, slowed: Bool) -> some View {
        Text((slowed ? "❄ " : "") + "\(layer + 1)")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
            .frame(width: 0, alignment: .trailing)
    }

    private var help: String {
        String(format: "Layer %d of %d, at z %.2f mm. Drag a knob: the top knob is the top layer, and the bottom knob the lowest layer that shows. Up and Down move the top knob; Shift with them moves the bottom knob.",
               workspace.hi + 1, workspace.layerCount, workspace.z(of: workspace.hi))
    }
}
