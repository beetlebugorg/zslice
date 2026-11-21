//! The search of settings and actions (docs/internals/one-view.md,
//! web/app/search.js, linux/src/ui/search.c). `/` opens it over the view.
//!
//! The results are live controls: a number has its field and a slider, a
//! choice its menu, a switch its switch. A change goes to the core at once
//! (a drag sends a value at most each 90 ms), the core slices again, and
//! the view behind the search shows the new slice. The core ranks the
//! settings (zs_setting_search: the words, their other names in other
//! slicers, and a boost for the common settings); the shell ranks its few
//! actions by a plain match of their words. The eye of a setting
//! shows only the lines that it changes, with the other lines as ghosts,
//! while the search is open. An action runs with a click or Return.
//!
//! The search does not block the view: a drag in the view turns it, the
//! wheel zooms, and a click picks a line, while the search stays open.
//! Up and Down go through the results, Return runs an action or turns a
//! switch, and Esc closes. Return on a number or a text goes into its
//! field with the text selected: a typed number replaces it, and Up and
//! Down step it. Return there sends the value and goes back to the
//! search, for the next Up or Down; Esc goes back with no change. A drag of the top bar moves the box; it opens at
//! the same place next time, and a double click on the bar puts it back.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A command that the search can run.
struct SearchAction: Identifiable {
    let label: String
    let keys: String
    let run: () -> Void
    var id: String { label }
}

struct SearchOverlay: View {
    let workspace: Workspace
    @State private var query = ""
    @State private var index = 0
    @State private var drag: CGSize = .zero
    /// A drag of the head moves the search from its place under the Search
    /// button, and it keeps that offset.
    @AppStorage("search.dx", store: prefs) private var placeX = 0.0
    @AppStorage("search.dy", store: prefs) private var placeY = 0.0
    static let width: CGFloat = 400
    @FocusState private var fieldFocus: Bool
    /// The setting whose field takes the focus next (Return on its row).
    @State private var editing: String?

    private static let maxSettings = 14
    private static let maxActions = 4

    private var model: SliceModel { workspace.model }

    private var actions: [SearchAction] {
        [
            SearchAction(label: "Export G-code…", keys: "⌘E") { workspace.exportGcode(from: NSApp.keyWindow) },
            SearchAction(label: "Test Print: the Top Layer…", keys: "") { workspace.saveTestPrint(lo: workspace.hi, hi: workspace.hi + 1) },
            SearchAction(label: "Test Print: the Layers Shown…", keys: "") { workspace.saveTestPrint(lo: workspace.lo, hi: workspace.hi + 1) },
            SearchAction(label: "Undo", keys: "⌘Z") { model.history.undoManager.undo() },
            SearchAction(label: "Redo", keys: "⇧⌘Z") { model.history.undoManager.redo() },
            SearchAction(label: "Show the 3D View", keys: "⌘1") { workspace.page = .threeD },
            SearchAction(label: "Show the 2D Layer View", keys: "⌘2") { workspace.page = .twoD },
            SearchAction(label: "Fit the Part", keys: "⌘0") { workspace.fit() },
            SearchAction(label: "Show or Hide the Settings", keys: "N") { workspace.showSettings.toggle() },
            SearchAction(label: "Measure", keys: "T") { workspace.setTool(.measure) },
            SearchAction(label: "Move a Part", keys: "M") { workspace.setTool(.move) },
            SearchAction(label: "Turn a Part", keys: "R") { workspace.setTool(.turn) },
            SearchAction(label: workspace.simulated ? "Show the Plan" : "Show the Print as It Forms (Simulated Plastic)", keys: "") { workspace.toggleSimulation() },
        ] + (workspace.model.project == nil ? [] : [SearchAction(label: "Close the Project", keys: "") { workspace.closeProject() }])
    }

    private var words: [String] {
        query.lowercased().split(separator: " ").map(String.init)
    }

    private var settings: [SettingInfo] {
        let w = words
        guard !w.isEmpty else { return [] }
        // The core ranks the settings (zs_setting_search).
        return SettingInfo.search(query, max: Self.maxSettings)
    }

    private var matchingActions: [SearchAction] {
        let w = words
        guard !w.isEmpty else { return [] }
        return Array(actions.filter { a in w.allSatisfy { a.label.lowercased().contains($0) } }.prefix(Self.maxActions))
    }

