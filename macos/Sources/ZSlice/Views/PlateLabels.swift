//! The plate labels of the 3D view (web/app/app.js, placePlateLabels): with
//! two plates or more, each plate has a label with its number, its name,
//! and its status. The labels stay in a row at the top of the view, each
//! over the middle of its plate, so they never cover a part. A label that
//! covers one at its left moves right, and all stay in the view. A click
//! on a label makes its plate the active plate; a right click removes it.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI

/// A label of a plate, placed: its plate, its text, and its center x.
struct PlateLabel: Equatable {
    var plate: Int
    var text: String
    var status: String
    var x: CGFloat
}

extension Workspace {
    /// The labels in their places, for the frame that the view drew.
    func placePlateLabels() {
        let plates = model.plates
        guard plates.count > 1, page == .threeD, let v = canvas.view else {
            if !plateLabels.isEmpty { plateLabels = [] }
            return
        }
        let width = canvas.bounds.width
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        var out: [(label: PlateLabel, w: CGFloat)] = []
        for (i, p) in plates.enumerated() {
            var ox = 0.0, oy = 0.0
            guard zs_view_plate_origin(v, i, &ox, &oy) == 0,
                  let q = canvas.viewPoint(x: ox + p.bedX / 2, y: oy + p.bedY / 2, z: 0),
                  q.x > -40, q.x < width + 40 else { continue }
            let text = "\(i + 1). \(p.name.isEmpty ? "Empty plate" : p.name)"
            let status = plateStatusText(p)
            let w = ((text + (status.isEmpty ? "" : "  " + status)) as NSString).size(withAttributes: [.font: font]).width + 18
            out.append((PlateLabel(plate: i, text: text, status: status, x: q.x), w))
        }
        out.sort { $0.label.x < $1.label.x }
        // Right of the tool strip, and clear of the layer slider.
        var edge: CGFloat = 76
        for k in out.indices {
            let w = out[k].w
            let x = min(max(out[k].label.x - w / 2, edge), width - 84 - w)
            out[k].label.x = x + w / 2
            edge = x + w + 6
        }
        let labels = out.map(\.label)
        if labels.count != plateLabels.count || zip(labels, plateLabels).contains(where: { $0.plate != $1.plate || $0.text != $1.text || $0.status != $1.status || abs($0.x - $1.x) > 0.5 }) {
            plateLabels = labels
        }
    }
}

/// The status of a plate in words; "" for a sliced plate.
func plateStatusText(_ p: PlateInfo) -> String {
    switch Int(p.status) {
    case Int(ZS_PLATE_STATUS_EMPTY.rawValue): "empty"
    case Int(ZS_PLATE_STATUS_STALE.rawValue): "to slice"
    case Int(ZS_PLATE_STATUS_SLICING.rawValue): "slicing"
    case Int(ZS_PLATE_STATUS_DONE.rawValue): ""
    case Int(ZS_PLATE_STATUS_FAILED.rawValue): "failed"
    default: "cannot slice"
    }
}

struct PlateLabels: View {
    let workspace: Workspace

    var body: some View {
        ForEach(workspace.plateLabels, id: \.plate) { l in
            let active = l.plate == workspace.model.active
            HStack(spacing: 6) {
                Text(l.text)
                if !l.status.isEmpty { Text(l.status).opacity(0.75) }
            }
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(white: 0.18).opacity(0.82)),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { workspace.selectPlate(l.plate) }
            .contextMenu {
                Button("Remove Plate \(l.plate + 1)") { workspace.removePlate(l.plate) }
            }
            .help(active ? "The active plate" : "Show this plate")
            .position(x: l.x, y: 64)
        }
    }
}
