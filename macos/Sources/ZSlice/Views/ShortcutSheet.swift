//! The sheet of all keyboard shortcuts of the Mac app, grouped (the view,
//! the tools, the layers, the selected line, the settings, the history,
//! the print). `?` in the view, or Help > Keyboard Shortcuts, opens it.
//! Type in its field to filter it. Each shell owns its table: the keys
//! follow the conventions of its platform (docs/internals/one-view.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    /// The table: the groups, and in each the keys and what they do.
    static let table: [(group: String, rows: [(keys: String, what: String)])] = [
        ("View", [
            ("Drag, right-drag (mouse)", "Orbit the view"),
            ("Two fingers clicked down and slid (trackpad), middle-drag, Shift-drag", "Pan the view"),
            ("Shift-click", "Select tool: the run of the line, one extrusion from a retraction to the next. Other tools: add a part to the selection, or take it out"),
            ("Command-Shift-click", "Select tool: add a part to the selection, or take it out"),
            ("Drag from a line (Select)", "Select a range of layers, and edit their settings"),
            ("Click a support line (Select)", "Select that support: drag a tree, or Delete"),
            ("Two-finger scroll, wheel, pinch", "Zoom toward the pointer"),
            ("Double-click a side", "Face that side (on no side: the start view)"),
            ("2", "The 2D view of one layer, and 2 again the 3D view (also View > 2D View, ⌘2)"),
            ("3", "The 3D view"),
            ("⌘0", "Fit the part"),
        ]),
        ("Tools", [
            ("V", "Select: click a line"),
            ("M", "Move: drag a part"),
            ("R", "Turn: ← → about Z, ↑ ↓ about X, Page Up and Page Down about Y (Shift: 5°)"),
            ("T", "Measure: click two points (Shift: no snap)"),
            ("H", "Grab: click a part to pick it up, move to carry it (⌥: turn, ⇧: 15°, wheel: lift), click or Esc to let go"),
            ("S or U", "Support: draw an area of support (S again: show or hide its card)"),
            ("P", "Paint: click a region of a part to paint it with a filament (Shift: add more), or drag the brush; Esc closes"),
            ("L", "Label: click a face of a part to put a label there. Drag it to move it (Shift: in its plane), the wheel over it turns it (Shift: 15°), its handle scales it, Delete removes it; Esc closes the card, then the tool"),
            ("⌘-drag", "Move a part in any tool"),
            ("⌘-scroll", "Turn the selected part by 15°"),
            ("Esc", "Clear the measure, the selection, or close a card"),
        ]),
        ("Layers", [
            ("↑ ↓ or k j", "The top layer up or down"),
            ("Shift ↑ ↓", "The bottom layer up or down"),
            ("Page Up, Page Down", "10 layers up or down"),
            ("⌃F, ⌃B", "A page of layers up or down (5 % of the print)"),
            ("Shift-K, Shift-J", "Select layers: the range grows up or down, and its card opens"),
            ("← →", "The nozzle back or on in the top layer"),
            ("Shift-C", "All layers"),
        ]),
        ("Selected line", [
            ("← →", "The segment before or after (Shift: the line)"),
            ("Shift-H, Shift-L", "The line before or after"),
            ("↑ ↓ or k j", "The nearest line on the layer above or below"),
            ("C", "The layers up to the line"),
            ("Esc", "Clear the selection"),
        ]),
        ("Settings", [
            ("/ or ⌘F", "Search the settings and the actions: the field of the toolbar (or the card of an undocked search)"),
            ("N or ⌥⌘I", "Show or hide the settings"),
            ("⌘[", "Back in the settings"),
            ("↑ ↓ in a field", "A step of the value"),
        ]),
        ("History", [
            ("⌘Z", "Undo"),
            ("⇧⌘Z", "Redo"),
        ]),
        ("Print", [
            ("⌘E", "Export the G-code"),
            ("⌘O", "Open a model"),
        ]),
    ]

    var body: some View {
        let needle = filter.lowercased()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
                Spacer()
                SearchField(text: $filter, prompt: "Filter")
                    .frame(width: 200)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.table, id: \.group) { g in
                        let rows = g.rows.filter { needle.isEmpty || $0.keys.lowercased().contains(needle) || $0.what.lowercased().contains(needle) }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.group).font(.headline)
                                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                    ForEach(rows, id: \.keys) { r in
                                        GridRow {
                                            Text(r.keys)
                                                .font(.callout.monospaced())
                                                .frame(width: 240, alignment: .leading)
                                            Text(r.what).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 560)
    }
}
