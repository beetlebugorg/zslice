//! The settings drawer: a native inspector at the right of the window
//! (docs/internals/one-view.md, "the drawer"; linux/src/ui/settings-browser.c
//! and web/app/settings.js). N in the view, or View > Show Settings,
//! shows it and hides it, and the app keeps the choice.
//!
//! It has three levels, as the browsers of the other apps:
//! 1. the sections of each group (Part, Filament, Printer, Engine), and a
//!    search field that finds settings by name or help text;
//! 2. the settings of a section, each with an editor;
//! 3. the page of one setting: its editor and slider, its formula, where
//!    its value comes from (with Reset), what it does, and the lines of the
//!    print that it changes, with their share of the print time.
//!
//! The 3D view shows the lines that the setting or the section changes in
//! their feature colors, and the other lines fade (zs_view_focus). A hidden
//! drawer shows the whole print.
//!
//! A change goes to the core at once: a switch or a choice on a click, a
//! number after a pause in the typing (450 ms), on Return, or with the up
//! and down arrow keys. The plate then slices again.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

/// A page of the drawer.
enum SettingsRoute: Hashable {
    case section(group: String, section: String)
    case feature(Int)
    case setting(String)
    /// All settings that change the selected line, by section.
    case line
}

struct SettingsInspector: View {
    let workspace: Workspace
    private var path: [SettingsRoute] { workspace.settingsPath }
    @State private var search = ""

    private var model: SliceModel { workspace.model }

