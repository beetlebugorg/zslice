//! The Printers page (web/app/farm.js): a view of a print farm. It covers
//! the window (the settings pane hides), from the Printers button of the
//! toolbar (Option-Command-P).
//!
//! - The header: Plate (back), the count, the time of the last read, and
//!   Refresh. Under it, a summary: how many print, are ready to collect,
//!   failed, are free, and do not answer; a click shows only those.
//! - A tile for each printer (FarmMonitor reads them): a status dot, the
//!   job with its progress and the time left, "Ready to collect" (with
//!   Collected, Bed Clear) or "Failed" in color, and the plates that it
//!   prints and that come next. The printers that need a person come first.
//! - Up Next: the sends that the queue of the farm proposes (FarmMonitor,
//!   zs_farm_next), each with Send.
//! - Plates to Print: each plate with a preview, its time and grams, its
//!   state in the queue (or Queue, and Queue All), its printer (the plate
//!   bar assigns it too), and Send for a send by hand.
//!
//! A send asks first. A printdeck never starts a print by itself: the file
//! waits in its queue until a person at the deck presses Print. OctoPrint
//! and Moonraker start the print, so the app asks if the bed is clear.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI

struct FarmPage: View {
    let workspace: Workspace
    @State private var busy: Set<UUID> = []
    @State private var filter: Look?

