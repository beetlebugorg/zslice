//! The search of settings and actions (docs/internals/one-view.md,
//! web/app/search.js, linux/src/ui/search.c).
//!
//! The search field is always in the toolbar. Text in it, a click in it,
//! `/`, or Command-F shows the results under it. Esc, `/`, or the close
//! button of the results hides them. The undock button of the field makes
//! the search a card over the view, with its own field: a drag of its head
//! moves it, its corner changes its size, and it opens at the same place
//! and size next time (SpatialCards.swift, the kind "search"). The app
//! keeps the choice to undock. While the search is undocked, the toolbar
//! has a Search button that opens the card, and the dock button of the
//! card puts the search back in the toolbar.
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
//! wheel zooms, and a click picks a line, while the results stay open.
//! Up and Down go through the results, and Return runs an action or turns
//! a switch. Return on a number or a text goes into its field with the
//! text selected: a typed number replaces it, and Up and Down step it.
//! Return there sends the value and goes back to the search field, for the
//! next Up or Down; Esc goes back with no change.
//!
//! The state of the search (SearchState) is the same for the field of the
//! toolbar and the field of the card, so the text stays when it moves.
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

/// The text, the results shown, the selected row, and the place of the
/// search (the toolbar or a card).
@MainActor
@Observable
final class SearchState {
    var query = "" {
        didSet {
            index = 0
            if !query.isEmpty { open = true }
        }
    }
    /// The results show (docked), or the card shows (undocked).
    var open = false
    /// The left edge of the first item at the right of the toolbar.
    var rightItemsX: CGFloat = 0
    var index = 0
    /// The setting whose field takes the focus next (Return on its row).
    var editing: String?
    /// The search is in the toolbar; false: a card over the view.
    var docked = prefs.object(forKey: "search.docked") as? Bool ?? true {
        didSet { prefs.set(docked, forKey: "search.docked") }
    }
    /// Off the toolbar: a rail of the view ("left", beside the tool strip,
    /// or "right"), the height of the view, or "" for a card. A rail and a
    /// card stay open at a click outside, until × or Esc.
    var rail = prefs.string(forKey: "search.rail") ?? "" {
        didSet { prefs.set(rail, forKey: "search.rail") }
    }
    /// A field asks for the focus when this changes.
    var focusTick = 0

    /// Where the search goes: "toolbar", "card", "left", or "right".
    func place(_ p: String) {
        docked = p == "toolbar"
        rail = p == "left" || p == "right" ? p : ""
        show()
    }

    /// The place now, as for `place`.
    var placeName: String { docked ? "toolbar" : rail.isEmpty ? "card" : rail }
    /// The left edge of the field of the toolbar in the window, for the
    /// results under it.
    var fieldMinX: CGFloat = 0

    static let maxSettings = 14
    static let maxActions = 4

    var words: [String] { query.lowercased().split(separator: " ").map(String.init) }

    /// The settings that match, without the settings of a nozzle that the
    /// printer does not have.
    func settings(_ workspace: Workspace) -> [SettingInfo] {
        guard !words.isEmpty else { return [] }
        // The core ranks the settings (zs_setting_search).
        let nozzles = workspace.model.nozzleCount
        return SettingInfo.search(query, max: Self.maxSettings).filter { $0.on(nozzles: nozzles) }
    }

    func actions(_ workspace: Workspace) -> [SearchAction] {
        let w = words
        guard !w.isEmpty else { return [] }
        return Array(Self.allActions(workspace).filter { a in w.allSatisfy { a.label.lowercased().contains($0) } }.prefix(Self.maxActions))
    }

