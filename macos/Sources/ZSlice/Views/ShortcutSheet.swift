//! The sheet of all keyboard shortcuts of the Mac app, in the groups of
//! the web and Linux sheets (web/app/shortcuts.js), in two columns. `?` in the view, or Help > Keyboard Shortcuts, opens it.
//! Type in its field to filter it. Each shell owns its table: the keys
//! follow the conventions of its platform (docs/internals/one-view.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    /// The table: the groups of the web and Linux sheets, and in each the
    /// keys of the Mac and what they do.
    static let table: [(group: String, rows: [(keys: String, what: String)])] = [
        ("General", [
            ("?", "Show this sheet of the keyboard shortcuts (also Help > Keyboard Shortcuts)"),
            ("/ or ⌘F", "Search the settings and the actions: the field of the toolbar (or the card of an undocked search)"),
            ("N or ⌥⌘I", "Show or hide the settings"),
            ("2", "The 2D view of one layer, and 2 again the 3D view (also View > 2D View, ⌘2)"),
            ("3", "The 3D view"),
            ("B", "Hide the bed and its grid, or show them again: the bottom of a part shows from below (also View > Hide the Bed)"),
            ("⌘0", "Fit the part"),
            ("⌘O", "Open a model or a project"),
            ("⌘S", "Save the project: all plates in one 3MF file"),
            ("⌘E", "Export the G-code"),
            ("⌘Z", "Undo"),
            ("⇧⌘Z", "Redo"),
            ("Esc", "Clear the measure, the selection, or close a card"),
        ]),
        ("Copy and paste", [
            ("⌘C", "Copy the selection: parts, a label, a support area, the changes of the selected layers, or the report of a line"),
            ("⌘X", "Cut the selection: a copy, then it goes"),
            ("⌘V", "Paste: parts next to the selected parts, else at the pointer; a label or a support area on the part under the pointer; layer changes on the selected layers"),
            ("⇧⌘V", "Paste the copied parts or plate as a new plate"),
            ("⌘D", "Duplicate the selected parts or the selected label"),
        ]),
        ("Plates", [
            ("]", "The next plate: make it active, and show it"),
            ("[", "The plate before: make it active, and show it"),
            ("F", "Show the active plate"),
            ("Home", "Show all plates (with one plate: the start view)"),
        ]),
        ("Tools", [
            ("V", "Select: click a line"),
            ("M", "Move: drag a part"),
            ("R", "Turn: ← → about Z, ↑ ↓ about X, Page Up and Page Down about Y (Shift: 5°)"),
            ("S or U", "Support: draw an area of support (S again: show or hide its card)"),
            ("G", "Grab: click a part to pick it up, move to carry it (⌥: turn, ⇧: 15°, wheel: lift), click or Esc to let go"),
            ("T", "Measure: click two points (Shift: no snap)"),
            ("P", "Paint: click a region of a part to paint it with a filament (Shift: add more), or drag the brush; Esc closes"),
            ("E", "Label: click a face of a part to put a label there. Drag it to move it (Shift: in its plane), the wheel over it turns it (Shift: 15°), its handle scales it, Delete removes it; Esc closes the card, then the tool"),
            ("⌘-drag", "Move a part in any tool"),
            ("⌘-scroll", "Turn the selected part by 15°"),
            ("Tab, ⇧Tab", "Select the next part, or the part before"),
            ("← → ↑ ↓ (a part)", "Move the selected parts 1 mm (Shift: 10 mm)"),
            ("D, ⌘D", "Duplicate the selected parts"),
            ("Delete", "Remove the selected parts or support; on a selected line, take the line out of the print"),
            ("Shift-click", "Select tool: the run of the line, one extrusion from a retraction to the next. Other tools: add a part to the selection, or take it out"),
            ("⌘⇧-click", "Add a part to the selection, or take it out"),
        ]),
        ("Layers", [
            ("↑ ↓ or K J", "The top layer up or down (with a selected line: the nearest line one layer up or down)"),
            ("Shift ↑ ↓", "The bottom layer up or down"),
            ("Page Up, Page Down", "10 layers up or down"),
            ("⌃F, ⌃B", "A page of layers up or down (5 % of the print)"),
            ("Shift-K, Shift-J", "Select layers: the range grows up or down, and its card opens"),
            ("C", "The layers up to the selected line"),
            ("Shift-C", "All layers"),
        ]),
        ("Lines and the nozzle", [
            ("← or h", "The segment before the selected one (no selection: the nozzle back 2 % of the layer)"),
            ("→ or l", "The next segment (no selection: the nozzle on 2 % of the layer)"),
            ("Shift ← →", "The line before, or the next line"),
            ("Shift-H, Shift-L", "The line before or after"),
        ]),
        ("Search", [
            ("↑ ↓", "Go through the results"),
            ("Return", "Edit the value of the result, or run the action"),
            ("Esc", "Close the search"),
        ]),
        ("Settings", [
            ("⌘[", "Back in the settings"),
            ("↑ ↓ in a field", "A step of the value"),
        ]),
        ("History", [
            ("⌘Y", "Show or hide the history"),
        ]),
        ("Mouse and touchpad", [
            ("Drag, right-drag (mouse)", "Orbit the view"),
            ("Two fingers clicked down and slid (trackpad), middle-drag, Shift-drag", "Pan the view"),
            ("Two-finger scroll, wheel, pinch", "Zoom toward the pointer"),
            ("Drag from a line (Select)", "Select a range of layers, and edit their settings"),
            ("Click a support line (Select)", "Select that support: drag a tree, or Delete"),
            ("Double-click a side", "Face that side (on no side: the start view)"),
            ("Right click", "The menu of the view"),
        ]),
    ]

    /// The groups in two columns, about the same height: the groups keep
    /// their order, down the left column and then the right.
    static func columns(_ groups: [(group: String, rows: [(keys: String, what: String)])]) -> [[(group: String, rows: [(keys: String, what: String)])]] {
        let total = groups.reduce(0) { $0 + $1.rows.count + 2 }
        var left: [(group: String, rows: [(keys: String, what: String)])] = [], n = 0
        for g in groups where n < total / 2 {
            left.append(g)
            n += g.rows.count + 2
        }
        return [left, Array(groups.dropFirst(left.count))]
    }

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
                let groups = Self.table.map { g in
                    (group: g.group, rows: g.rows.filter { needle.isEmpty || $0.keys.lowercased().contains(needle) || $0.what.lowercased().contains(needle) })
                }.filter { !$0.rows.isEmpty }
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(Self.columns(groups).enumerated()), id: \.offset) { _, col in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(col, id: \.group) { g in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(g.group).font(.headline)
                                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
                                        ForEach(g.rows, id: \.keys) { r in
                                            GridRow {
                                                Text(r.keys)
                                                    .font(.callout.monospaced())
                                                    .frame(width: 170, alignment: .leading)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                Text(r.what)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .frame(width: 960, height: 640)
    }
}
