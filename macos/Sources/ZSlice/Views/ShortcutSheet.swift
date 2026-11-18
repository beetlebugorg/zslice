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
            ("Drag", "Orbit the view"),
            ("Right-drag, middle-drag, two-finger press-drag", "Pan the view"),
            ("Two-finger scroll, wheel, pinch", "Zoom toward the pointer"),
            ("Double-click a side", "Face that side (on no side: the start view)"),
            ("⌘1, ⌘2", "The 3D view, the 2D layer view"),
            ("⌘0", "Fit the part"),
        ]),
        ("Tools", [
            ("V", "Select: click a line"),
            ("M", "Move: drag a part"),
            ("R", "Turn: ← → about Z, ↑ ↓ about X, Page Up and Page Down about Y (Shift: 5°)"),
            ("T", "Measure: click two points (Shift: no snap)"),
            ("S or U", "Support: draw an area of support (S again: show or hide its card)"),
            ("⌘-drag", "Move a part in any tool"),
            ("⌘-scroll", "Turn the selected part by 15°"),
            ("Esc", "Clear the measure, the selection, or close a card"),
        ]),
        ("Layers", [
            ("↑ ↓ or k j", "The top layer up or down"),
            ("Shift ↑ ↓", "The bottom layer up or down"),
            ("Page Up, Page Down", "10 layers up or down"),
            ("← → or h l", "The nozzle back or on in the top layer"),
            ("Shift-C", "All layers"),
        ]),
        ("Selected line", [
            ("← → or h l", "The segment before or after (Shift: the line)"),
            ("↑ ↓ or k j", "The nearest line on the layer above or below"),
            ("C", "The layers up to the line"),
            ("Esc", "Clear the selection"),
        ]),
        ("Settings", [
            ("/ or ⌘F", "Search the settings and the actions"),
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
