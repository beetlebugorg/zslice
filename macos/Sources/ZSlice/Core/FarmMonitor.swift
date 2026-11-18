//! FarmMonitor: the status of every printer with a connection, for the
//! Printers page of each window and for the notifications of macOS.
//!
//! It reads each printer (PrinterLink.status) every 10 s while a Printers
//! page shows, else every 30 s, all at once. When a print ends, it posts
//! "Ready to collect" (the print waits on the bed), and when a print
//! fails, "Print failed", as notifications of macOS (UserNotifications).
//!
//! A printdeck never starts a print by itself: a file sent to it waits in
//! its queue until a person at the deck presses Print. OctoPrint and
//! Moonraker start a print of a file sent with print=true.
//!
//! A fleet file (tools/farm_sim/farm_sim.py writes one) adds many printers
//! at once: File > Add Printers from a Fleet File, or ZSLICE_FLEET=path.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications

@MainActor
@Observable
final class FarmMonitor {
    static let shared = FarmMonitor()

    private(set) var status: [UUID: PrinterStatus] = [:]
    private(set) var silent: Set<UUID> = []
    private(set) var updated: Date?
    private(set) var refreshing = false
    /// The Printers pages that show: they read every 10 s.
    var watchers = 0 {
        didSet { if watchers > oldValue { Task { await refresh() } } }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var asked = false

    private var printers: [Printer] { PrinterStore.shared.printers.filter { $0.kind != .none } }

    /// Starts the reads, once for the app.
    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .seconds(watchers > 0 ? 10 : 30))
            }
        }
    }

    /// Reads each printer now; each tile changes when its answer comes.
    func refresh() async {
        guard !refreshing, !printers.isEmpty else { return }
        refreshing = true
        defer {
            refreshing = false
            updated = Date()
        }
        let asks = printers.map { p in
            Task { @MainActor in
                let st = await PrinterLink.status(p)
                let before = status[p.id]
                status[p.id] = st
                if st == nil { silent.insert(p.id) } else { silent.remove(p.id) }
                if let before, let st { changed(p, from: before, to: st) }
            }
        }
        for ask in asks { await ask.value }
    }

    // MARK: - the states

    static func printing(_ st: PrinterStatus) -> Bool {
        if done(st) || failed(st) { return false }
        return (!st.job.isEmpty && st.progress > 0 && st.progress < 1) || st.state.range(of: "print|running|heating|busy", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func paused(_ st: PrinterStatus) -> Bool { st.state.range(of: "pause", options: .caseInsensitive) != nil }

    /// The print ended and waits on the bed.
    static func done(_ st: PrinterStatus) -> Bool {
        st.state.range(of: "^(finish|finished|complete|completed)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func failed(_ st: PrinterStatus) -> Bool {
        st.state.range(of: "error|fail|cancel", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - the notifications

    private func changed(_ p: Printer, from a: PrinterStatus, to b: PrinterStatus) {
        let job = b.job.isEmpty ? a.job : b.job
        if Self.done(b), !Self.done(a) {
            notify("Ready to collect: \(job.isEmpty ? "a print" : job)", "\(p.name) finished. Take the print off the bed.")
        } else if Self.failed(b), !Self.failed(a) {
            notify("Print failed on \(p.name)", job.isEmpty ? "Check the printer." : "\(job) stopped. Check the printer, then clear the bed.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        NSLog("zslice farm: %@: %@", title, body)
        // UserNotifications needs an app bundle; a bare test binary only logs.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        if asked {
            center.add(request)
            return
        }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            if ok { center.add(request) }
        }
    }

    // MARK: - a fleet file

    /// Adds the printers of a fleet file ({"printers": [{name, kind, url,
    /// key, model}]}) that the store does not have (by address).
    @discardableResult
    func addFleet(_ url: URL) -> Int {
        guard let d = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let list = j["printers"] as? [[String: Any]] else { return 0 }
        let store = PrinterStore.shared
        let have = Set(store.printers.map(\.url))
        var n = 0
        // Adding printers keeps the printer of the plate.
        let current = store.currentID
        defer { store.currentID = current }
        for f in list {
            guard let u = f["url"] as? String, !have.contains(u), let k = Printer.Kind(rawValue: f["kind"] as? String ?? "") else { continue }
            let p = Printer(name: f["name"] as? String ?? "Printer", kind: k, url: u)
            if let key = f["key"] as? String, !key.isEmpty { p.apiKey = key }
            store.add(p)
            n += 1
        }
        Task { await refresh() }
        return n
    }

    func askFleet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "A fleet file lists printers with their addresses and keys (the farm simulator writes fleet.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let n = addFleet(url)
        let a = NSAlert()
        a.messageText = n == 0 ? "No new printers" : "Added \(n) printers"
        a.informativeText = n == 0 ? "The file has no printers that zslice does not have already." : "They show on the Printers page (Option-Command-P)."
        a.runModal()
    }
}
