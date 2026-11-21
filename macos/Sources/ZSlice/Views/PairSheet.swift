//! The key of a printdeck or an OctoPrint printer in one step
//! (linux/src/ui/pair-dialog.c, web/app/app.js).
//!
//! The sheet starts the App Keys flow at once (PrinterLink.requestKey):
//! the printer asks "Allow zslice?" on its touch screen (printdeck) or in
//! its web page (OctoPrint). The sheet says so, with the key id of the
//! signatures for a deck, counts down the 2 minutes, and has Cancel. After
//! Allow, the key goes to the printer (the Keychain). A printdeck that
//! drives more than one printer lists them (/slicer/printer.json): the
//! user picks the ones to add, and each one gets the key of the deck, the
//! machine settings of the deck, and the path of its API under the deck.
//! After Deny or the time-out, the sheet says why and offers Try Again.
//!
//! The picker opens it after it adds such a printer with no key, and the
//! card of the Printers page opens it from Get a Key.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct PairSheet: View {
    let workspace: Workspace
    let printerID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var count = ""
    @State private var failed = false
    @State private var connected = false
    @State private var deck: [DeckPrinter] = []
    @State private var picked: Set<String> = []
    @State private var task: Task<Void, Never>?
    @State private var deckAdded = false

    private var printer: Printer? { PrinterStore.shared.printers.first { $0.id == printerID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to \(printer?.name ?? "the Printer")").font(.headline)
            Text(text)
                .font(.title3)
                .foregroundStyle(failed ? .red : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if !count.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(count).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !deck.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(deck) { d in
                        Toggle(d.title, isOn: Binding(get: { picked.contains(d.id) },
                                                      set: { on in if on { picked.insert(d.id) } else { picked.remove(d.id) } }))
                    }
                }
                .padding(.leading, 4)
            }
            HStack {
                Spacer()
                if failed { Button("Try Again") { start() } }
                Button(connected ? "Close" : "Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                if !deck.isEmpty {
                    Button("Add") { addDeck() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(picked.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard let p = printer else { return }
        failed = false
        let deckKind = p.kind == .printdeck
        let id = Signer.keyID
        text = deckKind ? (id.isEmpty ? "Tap Allow on the screen of the printdeck."
                                      : "Tap Allow on the screen of the printdeck, and check that it shows the key \(id).")
                        : "Allow zslice in the web page of OctoPrint: it shows a request for zslice."
        count = "Waiting for Allow: 120 s left."
        task?.cancel()
        task = Task { @MainActor in
            let r = await PrinterLink.requestKey(p) { s in count = "Waiting for Allow: \(max(0, 120 - s)) s left." }
            guard !Task.isCancelled else { return }
            count = ""
            guard let key = r.key, var q = printer else {
                text = r.message
                failed = true
                return
            }
            q.apiKey = key
            PrinterStore.shared.update(q)
            connected = true
            text = "Connected to \(q.name)."
            FarmMonitor.shared.forget(q)
            NSLog("zslice pair: connected to %@", q.name)
            guard q.kind == .printdeck else { return }
            if q.https.isEmpty, let https = await PrinterLink.printdeckHTTPS(q) {
                q.https = https
                PrinterStore.shared.update(q)
            }
            // The other printers of the deck: the first one is the deck
            // itself, and zslice does not slice for resin.
            // All the printers of the deck, the one at the address of the
            // deck too (path ""); zslice does not slice for resin.
            let list = (await PrinterLink.deckPrinters(q) ?? []).filter { $0.kind != "resin" }
            let have = Set(PrinterStore.shared.printers.filter { $0.id != q.id }.map(\.name))
            // A fresh connection lists the deck alone too: its one printer.
            deck = workspace.pairingFresh || list.count > 1 ? list : []
            picked = Set(deck.filter { workspace.pairingFresh || !have.contains($0.title) }.map(\.id))
            if deck.count > 1 { text = "Connected to \(q.name). It drives \(deck.count) printers: pick the ones to add." } else if !deck.isEmpty { text = "Connected to \(q.name)." }
            NSLog("zslice pair: the deck lists %ld more printers", list.count)
            // ZSLICE_PAIR_ADD=1 (a test) presses Add.
            if ProcessInfo.processInfo.environment["ZSLICE_PAIR_ADD"] != nil, !list.isEmpty { addDeck() }
        }
    }

    /// Each picked printer of the deck: a printdeck at the root of the deck
    /// and its path, with the key of the deck, its name on the deck, and the
    /// machine profile of its model from the library (else the settings of
    /// the printer that got the key). A fresh connection drops the entry of
    /// the address, and the first printer picked is the printer now.
    private func addDeck() {
        guard let d = printer else { return }
        let base = PrinterLink.deckSplit(d.url).root
        let hbase = d.https.isEmpty ? "" : PrinterLink.deckSplit(d.https).root
        let store = PrinterStore.shared
        let current = store.currentID
        let lib = PrinterLibrary.shared
        var first: Printer?
        for item in deck where picked.contains(item.id) {
            var p = Printer(name: item.title, model: d.model, machine: d.machine, kind: .printdeck, url: base + item.path)
            // The model, then the full name, then the short label: the label
            // ("TAZ") alone matched the first TAZ, a TAZ 6, for a TAZ
            // Workhorse. A label of one word matches no model.
            let found = [item.model, item.name, item.label].lazy.filter { !$0.isEmpty }.compactMap { lib.findModel(product: $0) }.first
            if let i = found, let m = lib.model(i), let profile = lib.profile(i) {
                p.model = coreText(m.id)
                p.machine = profile
            }
            if !hbase.isEmpty { p.https = hbase + item.path }
            p.apiKey = d.apiKey
            // Its name on the deck: each send checks it (PrinterLink.checkDeckTarget).
            p.deckName = item.name
            store.add(p)
            if first == nil { first = p }
            NSLog("zslice pair: added %@ at %@, key %d, model %@", p.name, p.url, p.apiKey == d.apiKey && !p.apiKey.isEmpty ? 1 : 0, p.model)
        }
        if workspace.pairingFresh {
            // The entry of the address goes; the first printer picked is the
            // printer now.
            store.remove(d.id)
            if let first { workspace.usePrinter(first) }
        } else {
            // Adding printers keeps the printer of the plate.
            store.currentID = current
        }
        deckAdded = true
        NSLog("zslice pair: the printers now: %@; current %@", store.printers.map { "\($0.name) [\($0.deckName)]" }.joined(separator: ", "), store.current?.name ?? "-")
        Task { await FarmMonitor.shared.refresh() }
        close()
    }

    private func close() {
        task?.cancel()
        // A fresh connection that adds no printer leaves no entry.
        if workspace.pairingFresh, let p = printer, deckAdded == false { PrinterStore.shared.remove(p.id) }
        workspace.pairingFresh = false
        workspace.pairing = nil
        dismiss()
    }
}

/// Connect a Printdeck (the printer menu, web/app/app.js connectDeck): the
/// address of a deck, with no printer first. The sheet checks that the
/// address answers as a printdeck (GET /api/version, with no key), adds an
/// entry of that address, and opens the key sheet for it (PairSheet). The
/// key sheet lists all the printers of the deck; the entry goes when the
/// user adds them.
struct ConnectDeckSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var url = ProcessInfo.processInfo.environment["ZSLICE_CONNECT_DECK"] ?? ""
    @State private var message = ""
    @State private var busy = false
    /// The address of a test connects once.
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect a Printdeck").font(.headline)
            Text("The address of the printdeck: on its System page. A secure address (https://….d.printdeck.beetlebug.org) works from anywhere; http://printdeck.local works on your network.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://….d.printdeck.beetlebug.org or http://printdeck.local", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit { connect() }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if !url.isEmpty, !tried {
                tried = true
                connect()
            }
        }
    }

    private func connect() {
        guard !busy else { return }
        var u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else {
            message = "Type the address of the printdeck."
            return
        }
        if !u.contains("://") { u = "http://" + u }
        while u.hasSuffix("/") { u.removeLast() }
        // The root of the deck: an address of one of its printers works too.
        u = PrinterLink.deckSplit(u).root
        busy = true
        message = "Looking for the printdeck…"
        Task { @MainActor in
            defer { busy = false }
            let probe = Printer(name: "printdeck", kind: .printdeck, url: u)
            guard let (d, r) = try? await PrinterLink.request(probe, "/api/version", key: false) else {
                message = "No printdeck answered at \(u). Check the address, and that this Mac is on the network of the deck."
                return
            }
            let text = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["text"] as? String ?? ""
            guard (200 ..< 300).contains(r.statusCode), text.lowercased().contains("printdeck") else {
                message = (200 ..< 300).contains(r.statusCode)
                    ? "This address is an OctoPrint printer, not a printdeck. Add it with Add a Printer…"
                    : "The address answered \(r.statusCode): it is not a printdeck."
                return
            }
            // The entry of the address, for the key; the printers of the deck
            // take its place.
            let host = URL(string: u)?.host ?? u
            let entry = Printer(name: "printdeck at \(host)", kind: .printdeck, url: u)
            PrinterStore.shared.add(entry)
            NSLog("zslice connect deck: %@ answers as a printdeck", u)
            dismiss()
            workspace.pairingFresh = true
            workspace.pairing = entry.id
        }
    }
}