    private var monitor: FarmMonitor { FarmMonitor.shared }
    private var printers: [Printer] { PrinterStore.shared.printers.filter { $0.kind != .none } }
    private var model: SliceModel { workspace.model }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if printers.isEmpty {
                ContentUnavailableView {
                    Label("No Printers", systemImage: "printer")
                } description: {
                    Text("Add a printer with a connection: printdeck, OctoPrint, Moonraker (Klipper), or Bambu Lab.")
                } actions: {
                    Button("Add a Printer…") { workspace.pickerOpen = true }
                    Button("Add Printers from a Fleet File…") { monitor.askFleet() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        summary
                        upNext
                        let shown = printers.filter { filter == nil || look($0) == filter }.sorted { look($0).order < look($1).order }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12, alignment: .top)],
                                  alignment: .leading, spacing: 12) {
                            ForEach(shown) { tile($0) }
                        }
                        queue
                    }
                    .padding(20)
                    .frame(maxWidth: 1400, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { monitor.watchers += 1 }
        .onDisappear { monitor.watchers -= 1 }
    }

    // MARK: - the header and the summary

    private var header: some View {
        HStack {
            Button { workspace.farmOpen = false } label: { Label("Plate", systemImage: "chevron.left") }
                .keyboardShortcut(.cancelAction)
                .help("Back to the plate (Esc)")
            Spacer()
            VStack(spacing: 1) {
                Text("Printers").font(.headline)
                if !printers.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { Task { await monitor.refresh() } } label: {
                if monitor.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .frame(width: 70, alignment: .trailing)
            .buttonStyle(.borderless)
            .disabled(monitor.refreshing || printers.isEmpty)
            .help("Read the printers again now (they read every 10 s while this page shows)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let n = printers.count
        var s = n == 1 ? "1 printer" : "\(n) printers"
        if let u = monitor.updated { s += " · updated " + u.formatted(date: .omitted, time: .shortened) }
        return s
    }

    /// One chip for each state with printers; a click shows only those.
    private var summary: some View {
        let counts = Dictionary(grouping: printers, by: look).mapValues(\.count)
        return HStack(spacing: 8) {
            ForEach(Look.allCases.filter { counts[$0] != nil }, id: \.self) { l in
                Button {
                    filter = filter == l ? nil : l
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(l.color).frame(width: 8, height: 8)
                        Text("\(counts[l] ?? 0) \(l.title)").monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(filter == l ? l.color.opacity(0.25) : Color(nsColor: .controlBackgroundColor), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                }
                .buttonStyle(.plain)
                .help(filter == l ? "Show all printers" : "Show only the printers that are \(l.title)")
            }
        }
    }

    // MARK: - the tiles

    enum Look: CaseIterable {
        case failed, ready, paused, printing, free, unknown, silent

        var color: Color {
            switch self {
            case .failed: .red
            case .ready: .green
            case .paused: .orange
            case .printing: .accentColor
            case .free: .mint
            case .unknown, .silent: .secondary
            }
        }

        var title: String {
            switch self {
            case .failed: "failed"
            case .ready: "ready to collect"
            case .paused: "paused"
            case .printing: "printing"
            case .free: "free"
            case .unknown: "reading"
            case .silent: "not answering"
            }
        }

        /// The printers that need a person first.
        var order: Int { Look.allCases.firstIndex(of: self) ?? 0 }
    }

    private func look(_ p: Printer) -> Look {
        guard let st = monitor.status[p.id] else { return monitor.silent.contains(p.id) ? .silent : .unknown }
        if FarmMonitor.failed(st) { return .failed }
        if FarmMonitor.done(st) { return .ready }
        if FarmMonitor.paused(st) { return .paused }
        return FarmMonitor.printing(st) ? .printing : .free
    }

    private func tile(_ p: Printer) -> some View {
        let st = monitor.status[p.id]
        let l = look(p)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(l.color).frame(width: 9, height: 9)
                Text(p.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(p.kind == .bambu ? "Bambu Lab" : p.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            switch l {
            case .unknown:
                Text("Reading…").foregroundStyle(.secondary)
            case .silent:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not answering").foregroundStyle(.secondary)
                    SettingsLink { Text("Printer Settings…") }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("No answer, or the printer refused the key: check its address and its key in Settings > Printers")
                }
            case .ready:
                VStack(alignment: .leading, spacing: 2) {
                    Label("Ready to collect", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.semibold))
                    if let st, !st.job.isEmpty { Text(st.job).lineLimit(1) }
                    Text("Take the print off the bed\(p.kind == .printdeck ? ", then press Print on the deck for the next one" : "").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Collected, Bed Clear") { monitor.collected(p) }
                        .controlSize(.small)
                        .help("You took the print off the bed: the printer is free for the next job of the queue")
                }
            case .failed:
                VStack(alignment: .leading, spacing: 2) {
                    Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout.weight(.semibold))
                    if let st, !st.job.isEmpty { Text(st.job).lineLimit(1) }
                    Text(st.map { $0.why.isEmpty ? "" : $0.why + ". " } ?? "")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Check the printer, then clear the bed.").font(.caption).foregroundStyle(.secondary)
                }
            case .printing, .paused:
                if let st {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(st.job.isEmpty ? st.state : st.job).lineLimit(1)
                            if l == .paused { Text("Paused").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                        }
                        ProgressView(value: min(max(st.progress, 0), 1)).progressViewStyle(.linear).tint(l.color)
                        HStack {
                            Text("\(Int((st.progress * 100).rounded())) %")
                            Spacer()
                            if st.timeLeft > 0 { Text("\(duration(st.timeLeft)) left") }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            case .free:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free")
                    if let st, !st.roll.isEmpty || !st.material.isEmpty {
                        Text(st.roll.isEmpty ? st.material : st.roll + (st.rollLeft > 0 ? " · \(Int(st.rollLeft.rounded())) g left" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            // What it prints (a plate sent from here), and its plates to come.
            let now = workspace.printing[p.id].flatMap { id in model.plates.firstIndex { $0.id == id } }
            let next = model.plates.indices.filter { k in workspace.assigned(plate: k)?.id == p.id && k != now && workspace.sentPlates[model.plates[k].id] == nil }
            if now != nil || !next.isEmpty {
                HStack(spacing: 6) {
                    if let now { PlatePreview(workspace: workspace, plate: now, size: 40).help("Plate \(now + 1), sent here") }
                    if !next.isEmpty {
                        Text(now == nil ? "Up next:" : "Next:").font(.caption).foregroundStyle(.secondary)
                        ForEach(next.prefix(4), id: \.self) { k in
                            PlatePreview(workspace: workspace, plate: k, size: 28).help("Plate \(k + 1), for \(p.name)")
                        }
                        if next.count > 4 { Text("+\(next.count - 4)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Spacer(minLength: 0)
            if busy.contains(p.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…").font(.caption) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(l == .failed || l == .ready || l == .printing ? l.color.opacity(0.6) : Color(nsColor: .separatorColor),
                                                                 lineWidth: l == .failed || l == .ready ? 2 : 1))
        .opacity(l == .silent ? 0.7 : 1)
        .accessibilityElement(children: .contain)
    }

    /// Free (or a printdeck, which queues) before busy, busy before not
    /// answering.
    private func rank(_ p: Printer) -> Int {
        switch look(p) {
        case .free: 0
        case .ready: p.kind == .printdeck ? 1 : 2
        case .printing, .paused: p.kind == .printdeck ? 1 : 3
        case .failed: 4
        case .unknown, .silent: 5
        }
    }

    private func busyNow(_ p: Printer) -> Bool { [.printing, .paused, .ready, .failed].contains(look(p)) }

    /// "busy, free in 1 h 5 min", or "busy".
    private func busyText(_ p: Printer) -> String {
        switch look(p) {
        case .ready: return "print on the bed"
        case .failed: return "failed"
        default:
            guard let st = monitor.status[p.id], st.timeLeft > 0 else { return "busy" }
            return "busy, free in \(duration(st.timeLeft))"
        }
    }

    // MARK: - the plates to print

    @ViewBuilder private var queue: some View {
        let list = model.plates.enumerated().filter { $0.element.parts > 0 }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Plates to Print").font(.title3.weight(.semibold))
                Spacer()
                Button("Queue All") {
                    let n = monitor.queue(workspace, plates: Array(model.plates.indices), customer: model.name)
                    workspace.showNote(n == 0 ? "No sliced plate to queue." : "\(n) plate\(n == 1 ? "" : "s") in the queue: see Up Next.")
                }
                .help("Put each sliced plate in the queue of the farm")
            }
            if list.isEmpty {
                Text("No plate has parts.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.element.id) { k, item in
                        if k > 0 { Divider().padding(.leading, 72) }
                        plateRow(item.offset, item.element)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }

    private func plateRow(_ i: Int, _ plate: PlateInfo) -> some View {
        let fit = printers.filter { fits($0, plate) }.sorted { rank($0) < rank($1) }
        let ready = plate.status == ZS_PLATE_STATUS_DONE.rawValue
        return HStack(spacing: 12) {
            PlatePreview(workspace: workspace, plate: i, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(plate.name.isEmpty ? "Plate \(i + 1)" : (plate.name as NSString).deletingPathExtension).lineLimit(1)
                Text(plateLine(i, plate)).font(.caption).foregroundStyle(.secondary)
                if let j = monitor.job(of: workspace, plate: plate.id) {
                    jobLabel(j)
                } else if let sent = workspace.sentPlates[plate.id] {
                    Label(sent, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if let a = workspace.assigned(plate: i) {
                    Label("For \(a.name)", systemImage: "printer").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if ready, monitor.job(of: workspace, plate: plate.id).map({ $0.state == ZS_FARM_JOB_FAILED.rawValue }) ?? true {
                Button("Queue") { monitor.queue(workspace, plates: [i], customer: model.name) }
                    .help("Put this plate in the queue of the farm: zslice proposes a free printer that fits it")
            }
            if fit.isEmpty {
                Text("No printer fits").font(.callout).foregroundStyle(.secondary)
            } else {
                // The printer of the plate (the plate bar sets it too); a new
                // pick assigns the plate to it, so it slices for it.
                Picker("Printer", selection: Binding(get: { workspace.assigned(plate: i).map(\.id).flatMap { id in fit.contains { $0.id == id } ? id : nil } ?? fit.first?.id },
                                                     set: { id in if let p = printers.first(where: { $0.id == id }) { workspace.assign(plate: i, to: p) } })) {
                    ForEach(fit) { p in Text(p.name + (busyNow(p) ? " (\(busyText(p)))" : monitor.silent.contains(p.id) ? " (not answering)" : "")).tag(Optional(p.id)) }
                }
                .labelsHidden()
                .frame(width: 240)
                Button("Send") {
                    if let p = workspace.assigned(plate: i).flatMap({ a in fit.first { $0.id == a.id } }) ?? fit.first { send(plate: i, to: p) }
                }
                .disabled(!ready)
                .help(ready ? "Send this plate to the printer, after you confirm" : "The plate has no slice yet")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The sends that the farm proposes: a waiting job to a free printer
    /// that fits it. Each waits for a press of Send.
    @ViewBuilder private var upNext: some View {
        let list = monitor.proposals.compactMap { s -> (UInt32, Printer, Workspace, Int)? in
            guard let p = monitor.printer(at: s.printer), let ref = monitor.plate(of: s.job),
                  let i = ref.workspace.model.plates.firstIndex(where: { $0.id == ref.plate }) else { return nil }
            return (s.job, p, ref.workspace, i)
        }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next").font(.title3.weight(.semibold))
                Text("The queue proposes each job to a free printer that fits it. Nothing goes out until you press Send.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.0) { k, item in
                        if k > 0 { Divider().padding(.leading, 72) }
                        HStack(spacing: 12) {
                            PlatePreview(workspace: item.2, plate: item.3, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(monitor.jobName(item.0)).lineLimit(1)
                                Label(item.1.name, systemImage: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Send") { send(plate: item.3, to: item.1, from: item.2, job: item.0) }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy.contains(item.1.id))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
            }
        }
    }

    /// The state of a job of the queue, in a few words.
    private func jobLabel(_ j: zs_farm_job) -> some View {
        let p = j.printer >= 0 ? monitor.printer(at: Int(j.printer))?.name ?? "a printer" : ""
        let tries = j.tries > 1 ? " (try \(j.tries))" : ""
        // A printdeck waits for a press of Print on the deck.
        let deck = j.printer >= 0 && monitor.printer(at: Int(j.printer))?.kind == .printdeck
        let sent = deck ? "Waiting on \(p): press Print on the deck" : "Sent to \(p)"
        let (text, icon, color): (String, String, Color) = switch Int(j.state) {
        case Int(ZS_FARM_JOB_WAITING.rawValue): ("In the queue, waiting for a printer" + tries, "clock", .secondary)
        case Int(ZS_FARM_JOB_SENT.rawValue): (sent + tries, "paperplane", .accentColor)
        case Int(ZS_FARM_JOB_PRINTING.rawValue): ("Printing on \(p), \(Int((j.progress * 100).rounded())) %", "printer.fill", .accentColor)
        case Int(ZS_FARM_JOB_DONE.rawValue): ("Ready to collect on \(p)", "checkmark.circle.fill", .green)
        case Int(ZS_FARM_JOB_COLLECTED.rawValue): ("Done", "checkmark.seal.fill", .green)
        default: ("Failed 3 times: queue it again", "xmark.octagon.fill", .red)
        }
        return Label(text, systemImage: icon).font(.caption).foregroundStyle(color)
    }

    private func parts(_ n: Int) -> String { n == 1 ? "1 part" : "\(n) parts" }

    /// "3 parts · 1 h 13 min · 30.0 g", or "not sliced yet".
    private func plateLine(_ i: Int, _ plate: PlateInfo) -> String {
        guard plate.status == ZS_PLATE_STATUS_DONE.rawValue else { return "\(parts(plate.parts)), not sliced yet" }
        var t = zs_totals()
        guard zs_set_plate_totals(model.set, i, &t) == 0, t.time_s > 0 else { return "\(parts(plate.parts)), sliced" }
        return "\(parts(plate.parts)) · \(duration(t.time_s)) · " + String(format: "%.1f g", t.filament_g)
    }

    private func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    /// A printer whose bed is known and smaller than the plate does not fit.
    private func fits(_ p: Printer, _ plate: PlateInfo) -> Bool {
        guard let st = monitor.status[p.id], st.bedX > 0 else { return true }
        return st.bedX + 0.5 >= plate.bedX && st.bedY + 0.5 >= plate.bedY
    }

    // MARK: - the send

    private func send(plate i: Int, to p: Printer, from ws: Workspace? = nil, job: UInt32? = nil) {
        let workspace = ws ?? self.workspace
        let model = workspace.model
        guard let data = model.gcode(plate: i) else {
            workspace.showNote("No G-code: the plate has no slice yet.")
            return
        }
        let title = model.gcodeName(plate: i)
        let deck = p.kind == .printdeck
        // A fresh confirmation each time. G-code for another printer can
        // have another bed, nozzle, or temperatures: say so.
        let a = NSAlert()
        a.messageText = "Send \"\(title)\" to \(p.name)?"
        var info = "Is the bed of \(p.name) clear? The print starts when the file is there."
            + (deck ? " A deck set to ask waits for a press of Print on it." : "")
        if let current = workspace.assigned(plate: i) ?? PrinterStore.shared.current, current.id != p.id {
            info = "The plate is sliced for \(current.name), not for \(p.name). Choose \(p.name) for the plate to slice it for that printer first.\n\n" + info
        }
        if let app = zs_set_app(model.set, i), zs_app_plate_fits(app) == 0 {
            info = "A part is off the bed or on another part. The printer can hit its frame or the other part.\n\n" + info
        }
        if busyNow(p), !deck { info = "\(p.name) looks busy now (\(busyText(p))).\n\n" + info }
        if p.kind == .bambu { info += " (Bambu support is untested with a real printer.)" }
        a.informativeText = info
        a.addButton(withTitle: "The Bed Is Clear: Send")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy.insert(p.id)
        Task { @MainActor in
            let r = await workspace.transfer(data, title: title, to: p, print: true)
            busy.remove(p.id)
            if r.ok, let job { monitor.sent(job: job, to: p) }
            if r.ok, model.plates.indices.contains(i) {
                let time = Date().formatted(date: .omitted, time: .shortened)
                workspace.sentPlates[model.plates[i].id] = "Sent to \(p.name) at \(time)"
                workspace.printing[p.id] = model.plates[i].id
            }
            workspace.showNote(r.message)
            await monitor.refresh()
        }
    }
}

/// A small picture of a plate, for the Printers page: the parts in their
/// filament color (zs_app_thumbnail_png), from the meshes, so a plate shows
/// before it slices. The pictures are kept until the plate changes.
struct PlatePreview: View {
    let workspace: Workspace
    let plate: Int
    var size: CGFloat = 44

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.18)
            .fill(Color.secondary.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: size * 0.18).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay {
                if let img = image {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit().padding(size * 0.06)
                } else {
                    Image(systemName: "square.dashed").font(.system(size: size * 0.4)).foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if size >= 40 {
                    Text("\(plate + 1)")
                        .font(.system(size: max(9, size * 0.2), weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .padding(2)
                }
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Plate \(plate + 1)")
    }

    private var image: NSImage? {
        let model = workspace.model
        guard model.plates.indices.contains(plate), let app = zs_set_app(model.set, plate) else { return nil }
        let info = model.plates[plate]
        // A new picture when the plate or its parts change.
        let px = UInt32(min(1024, size * 2))
        let key = "\(info.id)-\(info.parts)-\(info.status)-\(model.settingsGeneration)-\(px)"
        if let img = Self.cache[key] { return img }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard zs_app_thumbnail_png(app, px, px, &out, &len) == 0, let out else { return nil }
        let img = NSImage(data: Data(bytes: out, count: len))
        zs_buffer_free(out, len)
        if Self.cache.count > 300 { Self.cache.removeAll() }
        Self.cache[key] = img
        return img
    }
}