    var body: some View {
        let found = settings
        let acts = matchingActions
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocus)
                    .onSubmit { runSelected(found, acts) }
                    .onKeyPress(.downArrow) { move(1, found.count + acts.count) }
                    .onKeyPress(.upArrow) { move(-1, found.count + acts.count) }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(10)
            if !query.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(acts.enumerated()), id: \.element.id) { i, a in
                            Button {
                                a.run()
                            } label: {
                                HStack {
                                    Image(systemName: "bolt").foregroundStyle(.secondary).frame(width: 18)
                                    Text(a.label)
                                    Spacer()
                                    Text(a.keys).foregroundStyle(.secondary).font(.callout)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(i == index ? Color.accentColor.opacity(0.15) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(Array(found.enumerated()), id: \.element.id) { i, info in
                            SearchRow(workspace: workspace, info: info, selected: acts.count + i == index, editing: $editing) {
                                fieldFocus = true
                            }
                        }
                        if found.isEmpty && acts.isEmpty {
                            Text("No setting or action matches.")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .offset(x: placeX + drag.width, y: placeY + drag.height)
        .onAppear {
            fieldFocus = true
            if let t = ProcessInfo.processInfo.environment["ZSLICE_SEARCH"] { query = t }
        }
        .onChange(of: query) { index = 0 }
    }

    private var header: some View {
        HStack {
            Text("Search").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .help("Drag to move the search. A double click puts it back.")
        .gesture(DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { g in
                placeX += g.translation.width
                placeY += g.translation.height
                drag = .zero
            })
        .onTapGesture(count: 2) {
            placeX = 0
            placeY = 0
        }
    }

    private func move(_ d: Int, _ n: Int) -> KeyPress.Result {
        guard n > 0 else { return .ignored }
        index = (index + d + n) % n
        return .handled
    }

    private func runSelected(_ found: [SettingInfo], _ acts: [SearchAction]) {
        if index < acts.count {
            acts[index].run()
        } else if index - acts.count < found.count {
            let info = found[index - acts.count]
            if info.kind == .boolean {
                model.set(info.name, model.entry(info.name).value == "true" ? "false" : "true")
            } else if info.kind != .choice, !info.multiline {
                editing = info.name
            }
        }
    }

    private func close() {
        workspace.searchOpen = false
        workspace.canvas.window?.makeFirstResponder(workspace.canvas)
    }
}

/// One setting of the search: its label, its source, the eye, and its
/// live editor (with a slider for a number).
private struct SearchRow: View {
    let workspace: Workspace
    let info: SettingInfo
    let selected: Bool
    @Binding var editing: String?
    /// The focus goes back to the search field.
    let back: () -> Void

    var body: some View {
        let model = workspace.model
        let entry = model.entry(info.name)
        let eye = workspace.searchEye == info.name
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    workspace.searchEye = eye ? nil : info.name
                } label: {
                    Image(systemName: eye ? "eye.fill" : "eye")
                        .foregroundStyle(eye ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                // Tab goes to the value, not to the eye.
                .focusable(false)
                .help("Show only the lines that this setting changes")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(info.label)
                        if OwnerBadge.owns(info.group) { OwnerBadge(model: model, group: info.group) }
                    }
                    let src = entry.sourceText
                    // The badge names the group of a printer or filament setting.
                    Text((OwnerBadge.owns(info.group) ? info.section : "\(SettingInfo.groupTitle(info.group)) · \(info.section)") + (src.isEmpty ? "" : " · \(src)"))
                        .font(.caption)
                        .foregroundStyle(entry.isMine ? Color.accentColor : .secondary)
                }
                .help(info.doc)
                Spacer(minLength: 8)
                SettingEditor(model: model, info: info, entry: entry, compact: true, focusRequest: $editing, onDone: back)
            }
            if info.hasSlider {
                QuickSlider(model: model, info: info, entry: entry)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
        .onHover { inside in
            guard workspace.searchEye == nil else { return }
            let e = SettingEffect(info.name)
            workspace.focus(inside ? e.features : 0, firstLayer: e.firstLayerOnly, always: true)
        }
    }
}

/// The slider of a number setting, sending at most each 90 ms in a drag.
struct QuickSlider: View {
    let model: SliceModel
    let info: SettingInfo
    let entry: SettingEntry
    @State private var throttle = Throttle()

    var body: some View {
        if let v = Double(entry.value) {
            let k = info.isRatio ? 100.0 : 1
            Slider(value: Binding(get: { v * k }, set: { x in
                let text = ValueText.number(((x / k) / info.step).rounded() * info.step)
                throttle.run { model.set(info.name, text) }
            }), in: info.sliderMin * k ... info.sliderMax * k)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}