    /// The drawer has its own search field and its own header with a back
    /// button: a navigation stack in an inspector shows neither.
    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $search, prompt: "Search settings")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            if !searching, let last = path.last {
                HStack(spacing: 6) {
                    Button {
                        workspace.settingsPath.removeLast()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back (⌘[)")
                    Text(title(of: last)).font(.headline).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                Divider()
            }
            Group {
                if searching {
                    SettingsList(workspace: workspace, title: "Search", withSection: true, settings: matches)
                } else if let last = path.last {
                    page(last)
                } else {
                    sections
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: path, initial: true) { sendFocus() }
        .onChange(of: search) { if searching { workspace.settingsPath = [] } }
        .onDisappear { workspace.focus(0, firstLayer: false) }
        .onAppear {
            // For development and screenshots: ZSLICE_SETTING=name opens the
            // page of that setting.
            if let name = ProcessInfo.processInfo.environment["ZSLICE_SETTING"], let info = SettingInfo.byName[name], path.isEmpty {
                workspace.settingsPath = [.section(group: info.group, section: info.section), .setting(name)]
            }
        }
    }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    @ViewBuilder private func page(_ route: SettingsRoute) -> some View {
        switch route {
        case let .section(group, section):
            SettingsList(workspace: workspace, title: section.isEmpty ? "General" : section, withSection: false,
                         settings: SettingInfo.all.filter { $0.group == group && $0.section == section })
        case let .feature(f):
            SettingsList(workspace: workspace, title: Feature.titles[f], withSection: true,
                         settings: SettingInfo.all.filter {
                             let e = SettingEffect($0.name).features
                             return (e >> f) & 1 != 0 && e & Feature.all != Feature.all
                         })
        case .line:
            LineSettings(workspace: workspace)
        case let .setting(name):
            if let info = SettingInfo.byName[name] {
                SettingDetail(workspace: workspace, info: info)
            }
        }
    }

    private func title(of route: SettingsRoute) -> String {
        switch route {
        case let .section(g, s): "\(SettingInfo.groupTitle(g)) › \(s.isEmpty ? "General" : s)"
        case let .feature(f): Feature.titles[f]
        case .line: "Selected Line"
        case let .setting(name): SettingInfo.byName[name]?.label ?? name
        }
    }

    private var matches: [SettingInfo] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return SettingInfo.all.filter {
            $0.label.lowercased().contains(needle) || $0.doc.lowercased().contains(needle) || $0.name.contains(needle)
        }
    }

    private var sections: some View {
        List {
            ForEach(SettingInfo.groups, id: \.key) { g in
                let names = sectionNames(g.key)
                if !names.isEmpty {
                    Section(g.title) {
                        ForEach(names, id: \.self) { s in
                            RouteRow(workspace: workspace, route: .section(group: g.key, section: s)) {
                                Text(s.isEmpty ? "General" : s)
                            }
                            .onHover { inside in
                                if inside { workspace.focus(sectionFocus(g.key, s), firstLayer: false) } else { sendFocus() }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func sectionNames(_ group: String) -> [String] {
        var seen = Set<String>()
        return SettingInfo.all.filter { $0.group == group }.compactMap { seen.insert($0.section).inserted ? $0.section : nil }
    }

    private func sectionFocus(_ group: String, _ section: String) -> UInt32 {
        let mask = SettingInfo.all.filter { $0.group == group && $0.section == section }
            .reduce(UInt32(0)) { $0 | SettingEffect($1.name).features }
        return mask != 0 ? mask : Feature.all
    }

    /// The focus of the view: the lines that the page changes.
    private func sendFocus() {
        switch path.last {
        case let .setting(name)?:
            let e = SettingEffect(name)
            workspace.focus(e.features != 0 ? e.features : Feature.all, firstLayer: e.firstLayerOnly)
        case let .feature(f)?:
            workspace.focus(1 << UInt32(f), firstLayer: false)
        case let .section(g, s)?:
            workspace.focus(sectionFocus(g, s), firstLayer: false)
        case .line?, nil:
            workspace.focus(0, firstLayer: false)
        }
    }
}

/// All settings that change the selected line (zs_inspect.settings): a
/// line "# Speed" starts a section.
struct LineSettings: View {
    let workspace: Workspace

    var body: some View {
        let info = workspace.lineInfo
        List {
            if let info {
                Text("\(info.title) · layer \(info.layer + 1)").font(.headline)
                ForEach(sections(info.settings), id: \.title) { sec in
                    Section(sec.title) {
                        ForEach(sec.names.compactMap { SettingInfo.byName[$0] }) { s in
                            SettingRow(workspace: workspace, info: s, withSection: false)
                        }
                    }
                }
            } else {
                Text("Click a line in the view to see the settings that change it.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Selected Line")
    }

    private func sections(_ lines: [String]) -> [(title: String, names: [String])] {
        var out: [(title: String, names: [String])] = []
        for l in lines {
            if l.hasPrefix("# ") {
                out.append((String(l.dropFirst(2)), []))
            } else {
                if out.isEmpty { out.append(("Settings", [])) }
                out[out.count - 1].names.append(l)
            }
        }
        return out.filter { !$0.names.isEmpty }
    }
}

/// A row that opens a page of the drawer, with a chevron.
struct RouteRow<Label: View>: View {
    let workspace: Workspace
    let route: SettingsRoute
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            workspace.settingsPath.append(route)
        } label: {
            HStack {
                label()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A search field in the style of AppKit (NSSearchField).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

/// The settings of a section, of a search, or of a feature.
struct SettingsList: View {
    let workspace: Workspace
    let title: String
    let withSection: Bool
    let settings: [SettingInfo]

    var body: some View {
        List {
            if settings.isEmpty {
                Text("No setting matches.").foregroundStyle(.secondary)
            }
            ForEach(settings) { info in
                SettingRow(workspace: workspace, info: info, withSection: withSection)
            }
        }
        .navigationTitle(title)
    }
}

struct SettingRow: View {
    let workspace: Workspace
    let info: SettingInfo
    let withSection: Bool

    var body: some View {
        let entry = workspace.model.entry(info.name)
        // The label opens the page of the setting; the editor stays live.
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.label)
                let tag = tagText(entry)
                if !tag.isEmpty {
                    Text(tag)
                        .font(.caption)
                        .foregroundStyle(entry.isMine ? Color.accentColor : .secondary)
                }
            }
            .help(info.doc)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { workspace.settingsPath.append(.setting(info.name)) }
            SettingEditor(model: workspace.model, info: info, entry: entry, compact: true)
            Button {
                workspace.settingsPath.append(.setting(info.name))
            } label: {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Open the page of \(info.label)")
        }
        .onHover { inside in
            let e = SettingEffect(info.name)
            if inside { workspace.focus(e.features != 0 ? e.features : Feature.all, firstLayer: e.firstLayerOnly) }
        }
    }

    private func tagText(_ entry: SettingEntry) -> String {
        let t = entry.sourceText
        guard withSection else { return t }
        return "\(SettingInfo.groupTitle(info.group)) · \(info.section)" + (t.isEmpty ? "" : " · \(t)")
    }
}

/// The editor of a setting: a switch, a menu of choices, or a field with
/// its unit.
struct SettingEditor: View {
    let model: SliceModel
    let info: SettingInfo
    let entry: SettingEntry
    var compact = false

    var body: some View {
        switch info.kind {
        case .boolean:
            Toggle(info.label, isOn: Binding(get: { entry.value == "true" }, set: { model.set(info.name, $0 ? "true" : "false") }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        case .choice:
            Picker(info.label, selection: Binding(get: { entry.value }, set: { model.set(info.name, $0) })) {
                ForEach(info.choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .text where info.multiline && compact:
            Text(ValueText.display(info, entry.value))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .trailing)
        case .text where info.multiline:
            MultilineEditor(model: model, info: info, entry: entry)
        default:
            ValueField(model: model, info: info, entry: entry)
        }
    }
}

/// A field for a number or a line of text, with the unit after it.
struct ValueField: View {
    let model: SliceModel
    let info: SettingInfo
    let entry: SettingEntry
    @State private var text = ""
    @State private var error: String?
    @State private var typing: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(info.label, text: $text)
                .labelsHidden()
                .multilineTextAlignment(info.isNumber ? .trailing : .leading)
                .frame(width: info.isNumber ? 72 : 150)
                .focused($focused)
                .foregroundStyle(error != nil ? Color.red : (unusual ? Color.orange : Color.primary))
                .help(error ?? (unusual ? "\(info.doc)\n\nThe value is out of the usual range." : info.doc))
                .onSubmit { send() }
                .onKeyPress(.upArrow) { stepBy(1) }
                .onKeyPress(.downArrow) { stepBy(-1) }
                .onKeyPress(.escape) {
                    text = ValueText.display(info, entry.value)
                    focused = false
                    return .handled
                }
                .onChange(of: text) {
                    // Live: a number goes to the core after a pause in the typing.
                    typing?.cancel()
                    guard focused, info.isNumber, ValueText.parsesAsNumber(text) else { return }
                    typing = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        if !Task.isCancelled { send() }
                    }
                }
                .onChange(of: focused) {
                    if !focused { send() }
                    // An edit of one setting is one step of the history
                    // while its editor has the focus.
                    model.history.setFocus(focused ? info.name : nil)
                }
            if !info.unit.isEmpty {
                Text(info.unit).foregroundStyle(.secondary).font(.callout)
            }
        }
        .onAppear { text = ValueText.display(info, entry.value) }
        .onChange(of: entry) {
            if !focused {
                text = ValueText.display(info, entry.value)
                error = nil
            }
        }
    }

    /// A value out of the usual range is valid, but unusual.
    private var unusual: Bool {
        guard info.hasSlider, let v = Double(entry.value) else { return false }
        return v < info.sliderMin - 1e-9 || v > info.sliderMax + 1e-9
    }

    private func send() {
        typing?.cancel()
        let v = ValueText.toCore(info, text)
        if v == entry.value { return }
        error = model.set(info.name, v)
    }

    private func stepBy(_ dir: Double) -> KeyPress.Result {
        guard info.isNumber, let v = Double(text) else { return .ignored }
        let k = info.isRatio ? 100.0 : 1
        text = ValueText.number(v + dir * info.step * k)
        send()
        return .handled
    }
}

/// A text of more than one line (the start and end G-code).
struct MultilineEditor: View {
    let model: SliceModel
    let info: SettingInfo
    let entry: SettingEntry
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(minHeight: 140)
            .focused($focused)
            .onAppear { text = entry.value }
            .onChange(of: focused) {
                if !focused && text != entry.value { model.set(info.name, text) }
                model.history.setFocus(focused ? info.name : nil)
            }
            .onChange(of: entry) { if !focused { text = entry.value } }
    }
}

/// The page of one setting.
struct SettingDetail: View {
    let workspace: Workspace
    let info: SettingInfo
    @State private var formula = ""
    @State private var formulaError = false
    @State private var throttle = Throttle()

    private var model: SliceModel { workspace.model }

    var body: some View {
        let entry = model.entry(info.name)
        Form {
            Section {
                LabeledContent(info.label) {
                    SettingEditor(model: model, info: info, entry: entry)
                }
                if info.hasSlider, let v = Double(entry.value) {
                    let k = info.isRatio ? 100.0 : 1
                    // Continuous, with the value rounded to the step: a
                    // slider with a step draws a tick for each step.
                    Slider(value: Binding(get: { v * k }, set: { slide(($0 / k / info.step).rounded() * info.step) }),
                           in: info.sliderMin * k ... info.sliderMax * k)
                        .labelsHidden()
                }
                if info.isNumber {
                    LabeledContent("Formula") {
                        TextField("Formula", text: $formula, prompt: Text("= {line_width} * 2"))
                            .labelsHidden()
                            .foregroundStyle(formulaError ? Color.red : Color.primary)
                            .help("A formula of other settings, for example {line_width} * 2. Empty: a plain value.")
                            .onSubmit { setFormula(entry) }
                    }
                }
                HStack {
                    Text(sourceLine(entry)).foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    if entry.isMine {
                        Button("Reset") { model.reset(info.name) }
                    }
                }
            } header: {
                Text("\(SettingInfo.groupTitle(info.group)) › \(info.section.isEmpty ? "General" : info.section)")
            }
            Section("What it does") {
                Text(info.doc).textSelection(.enabled)
            }
            Section("In your project") {
                EffectList(workspace: workspace, info: info)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(info.label)
        .onAppear { formula = entry.formula.map { "= \($0)" } ?? "" }
        .onChange(of: entry) { formula = entry.formula.map { "= \($0)" } ?? "" }
    }

    private func slide(_ v: Double) {
        let text = ValueText.number(v)
        throttle.run { model.set(info.name, text) }
    }

    private func setFormula(_ entry: SettingEntry) {
        let t = formula.trimmingCharacters(in: .whitespaces)
        let v = t.isEmpty ? entry.value : (t.hasPrefix("=") ? t : "= \(t)")
        formulaError = model.set(info.name, v) != nil
    }

    private func sourceLine(_ entry: SettingEntry) -> String {
        let def = ValueText.withUnit(info, info.defaultValue)
        if entry.level == 5 {
            let q = coreText(zs_app_quality_name(model.core))
            return "Changed for this print. Reset gives \(ValueText.withUnit(info, entry.base)) (from \(q.isEmpty ? "the default" : q))."
        }
        let src = entry.sourceText
        return src.isEmpty ? "The default (\(def))" : "From \(src). Default: \(def)"
    }
}

/// What a setting changes: the lines of each feature, with their time.
struct EffectList: View {
    let workspace: Workspace
    let info: SettingInfo

    var body: some View {
        let e = SettingEffect(info.name)
        if e.features == 0 {
            Text("\(e.note.isEmpty ? "It changes no line." : e.note) The view shows all lines, in their feature colors.")
                .foregroundStyle(.secondary)
        } else {
            let stats = workspace.model.state == .done ? workspace.model.featureStats() : nil
            let total = stats?.reduce(0) { $0 + $1.time_s } ?? 0
            let shown = (0 ..< Feature.titles.count).filter { f in
                (e.features >> UInt32(f)) & 1 != 0 && !(f < Feature.count && stats.map { $0[f].paths == 0 } == true)
            }
            Text(e.firstLayerOnly ? "It changes these lines on the first layer:" : "It changes these lines:")
            if shown.isEmpty {
                Text("This part has none of these lines now.").foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.self) { f in
                RouteRow(workspace: workspace, route: .feature(f)) {
                    HStack {
                        Circle().fill(Feature.colors[f]).frame(width: 9, height: 9)
                        Text(Feature.titles[f])
                        Spacer()
                        if f < Feature.count, let stats, total > 0, !e.firstLayerOnly {
                            Text("\(Int((stats[f].time_s / 60).rounded())) min · \(Int((100 * stats[f].time_s / total).rounded())) %")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .help("Show all settings that change the \(Feature.titles[f]) lines")
            }
        }
    }
}