    static func allActions(_ workspace: Workspace) -> [SearchAction] {
        let model = workspace.model
        return [
            SearchAction(label: "Export G-code…", keys: "⌘E") { workspace.exportGcode(from: NSApp.keyWindow) },
            SearchAction(label: "Test Print: the Top Layer…", keys: "") { workspace.saveTestPrint(lo: workspace.hi, hi: workspace.hi + 1) },
            SearchAction(label: "Test Print: the Layers Shown…", keys: "") { workspace.saveTestPrint(lo: workspace.lo, hi: workspace.hi + 1) },
            SearchAction(label: "Import from a Model Page…", keys: "") { workspace.askModelPage() },
            SearchAction(label: "Undo", keys: "⌘Z") { model.history.undoManager.undo() },
            SearchAction(label: "Redo", keys: "⇧⌘Z") { model.history.undoManager.redo() },
            SearchAction(label: "Show the 3D View", keys: "3") { workspace.page = .threeD },
            SearchAction(label: "Show the 2D View", keys: "2") { workspace.page = .twoD },
            SearchAction(label: "Fit the Part", keys: "⌘0") { workspace.fit() },
            SearchAction(label: "Show or Hide the Settings", keys: "N") { workspace.showSettings.toggle() },
            SearchAction(label: "Measure", keys: "T") { workspace.setTool(.measure) },
            SearchAction(label: "Move a Part", keys: "M") { workspace.setTool(.move) },
            SearchAction(label: "Turn a Part", keys: "R") { workspace.setTool(.turn) },
            SearchAction(label: workspace.simulated ? "Show the Plan" : "Show the Print as It Forms (Simulated Plastic)", keys: "") { workspace.toggleSimulation() },
        ] + (model.project == nil ? [] : [SearchAction(label: "Close the Project", keys: "") { workspace.closeProject() }])
    }

    func move(_ d: Int, _ workspace: Workspace) -> KeyPress.Result {
        let n = actions(workspace).count + settings(workspace).count
        guard n > 0 else { return .ignored }
        index = (index + d + n) % n
        return .handled
    }

    /// Return in a field: run the selected action, turn a switch, or go
    /// into the field of a number or a text.
    func runSelected(_ workspace: Workspace) {
        let acts = actions(workspace), found = settings(workspace)
        if index < acts.count {
            acts[index].run()
        } else if index - acts.count < found.count {
            let info = found[index - acts.count]
            if info.kind == .boolean {
                workspace.model.set(info.name, workspace.model.entry(info.name).value == "true" ? "false" : "true")
            } else if info.kind != .choice, !info.multiline {
                editing = info.name
            }
        }
    }

    /// `/` and Command-F: the field of the toolbar takes the focus, or the
    /// card opens.
    func show() {
        open = true
        focusTick += 1
    }
}

/// The field of the search in the toolbar, with the undock button; or the
/// Search button while the search is a card.
struct SearchToolbarItem: View {
    let workspace: Workspace
    @FocusState private var focused: Bool
    @State private var hovering = false

    /// The width that keeps the field in the center of the window: twice
    /// the room from the center to the first item at the right. A window
    /// with too little room has the narrowest field, as near the center as
    /// the items allow, and each item keeps its label.
    private func centeredWidth(_ search: SearchState) -> CGFloat {
        let widest: CGFloat = 340, narrowest: CGFloat = 180
        guard search.rightItemsX > 0, let w = workspace.canvas.window?.frame.width else { return widest }
        return min(widest, max(narrowest, 2 * (search.rightItemsX - w / 2 - 10)))
    }

    var body: some View {
        let search = workspace.search
        if search.docked {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings and actions", text: Bindable(search).query)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .frame(maxWidth: .infinity)
                    .focused($focused)
                    .onSubmit { search.runSelected(workspace) }
                    .onKeyPress(.downArrow) { search.move(1, workspace) }
                    .onKeyPress(.upArrow) { search.move(-1, workspace) }
                    .onKeyPress(.escape) {
                        workspace.closeSearch()
                        return .handled
                    }
                // The undock button shows only while the pointer is on the
                // field or the search is open, so the field stays plain. It
                // keeps its place, so the width of the field does not change.
                Button {
                    search.docked = false
                    search.show()
                } label: {
                    CardGlyph().foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Undock the search: a card over the view that you can move and size")
                .opacity(hovering || search.open ? 1 : 0)
                .allowsHitTesting(hovering || search.open)
                // The key of the search while it is closed; × closes the
                // results that show. One slot, so the text does not shift.
                Group {
                    if search.open {
                        Button { workspace.closeSearch() } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Close the search (Esc)")
                    } else {
                        Text("/")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .help("Press / to search")
                    }
                }
                .frame(width: 14)
            }
            .modifier(SearchFieldShape(open: search.open))
            .frame(width: centeredWidth(search))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help("Search the settings and the actions (/ or ⌘F)")
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { search.fieldMinX = $0 }
            .onChange(of: focused) { if focused { search.open = true } }
            .onChange(of: search.focusTick) { focused = true }
            .onAppear { if search.open { focused = true } }
        } else {
            Button { search.open.toggle() } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search the settings and the actions (/ or ⌘F)")
        }
    }
}

