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
            let list = (await PrinterLink.deckPrinters(q) ?? []).filter { !$0.path.isEmpty && $0.kind != "resin" }
            let have = Set(PrinterStore.shared.printers.map(\.name))
            deck = list
            picked = Set(list.filter { !have.contains($0.title) }.map(\.id))
            if !list.isEmpty { text = "Connected to \(q.name). The deck drives more printers: pick the ones to add." }
            NSLog("zslice pair: the deck lists %ld more printers", list.count)
            // ZSLICE_PAIR_ADD=1 (a test) presses Add.
            if ProcessInfo.processInfo.environment["ZSLICE_PAIR_ADD"] != nil, !list.isEmpty { addDeck() }
        }
    }

    /// Each picked printer of the deck: a printdeck at the address of the
    /// deck and its path, with the key and the machine settings of the deck.
    private func addDeck() {
        guard let d = printer else { return }
        var base = d.url
        while base.hasSuffix("/") { base.removeLast() }
        let store = PrinterStore.shared
        let current = store.currentID
        for item in deck where picked.contains(item.id) {
            var p = Printer(name: item.title, model: d.model, machine: d.machine, kind: .printdeck, url: base + item.path)
            if !d.https.isEmpty {
                var h = d.https
                while h.hasSuffix("/") { h.removeLast() }
                p.https = h + item.path
            }
            p.apiKey = d.apiKey
            store.add(p)
            NSLog("zslice pair: added %@ at %@, key %d", p.name, p.url, p.apiKey == d.apiKey && !p.apiKey.isEmpty ? 1 : 0)
        }
        // Adding printers keeps the printer of the plate.
        store.currentID = current
        Task { await FarmMonitor.shared.refresh() }
        close()
    }

    private func close() {
        task?.cancel()
        workspace.pairing = nil
        dismiss()
    }
}
