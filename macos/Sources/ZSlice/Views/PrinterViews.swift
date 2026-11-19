//! The printer views: the picker of the library (docs/user/
//! getting-started.md, "Add your printer"), the printer menu of the
//! toolbar, and the Printers page of the Settings window.
//!
//! The picker: a search field (search as you type), the brands at the
//! left (Popular first, zs_printers_popular, then All Brands and each brand),
//! the models in the middle, and the card of the selected model at
//! the right (its facts, its sources, the nozzle). Below the card: the
//! name and the connection. "Add Printer" makes it a printer of the user
//! and the printer of the plate. "My printer is not in the list" adds the
//! generic printer.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import SwiftUI

struct PrinterPicker: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// -2: the popular printers (at first), -1: all brands.
    @State private var brand = -2
    @State private var selected: Int?
    @State private var name = ""
    @State private var nozzle = 0.0
    @State private var kind = Printer.Kind.none
    @State private var url = ""
    @State private var key = ""
    @State private var serial = ""
    @State private var discovery = Discovery()
    @State private var network: FoundPrinter?
    /// The model that useFound picked from the name of a found printer.
    @State private var guessed: Int?

    private let lib = PrinterLibrary.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add a Printer").font(.title2.weight(.semibold))
                Spacer()
                SearchField(text: $query, prompt: "Search: ender 3, mk4, k1 max, voron 2.4")
                    .frame(width: 320)
            }
            .padding()
            Divider()
            HSplitView {
                List(selection: Binding(get: { brand }, set: { brand = $0 ?? -1 })) {
                    Text("Popular (\(lib.popular.count))").tag(-2)
                    Text("All Brands").tag(-1)
                    ForEach(Array(lib.brands.enumerated()), id: \.offset) { i, b in
                        Text(b.name).tag(i)
                    }
                }
                .frame(minWidth: 160, maxWidth: 220)
                List(selection: $selected) {
                    if query.isEmpty && brand < 0 {
                        Section {
                            if discovery.offered.isEmpty {
                                Text(discovery.searching ? "Searching…" : "No printer answered.").foregroundStyle(.secondary)
                            }
                            ForEach(discovery.offered) { f in
                                Button { useFound(f) } label: {
                                    HStack {
                                        if let c = Color(hex: f.color) {
                                            Circle().fill(c).frame(width: 10, height: 10).frame(width: 18)
                                        } else {
                                            Image(systemName: "wifi").foregroundStyle(.secondary)
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(f.name)
                                            Text("\(f.kindTitle) · \(f.url)\(f.model.isEmpty ? "" : " · \(f.model)")"
                                                 + (f.bambu ? " · type its access code below" : ""))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if network == f { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text("On Your Network")
                                if discovery.searching { ProgressView().controlSize(.mini) }
                                Spacer()
                                Button("Search Again") { discovery.start() }
                                    .buttonStyle(.link)
                                    .disabled(discovery.searching)
                            }
                        }
                    }
                    // Popular with no query: those printers; a search covers all.
                    ForEach(brand == -2 && query.isEmpty ? lib.popular : lib.search(query, brand: max(brand, -1)), id: \.self) { i in
                        if let m = lib.model(i) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(coreText(m.title))
                                Text(lib.facts(i)).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(i)
                        }
                    }
                }
                .frame(minWidth: 280)
                detail
                    .frame(minWidth: 300, maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("My Printer Is Not in the List") { addGeneric() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Printer") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((selected == nil && network == nil) || name.isEmpty)
                    .help(selected == nil && network != nil ? "Add the printer of the network with generic settings; pick its model at the left for its bed and start G-code" : "")
            }
            .padding()
        }
        .frame(width: 960, height: 620)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: selected) {
            if let i = selected, let m = lib.model(i) {
                name = coreText(m.title)
                nozzle = m.nozzle
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let i = selected, let m = lib.model(i) {
            Form {
                Section {
                    // A model of the network is a guess from the name: many
                    // printers come with several tool heads and nozzles.
                    if guessed == i {
                        Label("zslice guessed this model from the printer's name. Check that the tool head and the nozzle are yours: the slice uses this nozzle, and a wrong one leaves out thin parts or overfills them.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("Model", value: coreText(m.title))
                    LabeledContent("Facts", value: lib.facts(i))
                    LabeledContent("Firmware", value: coreText(m.firmware))
                    LabeledContent("Data from", value: lib.sources(i))
                    if !m.has_start_gcode {
                        Text("The start G-code of this printer has scripts, which zslice cannot run: it gets the start G-code of zslice. Check it before the first print.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Section("This printer") {
                    TextField("Name", text: $name)
                    let sizes = coreText(m.nozzles).split(separator: ";").compactMap { Double($0) }
                    if !sizes.isEmpty {
                        Picker("Nozzle", selection: $nozzle) {
                            ForEach(sizes, id: \.self) { Text(String(format: "%.2g mm", $0)).tag($0) }
                        }
                    }
                }
                ConnectionSection(kind: $kind, url: $url, key: $key, serial: $serial)
            }
            .formStyle(.grouped)
        } else if let f = network {
            // A printer of the network with no model of the library: it can
            // be added as it is.
            Form {
                Section("On Your Network") {
                    LabeledContent("Found", value: f.name)
                    LabeledContent("Kind", value: f.kindTitle)
                    LabeledContent("Address", value: f.url)
                    Text("zslice has no model in its library for this printer's name. Pick its model at the left for its bed, nozzle, and start G-code, or add it as it is: it gets generic settings, and Use the Printer's Bed, Nozzle, and Motion in the printer menu reads them from the printer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("This printer") {
                    TextField("Name", text: $name)
                }
                ConnectionSection(kind: $kind, url: $url, key: $key, serial: $serial)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("Choose Your Printer", systemImage: "printer")
            } description: {
                Text("Click a printer on your network, or pick your printer's model in the list: its bed, nozzle, and start G-code come from the library of more than 1000 printers.")
            }
        }
    }

    /// A printer on the network: its address and kind, and its model if
    /// the library has one that fits.
    private func useFound(_ f: FoundPrinter) {
        network = f
        kind = f.printerKind
        url = f.bambu ? f.url.replacingOccurrences(of: "ftps://", with: "") : f.url
        serial = f.serial
        let hint = f.model.isEmpty ? f.name : f.model
        if let i = lib.match(hint: hint, bedX: f.bedX, bedY: f.bedY, height: f.height) {
            selected = i
            guessed = i
        }
        if !f.name.isEmpty { name = f.name }
        // The nozzle of the printer, if its status tells it: the tool head
        // with that nozzle (printdeck, Moonraker, OctoPrint).
        guard !f.bambu else { return }
        Task { @MainActor in
            guard let st = await PrinterLink.status(Printer(name: name, kind: kind, url: url)), st.nozzle > 0,
                  network == f, let i = lib.match(hint: hint, bedX: f.bedX, bedY: f.bedY, height: f.height, nozzle: st.nozzle) else { return }
            selected = i
            guessed = i
            nozzle = st.nozzle
        }
    }

    private func add() {
        // A printer of the network with no model: generic settings.
        if selected == nil, network != nil {
            var p = Printer(name: name, kind: kind, url: url)
            p.serial = serial
            if !key.isEmpty { p.apiKey = key }
            finish(p)
            return
        }
        guard let i = selected, let m = lib.model(i), let profile = lib.profile(i, nozzle: nozzle) else { return }
        var p = Printer(name: name, model: coreText(m.id), machine: profile, kind: kind, url: url)
        p.serial = serial
        if !key.isEmpty { p.apiKey = key }
        p.machine = profile
        finish(p)
    }

    private func addGeneric() {
        finish(Printer(name: "My Printer"))
    }

    private func finish(_ p: Printer) {
        PrinterStore.shared.add(p)
        workspace.usePrinter(p)
        dismiss()
        // A printdeck: its https address, so the key never travels in clear text.
        if p.kind == .printdeck {
            Task { @MainActor in
                if let https = await PrinterLink.printdeckHTTPS(p) {
                    var q = p
                    q.https = https
                    PrinterStore.shared.update(q)
                }
            }
        }
    }
}

/// The connection of a printer: its kind, its address, and its API key,
/// with Test and Get a Key.
struct ConnectionSection: View {
    @Binding var kind: Printer.Kind
    @Binding var url: String
    @Binding var key: String
    @Binding var serial: String
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        Section("Connection") {
            Picker("Send prints to", selection: $kind) {
                ForEach(Printer.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if kind == .bambu {
                Text("Bambu Lab support is untested with a real printer. Turn on LAN mode on the printer: its screen shows the access code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Address", text: $url, prompt: Text("192.168.1.42"))
                TextField("Serial number", text: $serial, prompt: Text("01P00A123456789"))
                SecureField("Access code", text: $key)
                let host = BambuLink.host(probe)
                if let pin = BambuPins.pin(for: host) {
                    LabeledContent("Trusted certificate") {
                        HStack {
                            Text(pin.prefix(23) + "…").font(.caption.monospaced()).textSelection(.enabled)
                            Button("Forget") { BambuPins.set(nil, for: host) }
                                .help("The next connection trusts the certificate of the printer again (after a reset of the printer, for example)")
                        }
                    }
                }
            } else if kind != .none {
                TextField("Address", text: $url, prompt: Text("http://printer.local"))
                if kind != .moonraker {
                    SecureField("API key", text: $key)
                }
                HStack {
                    Button("Test the Connection") { run { await PrinterLink.test(probe) } }
                    if kind != .moonraker && kind != .bambu {
                        Button("Get a Key") {
                            run {
                                let id = Signer.keyID
                                let r = await PrinterLink.requestKey(probe) { s in
                                    result = "Allow zslice on the printer (\(s) s)…" + (id.isEmpty ? "" : " The deck shows the key \(id): check that it is the same.")
                                }
                                if let k = r.key { key = k }
                                return r
                            }
                        }
                        .help("The printer asks \"Allow zslice?\" on its screen (printdeck) or in its web page (OctoPrint). Allow it within 2 minutes.")
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .disabled(busy || url.isEmpty)
                if let result {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A printer with this connection, for a test.
    private var probe: Printer {
        var p = Printer(name: "test", kind: kind, url: url)
        p.serial = serial
        p.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return p
    }

    private func run(_ op: @escaping @MainActor () async -> LinkResult) {
        busy = true
        result = nil
        Task { @MainActor in
            // The test sends the key of the field.
            Keychain.write(key, account: probe.id.uuidString)
            let r = await op()
            Keychain.write("", account: probe.id.uuidString)
            result = r.message
            busy = false
        }
    }
}

/// The printer menu of the toolbar: the printers of the user, Add a
/// Printer, and Manage Printers.
struct PrinterMenu: View {
    let workspace: Workspace
    private var store: PrinterStore { PrinterStore.shared }

    var body: some View {
        Menu {
            ForEach(store.printers) { p in
                Toggle(p.name, isOn: Binding(get: { store.currentID == p.id }, set: { _ in workspace.usePrinter(p) }))
            }
            if !store.printers.isEmpty { Divider() }
            if workspace.connectedPrinter != nil {
                Button("Use the Printer's Bed, Nozzle, and Motion") { workspace.applyPrinterStatus(1) }
                    .help("The bed, the nozzle, and the motion limits that the printer reports, so the time estimate plans as it moves")
                Button("Use the Filament in the Printer") { workspace.applyPrinterStatus(2) }
                    .help("The material, the name, the diameter, and the color of the filament that the printer reports")
                Divider()
            }
            Button("Add a Printer…") { workspace.pickerOpen = true }
            SettingsLink { Text("Manage Printers…") }
        } label: {
            // ZSLICE_PRINTER_LABEL=text: the label, for tests of the toolbar.
            Label(ProcessInfo.processInfo.environment["ZSLICE_PRINTER_LABEL"] ?? store.current?.name ?? "No Printer", systemImage: "printer")
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .help("The printer of this plate")
    }
}

/// The Printers page of the Settings window: each printer, its name, and
/// its connection.
struct PrintersSettings: View {
    @State private var selected: UUID?
    private var store: PrinterStore { PrinterStore.shared }

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(store.printers) { p in
                    Label(p.name, systemImage: "printer").tag(p.id)
                }
            }
            .frame(minWidth: 180, maxWidth: 240)
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Remove", role: .destructive) { ids.forEach { store.remove($0) } }
            }
            if let id = selected, let p = store.printers.first(where: { $0.id == id }) {
                PrinterEditor(printer: p).id(id)
            } else {
                ContentUnavailableView("No Printer Selected", systemImage: "printer",
                                       description: Text("Add a printer with the printer menu of a window."))
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { selected = store.currentID }
    }
}

private struct PrinterEditor: View {
    @State var printer: Printer
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $printer.name)
                LabeledContent("Model", value: PrinterLibrary.shared.find(id: printer.model).flatMap { PrinterLibrary.shared.model($0) }.map { coreText($0.title) } ?? "Generic")
                if !printer.https.isEmpty {
                    LabeledContent("Secure address", value: printer.https)
                }
            }
            ConnectionSection(kind: $printer.kind, url: $printer.url, key: $key, serial: $printer.serial)
            HStack {
                Spacer()
                Button("Remove Printer", role: .destructive) { PrinterStore.shared.remove(printer.id) }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = printer.apiKey }
        .onChange(of: printer) { PrinterStore.shared.update(printer) }
        .onChange(of: key) { printer.apiKey = key }
    }
}

/// The Filament menu of the toolbar: the built-in materials and the
/// filaments of the user, and Save as Profile.
struct FilamentMenu: View {
    let workspace: Workspace

    var body: some View {
        let model = workspace.model
        let now = model.materialName
        Menu {
            Section("Material") {
                ForEach(Profiles.builtin(Profiles.filament).filter { $0.hasPrefix("generic-") }, id: \.self) { n in
                    let mat = String(n.dropFirst(8)).uppercased()
                    Toggle(mat, isOn: Binding(get: { now == mat }, set: { _ in model.useFilament(name: n) }))
                }
            }
            let mine = Profiles.mine(Profiles.filament)
            if !mine.isEmpty {
                Section("My Filaments") {
                    ForEach(mine, id: \.self) { n in
                        Button(n) { model.useFilament(name: n, text: Profiles.text(of: n, group: Profiles.filament)) }
                    }
                }
            }
            Divider()
            Button("Save as Profile…") {
                if let name = askProfileName("Save the Filament as a Profile") { try? model.saveProfile(group: Profiles.filament, name: name) }
            }
        } label: {
            Label(now.isEmpty ? "Filament" : now, systemImage: "circle.dashed")
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .help("The filament of the plate: its material, or a filament profile of yours")
    }
}

/// The Quality menu of the toolbar: the built-in qualities and the
/// qualities of the user, and Save as Profile. A dot: this print has
/// changes on top of the quality.
struct QualityMenu: View {
    let workspace: Workspace

    var body: some View {
        let model = workspace.model
        let q = model.qualityName
        let changed = !(coreString({ zs_app_state_write(model.core, Profiles.quality, $0, $1, $2) }) ?? "")
            .split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("extends") }.isEmpty
        Menu {
            Section("Built-in") {
                ForEach(Profiles.builtin(Profiles.quality), id: \.self) { n in
                    Toggle(n, isOn: Binding(get: { q == n }, set: { _ in model.useQuality(name: n) }))
                }
            }
            let mine = Profiles.mine(Profiles.quality)
            if !mine.isEmpty {
                Section("My Qualities") {
                    ForEach(mine, id: \.self) { n in
                        Toggle(n, isOn: Binding(get: { q == n }, set: { _ in model.useQuality(name: n, text: Profiles.text(of: n, group: Profiles.quality)) }))
                    }
                }
            }
            Divider()
            Button("Save as Profile…") {
                if let name = askProfileName("Save the Quality as a Profile") { try? model.saveProfile(group: Profiles.quality, name: name) }
            }
        } label: {
            Label((q.isEmpty ? "Quality" : q) + (changed ? " •" : ""), systemImage: "dial.medium")
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .help("The quality of the plate. A dot: this print has changes on top of it. A pick of another quality keeps your changes.")
    }
}

extension Color {
    /// "#rrggbb", or nil.
    init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