/// The one shape of the search field. From macOS 26 the toolbar puts a
/// glass capsule behind each item, so the field uses that kind of capsule
/// and its toolbar item hides the shared one (SearchToolbarContent). An
/// open search shows as one accent line on the shape.
private struct SearchFieldShape: ViewModifier {
    let open: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular, in: Capsule())
                .overlay {
                    if open { Capsule().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5) }
                }
        } else {
            content
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(open ? 0.02 : 0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(open ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: open ? 1.5 : 1)
                )
        }
    }
}

/// The search in the center of the toolbar, with no shared glass behind it.
struct SearchToolbarContent: ToolbarContent {
    let workspace: Workspace

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { SearchToolbarItem(workspace: workspace) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { SearchToolbarItem(workspace: workspace) }
        }
    }
}

/// The results of the search: under the field of the toolbar (docked), or
/// a card with its own field (undocked).
struct SearchOverlay: View {
    let workspace: Workspace
    /// The area of the layer of the cards, for the place of the card.
    var area: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var size = CGSize(width: 400, height: 300)
    static let width: CGFloat = 400
    @FocusState private var fieldFocus: Bool

    private var search: SearchState { workspace.search }

    /// The width of a rail, and the room above and below it.
    static let railWidth: CGFloat = 330

    var body: some View {
        if search.docked {
            card
        } else if !search.rail.isEmpty {
            // A rail: beside the tool strip, or beside the layer slider, from
            // under the toolbar down to the bottom bar.
            let h = max(200, area.height - 60 - workspace.dockHeight - 12)
            card
                .frame(height: h, alignment: .top)
                .position(x: search.rail == "left" ? 72 + Self.railWidth / 2 : area.width - 92 - Self.railWidth / 2,
                          y: 60 + h / 2)
        } else {
            // A card over the view, at its place (the parent gives the area).
            card
                .position(cardCenter(in: area))
                .offset(drag)
        }
    }

