//! The card of the Paint tool (Core/PaintTool.swift, web/app/paint.js
//! buildCard): the mode (Smart Select or Brush), the size of the brush, a
//! chip for each filament (the one to paint with), a hint, and Remove All
//! Paint. It sits at the left, next to the tools, so it never covers the
//! part.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct PaintCard: View {
    let workspace: Workspace
    let paint: PaintSession

    var body: some View {
        let model = workspace.model
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Paint").font(.headline)
                Spacer()
                Button { workspace.setTool(.select) } label: {
                    CloseMark()
                }
                .buttonStyle(.borderless)
                .help("Close the Paint tool (P or Esc)")
            }
            Picker("", selection: Binding(get: { paint.mode }, set: { m in
                paint.mode = m
                paint.hover = nil
                workspace.paintUpload()
            })) {
                Text("Smart Select").tag(PaintSession.Mode.smart)
                Text("Brush").tag(PaintSession.Mode.brush)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Smart Select: click a region (a raised letter, a logo, or a face). Brush: drag over the surface.")
            if paint.mode == .brush {
                HStack {
                    Text("Size")
                    Slider(value: Binding(get: { paint.size }, set: { paint.size = $0 }), in: 0.3 ... 10)
                    Text(String(format: "%.1f mm", paint.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            Text("Filament").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(model.filaments) { f in
                    Button { workspace.paintWith(f.index + 1) } label: { FilamentChip(slot: f, selected: paint.filament == f.index + 1, size: 26) }
                        .buttonStyle(.plain)
                        .help("Paint with filament \(f.index + 1) (\(f.material), \(f.color))" + (f.index + 1 == paint.base ? ": the filament of the part" : ""))
                }
                if model.filaments.count < 16 {
                    Button {
                        if let i = model.addFilament() {
                            workspace.paintColors()
                            workspace.paintWith(i + 1)
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                    }
                    .buttonStyle(.plain)
                    .help("Add a filament to the plate")
                }
            }
            Text(paint.mode == .smart
                ? "Click a raised letter, a logo, or a face to paint it. Shift and a click add more. A right drag turns the view."
                : "Drag over the surface to paint it. A right drag turns the view.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Remove All Paint") { workspace.paintClear() }
                .buttonStyle(.link)
                .help("The whole part prints with its own filament again")
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        // A new color of a filament: the palette again.
        .onChange(of: model.filaments) { workspace.paintColors() }
    }
}
