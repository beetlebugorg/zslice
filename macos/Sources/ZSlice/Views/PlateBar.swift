//! The plate bar (docs/internals/one-view.md, web/app/app.js
//! updatePlateBar): the plate that the window shows, the plate before and
//! the next plate ([ and ]), All (Home: the camera shows all plates),
//! + Plate (a new empty plate), and × (remove the plate). All plates are in
//! one view, in a row; each plate slices, the active plate first.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct PlateBar: View {
    let workspace: Workspace
    /// In the dock: no capsule of its own.
    var bare = false

    var body: some View {
        let model = workspace.model
        let n = model.plates.count
        let i = model.active
        HStack(spacing: 6) {
            Button { workspace.selectPlate(i - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(i <= 0)
                .help("The plate before ([)")
            Menu {
                ForEach(model.plates.indices, id: \.self) { k in
                    let p = model.plates[k]
                    Toggle(isOn: Binding(get: { k == i }, set: { _ in workspace.selectPlate(k) })) {
                        Text("\(k + 1). \(p.name.isEmpty ? "Empty plate" : p.name) · \(status(p))")
                    }
                }
                if bare {
                    Divider()
                    Button("Show All Plates") { workspace.framePlate(-1) }.disabled(n < 2)
                    Button("New Plate") { workspace.model.addPlate() }
                    Button("Remove This Plate") { workspace.removePlate(i) }.disabled(n < 2)
                }
            } label: {
                Text(bare ? "Plate \(i + 1)/\(max(n, 1))" : "Plate \(i + 1) of \(max(n, 1))").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { workspace.selectPlate(i + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(i >= n - 1)
                .help("The next plate (])")
            Divider().frame(height: 16)
            // The printer of this plate: it slices for that printer, and the
            // Printers page sends it there.
            Menu {
                ForEach(PrinterStore.shared.printers) { p in
                    Toggle(p.name, isOn: Binding(get: { workspace.assigned(plate: i)?.id == p.id }, set: { _ in workspace.assign(plate: i, to: p) }))
                }
                if PrinterStore.shared.printers.isEmpty {
                    Button("Add a Printer…") { workspace.pickerOpen = true }
                }
            } label: {
                if bare {
                    Image(systemName: workspace.assigned(plate: i) == nil ? "printer" : "printer.fill")
                } else {
                    Label(workspace.assigned(plate: i)?.name ?? "Printer", systemImage: "printer")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The printer of this plate: the plate slices for it, and the Printers page sends it there")
            if n > 1, !bare {
                Button("All") { workspace.framePlate(-1) }
                    .help("Show all plates (Home)")
                Button { workspace.removePlate(i) } label: { Image(systemName: "xmark") }
                    .help("Remove this plate")
            }
            Divider().frame(height: 16)
            Button { workspace.model.addPlate() } label: {
                if bare { Image(systemName: "plus.rectangle.on.rectangle") } else { Label("Plate", systemImage: "plus") }
            }
                .help("A new empty plate, after the others (⌥⌘N)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, bare ? 0 : 12)
        .padding(.vertical, bare ? 0 : 6)
        .background(bare ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial), in: Capsule())
    }

    private func status(_ p: PlateInfo) -> String {
        switch Int(p.status) {
        case Int(ZS_PLATE_STATUS_EMPTY.rawValue): "empty"
        case Int(ZS_PLATE_STATUS_STALE.rawValue): "to slice"
        case Int(ZS_PLATE_STATUS_SLICING.rawValue): "slicing"
        case Int(ZS_PLATE_STATUS_DONE.rawValue): "sliced"
        case Int(ZS_PLATE_STATUS_FAILED.rawValue): "failed"
        default: "cannot slice"
        }
    }
}
