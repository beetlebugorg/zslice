//! Cut: a popover of the part card (web/app/partcard.js, "Cut…"). It
//! cuts the part with a level plane (zs_app_part_cut) into a bottom part
//! and a top part, each closed. The height has a slider and a number, from
//! 0.2 mm to the height of the part less 0.2 mm, and the view shows the
//! plane at once (zs_view_set_cut). "Turn the top over" lays the top part
//! on its cut face. Pegs: holes in both cut faces, and the pegs as parts,
//! to line the halves up when they are glued.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct CutPopover: View {
    let workspace: Workspace
    let index: Int
    @Binding var open: Bool
    @State private var z = 0.0
    @State private var flip = true
    @State private var pegsOn = true
    @State private var pegs = 2
    @State private var diameter = 5.0
    @State private var note: String?

    var body: some View {
        if let p = workspace.part(index) {
            let top = max(0.4, p.size_z - 0.2)
            VStack(alignment: .leading, spacing: 10) {
                Text("Cut the Part").font(.headline)
                HStack {
                    Slider(value: $z, in: 0.2 ... top)
                    TextField("Height", value: $z, format: .number.precision(.fractionLength(1)))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("mm").foregroundStyle(.secondary)
                }
                .help("The height of the cut above the bed")
                Toggle("Turn the top over", isOn: $flip)
                    .help("The top part lies on its cut face, so it prints with no support under the cut")
                HStack(spacing: 4) {
                    Toggle("Pegs to line up the parts:", isOn: $pegsOn)
                    Stepper("\(pegs)", value: $pegs, in: 1 ... 8).disabled(!pegsOn).fixedSize()
                    Text("of").foregroundStyle(.secondary)
                    TextField("Diameter", value: $diameter, format: .number.precision(.fractionLength(1)))
                        .frame(width: 44)
                        .disabled(!pegsOn)
                    Text("mm").foregroundStyle(.secondary)
                }
                .help("Holes in both cut faces, and the pegs as parts on the plate, to glue the halves in line")
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { open = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Cut") { cut(p) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 340)
            .onAppear {
                z = (p.size_z / 2 * 10).rounded() / 10
                showPlane(p)
            }
            .onChange(of: z) { showPlane(p) }
            .onDisappear { hidePlane() }
        }
    }

    /// The parts overlap now: the user moves some to another plate.
    private func askToMove() {
        let a = NSAlert()
        a.messageText = "The parts do not all fit on this bed"
        a.informativeText = "They overlap now. Move some to another plate (+ Plate, then add them there)."
        a.runModal()
    }

    private func showPlane(_ p: zs_part) {
        guard let v = workspace.canvas.view else { return }
        // A square around the footprint, so a turned part is inside it too.
        let r = max(p.size_x, p.size_y) * 0.6 + 4
        zs_view_set_cut(v, p.x - r, p.y - r, p.x + r, p.y + r, min(max(z, 0.2), p.size_z - 0.2))
        workspace.canvas.requestFrame()
    }

    private func hidePlane() {
        guard let v = workspace.canvas.view else { return }
        zs_view_set_cut(v, 0, 0, 0, 0, 0)
        workspace.canvas.requestFrame()
    }

    private func cut(_ p: zs_part) {
        let want = pegsOn ? Int32(pegs) : 0
        let n = zs_app_part_cut(workspace.model.core, index, min(max(z, 0.2), p.size_z - 0.2), flip ? 1 : 0, want, diameter)
        if n == 0 {
            note = "The plane misses the part. Pick another height."
            return
        }
        guard n > 0 else {
            note = "The cut did not work (\(statusText(Int32(n))))."
            return
        }
        hidePlane()
        open = false
        workspace.model.settingsChanged()
        workspace.selectPart(index)
        if zs_app_plate_fits(workspace.model.core) == 0 { askToMove() }
        let fit = Int(n) - 2
        if want > 0, fit < want {
            let a = NSAlert()
            a.messageText = fit == 0 ? "No pegs fit" : "\(fit) of \(want) pegs fit"
            a.informativeText = fit == 0
                ? "The cut face is too small for a peg of \(String(format: "%.1f", diameter)) mm. The halves have no holes."
                : "The cut face has room for \(fit). The pegs are at the end of the plate."
            a.runModal()
        }
    }
}
