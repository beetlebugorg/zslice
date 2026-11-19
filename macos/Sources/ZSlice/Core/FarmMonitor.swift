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
//! The farm of the core (zs_farm, src/app/farm.zig) keeps the queue: the
//! orders and their jobs (one plate each), the state of each printer from
//! the reads, the sends that it proposes (a waiting job to a free printer
//! that fits it), and its events (ready, failed, paused, an order done),
//! which become the notifications. The farm never sends by itself: a send
//! is a proposal that the user confirms.
//!
//! The camera of each printer is read once, after its first answer
//! (PrinterLink.camera). A Bambu Lab printer has its camera from its
//! address and access code.
//!
//! A fleet file (tools/farm_sim/farm_sim.py writes one) adds many printers
//! at once: File > Add Printers from a Fleet File, or ZSLICE_FLEET=path.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
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
    /// The camera of each printer that has one.
    private(set) var cameras: [UUID: CameraSource] = [:]
    @ObservationIgnored private var cameraRead: Set<UUID> = []
    /// The Printers pages that show: they read every 10 s.
    var watchers = 0 {
        didSet { if watchers > oldValue { Task { await refresh() } } }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var asked = false

    /// The farm of the core, and the plate of each job (its window and the
    /// id of the plate there).
    @ObservationIgnored let farm: OpaquePointer = {
        var f: OpaquePointer?
        zs_farm_new(&f)
        return f!
    }()
    @ObservationIgnored private var plates: [UInt32: (workspace: Workspace, plate: UInt64)] = [:]
    /// Counts the changes of the farm, so the views read it again.
    private(set) var generation = 0

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
                status[p.id] = st
                if st == nil { silent.insert(p.id) } else { silent.remove(p.id) }
                if st != nil || p.kind == .bambu { await readCamera(p) }
            }
        }
        for ask in asks { await ask.value }
        feedFarm()
    }

    /// The camera of a printer, read once (again after its key changes).
    private func readCamera(_ p: Printer) async {
        let tag = p.id
        guard !cameraRead.contains(tag) else { return }
        cameraRead.insert(tag)
        cameras[tag] = await PrinterLink.camera(p)
    }

    /// Reads the camera and the status again: a new key, for one.
    func forget(_ p: Printer) {
        cameraRead.remove(p.id)
        cameras[p.id] = nil
        Task { await refresh() }
    }

    /// A printdeck or OctoPrint printer that answers 401 or 403: it has no
    /// key, or it refuses the key. A printer out of reach is offline.
    func needsKey(_ p: Printer) -> Bool {
        guard p.kind == .printdeck || p.kind == .octoprint, status[p.id] == nil else { return false }
        return PrinterLink.refused.contains(p.id)
    }

    // MARK: - the farm

    /// The printers and their states to the farm, then its events.
    private func feedFarm() {
        let now = Int64(Date().timeIntervalSince1970)
        for p in printers {
            let st = status[p.id]
            let i = zs_farm_printer_set(farm, p.id.uuidString, st?.bedX ?? 0, st?.bedY ?? 0, st?.nozzle ?? 0, st?.material ?? "", p.kind == .printdeck ? 1 : 0)
            guard i >= 0 else { continue }
            let state = st?.farmState ?? Int32(ZS_FARM_OFFLINE.rawValue)
            let why = st?.why ?? ""
            zs_farm_status(farm, Int(i), state, st?.progress ?? 0, why.isEmpty ? nil : why, now)
        }
        readEvents()
        generation += 1
    }

    /// The events of the farm as notifications.
    private func readEvents() {
        var list = [zs_farm_event](repeating: zs_farm_event(), count: 64)
        let n = zs_farm_events(farm, &list, list.count)
        for e in list.prefix(n) {
            let printer = e.printer >= 0 ? printerName(Int(e.printer)) : ""
            let job = jobName(e.job)
            let why = e.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: e.text_len), as: UTF8.self) } ?? ""
            switch Int(e.kind) {
            case Int(ZS_FARM_READY.rawValue):
                notify("Ready to collect: \(job)", "\(printer) finished. Take the print off the bed.")
            case Int(ZS_FARM_FAILED_EVENT.rawValue):
                notify("Print failed on \(printer)", "\(job) stopped\(why.isEmpty ? "" : ": \(why)"). It waits for another printer.")
            case Int(ZS_FARM_PAUSED_EVENT.rawValue):
                notify("Paused on \(printer)", "\(job) waits\(why.isEmpty ? "" : ": \(why)").")
            case Int(ZS_FARM_ORDER_DONE.rawValue):
                notify("Order done", "All jobs of the order printed.")
            case Int(ZS_FARM_ORDER_FAILED.rawValue):
                notify("Order failed", "A job of the order failed 3 times\(why.isEmpty ? "" : ": \(why)").")
            default: break
            }
        }
    }

    /// The printer of a farm index, as the store has it.
    func printer(at i: Int) -> Printer? {
        var fp = zs_farm_printer()
        guard zs_farm_printer_get(farm, i, &fp) == 0, let k = fp.key else { return nil }
        let key = String(decoding: UnsafeRawBufferPointer(start: k, count: fp.key_len), as: UTF8.self)
        return PrinterStore.shared.printers.first { $0.id.uuidString == key }
    }

    private func printerName(_ i: Int) -> String { printer(at: i)?.name ?? "a printer" }

    func index(of p: Printer) -> Int? {
        let i = zs_farm_printer_find(farm, p.id.uuidString)
        return i >= 0 ? Int(i) : nil
    }

    /// The jobs of the farm.
    var jobs: [zs_farm_job] {
        _ = generation
        return (0 ..< zs_farm_job_count(farm)).compactMap { i in
            var j = zs_farm_job()
            return zs_farm_job_get(farm, i, &j) == 0 ? j : nil
        }
    }

    func jobName(_ id: UInt32) -> String {
        guard let j = jobs.first(where: { $0.id == id }), let n = j.name else { return "a print" }
        return String(decoding: UnsafeRawBufferPointer(start: n, count: j.name_len), as: UTF8.self)
    }

    /// The job of a plate of a window, if it is in the queue.
    func job(of workspace: Workspace, plate id: UInt64) -> zs_farm_job? {
        guard let jid = plates.first(where: { $0.value.workspace === workspace && $0.value.plate == id })?.key else { return nil }
        return jobs.first { $0.id == jid }
    }

    func plate(of job: UInt32) -> (workspace: Workspace, plate: UInt64)? { plates[job] }

    /// Puts plates of a window in the queue: one order, one job for each
    /// sliced plate that is not in the queue yet. Returns how many.
    @discardableResult
    func queue(_ workspace: Workspace, plates indices: [Int], customer: String) -> Int {
        let model = workspace.model
        let list = indices.filter { i in
            model.plates.indices.contains(i) && model.plates[i].status == ZS_PLATE_STATUS_DONE.rawValue
                && job(of: workspace, plate: model.plates[i].id).map { $0.state == ZS_FARM_JOB_FAILED.rawValue } ?? true
        }
        guard !list.isEmpty else { return 0 }
        let order = zs_farm_order_add(farm, customer, 0)
        guard order > 0 else { return 0 }
        for i in list {
            guard let app = zs_set_app(model.set, i) else { continue }
            var t = zs_totals()
            zs_set_plate_totals(model.set, i, &t)
            let material = coreString { zs_app_setting_get(app, "filament.material", $0, $1, $2) } ?? ""
            let nozzle = Double(coreString { zs_app_setting_get(app, "machine.nozzle_diameter", $0, $1, $2) } ?? "") ?? 0
            let p = model.plates[i]
            let id = zs_farm_job_add(farm, UInt32(order), model.gcodeName(plate: i), material, p.bedX, p.bedY, nozzle, t.time_s)
            if id > 0 { plates[UInt32(id)] = (workspace, p.id) }
        }
        generation += 1
        return list.count
    }

    /// The sends that the farm proposes now (it changes nothing).
    var proposals: [zs_farm_send] {
        _ = generation
        var out = [zs_farm_send](repeating: zs_farm_send(), count: 64)
        let n = zs_farm_next(farm, &out, out.count)
        return Array(out.prefix(n))
    }

    /// After a send that the user confirmed.
    func sent(job: UInt32, to p: Printer) {
        guard let i = index(of: p) else { return }
        zs_farm_sent(farm, job, i, Int64(Date().timeIntervalSince1970))
        generation += 1
    }

    /// A person took the print off the bed.
    func collected(_ p: Printer) {
        guard let i = index(of: p) else { return }
        zs_farm_collected(farm, i)
        generation += 1
    }

    // MARK: - the states (zs_printer_status_farm_state, the same for each kind)

    static func printing(_ st: PrinterStatus) -> Bool { st.farmState == ZS_FARM_PRINTING.rawValue }
    static func paused(_ st: PrinterStatus) -> Bool { st.farmState == ZS_FARM_PAUSED.rawValue }
    /// The print ended and waits on the bed.
    static func done(_ st: PrinterStatus) -> Bool { st.farmState == ZS_FARM_FINISHED.rawValue }
    static func failed(_ st: PrinterStatus) -> Bool { st.farmState == ZS_FARM_FAILED.rawValue }

    // MARK: - the notifications

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
            var p = Printer(name: f["name"] as? String ?? "Printer", kind: k, url: u)
            // The id of the model in the library, if the file gives one.
            if let m = f["model"] as? String, PrinterLibrary.shared.find(id: m) != nil { p.model = m }
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