    private var card: some View {
        let found = search.settings(workspace)
        let acts = search.actions(workspace)
        return VStack(alignment: .leading, spacing: 0) {
            header
            if !search.docked {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings and actions", text: Bindable(search).query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocus)
                        .onSubmit { search.runSelected(workspace) }
                        .onKeyPress(.downArrow) { search.move(1, workspace) }
                        .onKeyPress(.upArrow) { search.move(-1, workspace) }
                        .onKeyPress(.escape) { workspace.closeSearch(); return .handled }
                }
                .padding(10)
            }
            if search.query.isEmpty {
                Divider()
                Text("Type a setting (infill, walls, brim, speed) or an action (export, arrange, print).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            } else {
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
                                .background(i == search.index ? Color.accentColor.opacity(0.15) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(Array(found.enumerated()), id: \.element.id) { i, info in
                            SearchRow(workspace: workspace, info: info, selected: acts.count + i == search.index, editing: Bindable(search).editing,
                                      stacked: !search.rail.isEmpty) {
                                // Back to the field of the search.
                                if search.docked { workspace.focusSearchField() } else { fieldFocus = true }
                            }
                        }
                        if found.isEmpty && acts.isEmpty {
                            Text("No setting or action matches.")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                }
                .frame(maxHeight: search.rail.isEmpty ? resultsHeight : .infinity)
            }
            if !search.rail.isEmpty { Spacer(minLength: 0) }
        }
        .frame(width: cardWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .modifier(CardGrip(on: !search.docked && search.rail.isEmpty, size: size))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onAppear {
            if !search.docked { fieldFocus = true }
            if let t = ProcessInfo.processInfo.environment["ZSLICE_SEARCH"], search.query.isEmpty { search.query = t }
        }
        .onChange(of: search.focusTick) { if !search.docked { fieldFocus = true } }
    }

    /// The kept width of the card; the results under the toolbar have the
    /// plain width.
    /// The width of the results under the field of the toolbar, as on
    /// the web, within the window.
    static let dockedWidth: CGFloat = 640

    private var cardWidth: CGFloat {
        if search.docked { return min(Self.dockedWidth, max(300, area.width - 16)) }
        if !search.docked, !search.rail.isEmpty { return Self.railWidth }
        guard !search.docked, let s = SpatialStore.shared.size("search") else { return Self.width }
        return max(s.width, 300)
    }

    /// The room of the results: the kept height of the card, else 420,
    /// and never past the bottom bar (the field and the head take about
    /// 90 points of a card, the head 30 of the results under the toolbar).
    private var resultsHeight: CGFloat {
        var h: CGFloat = 420
        if !search.docked, let s = SpatialStore.shared.size("search"), s.height > 0 { h = max(120, s.height - 90) }
        guard area.height > 0 else { return h }
        return max(120, min(h, area.height - workspace.dockHeight - 24 - (search.docked ? 36 : 150)))
    }

    /// The center of the card: the place that the user gave it, else under
    /// the toolbar in the middle.
    func cardCenter(in area: CGSize) -> CGPoint {
        let s = CGSize(width: cardWidth, height: size.height)
        if let c = SpatialStore.shared.center("search", size: s, area: area, bottom: workspace.dockHeight, avoiding: nil) { return c }
        return CGPoint(x: area.width / 2, y: 60 + s.height / 2)
    }

    private var header: some View {
        HStack {
            Text("Search").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            // The other places of the search.
            ForEach([("toolbar", "dock.arrow.up.rectangle", "Dock the search in the toolbar"),
                     ("card", "rectangle.on.rectangle", "A card over the view that you can move and size"),
                     ("left", "sidebar.left", "Pin the search to the left of the view"),
                     ("right", "sidebar.right", "Pin the search to the right of the view")].filter { $0.0 != search.placeName && !(search.docked && $0.0 == "toolbar") }, id: \.0) { p in
                Button { search.place(p.0) } label: {
                    if p.0 == "card" {
                        CardGlyph().foregroundStyle(.secondary)
                    } else {
                        Image(systemName: p.1).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .help(p.2)
            }
            Button {
                workspace.closeSearch()
            } label: {
                CloseMark()
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, search.docked ? 4 : 0)
        .contentShape(Rectangle())
        .help(search.docked ? "" : "Drag to move the search; zslice keeps its place. A double click puts it back.")
        .gesture(search.docked || !search.rail.isEmpty ? nil : DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { g in
                let c = cardCenter(in: area)
                SpatialStore.shared.moved("search", center: CGPoint(x: c.x + g.translation.width, y: c.y + g.translation.height),
                                          size: CGSize(width: cardWidth, height: size.height))
                drag = .zero
            })
        .onTapGesture(count: 2) { if !search.docked { SpatialStore.shared.forget("search") } }
    }
}

/// The grip of the card of the search, only while it is undocked.
private struct CardGrip: ViewModifier {
    let on: Bool
    let size: CGSize
    func body(content: Content) -> some View {
        if on { content.spatialGrip("search", size: size) } else { content }
    }
}

/// One setting of the search: its label, its source, the eye, and its
/// live editor (with a slider for a number).
private struct SearchRow: View {
    let workspace: Workspace
    let info: SettingInfo
    let selected: Bool
    @Binding var editing: String?
    /// In a rail: the name on its own line, over the controls.
    var stacked = false
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
                if !stacked {
                    SettingEditor(model: model, info: info, entry: entry, compact: true, focusRequest: $editing, onDone: back)
                }
            }
            if stacked {
                HStack {
                    Spacer(minLength: 26)
                    SettingEditor(model: model, info: info, entry: entry, compact: true, focusRequest: $editing, onDone: back)
                }
            }
            if info.hasSlider {
                QuickSlider(model: model, info: info, entry: entry)
                    .padding(.leading, 26)
            }
        }
        .environment(\.searchColumns, !stacked)
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
