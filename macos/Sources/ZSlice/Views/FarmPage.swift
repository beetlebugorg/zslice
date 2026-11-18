//! The Printers page of the drawer (web/app/farm.js): the first step of a
//! view of a print farm. A tile for each printer with a connection: its
//! name, its kind, its state (the job, the progress, the time left, or the
//! filament), and a progress bar while it prints. The tiles read the
//! status again every 10 s, only while the page shows. A printer that does
//! not answer fades and says so.
//!
//! "Send the Plate" on a tile sends the active plate. Under the tiles,
//! "Plates to Print" lists the plates with parts, each with a printer (the
//! free ones first, and none whose bed is smaller than the plate) and
//! Send. Each send asks the user first if the bed of that printer is
//! clear, and says when the plate is sliced for another printer. A plate
//! row has its time and grams (zs_set_plate_totals), a busy printer says
//! when it is free, and a plate sent in this session says where and when.
//!
//! The page covers the view and the pane (DocumentWindow), from the
//! Printers button of the toolbar (Option-Command-P).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI

struct FarmPage: View {
    let workspace: Workspace
    @State private var status: [UUID: PrinterStatus] = [:]
    @State private var silent: Set<UUID> = []
    @State private var busy: Set<UUID> = []
    @State private var picks: [UInt64: UUID] = [:]

    private var printers: [Printer] { PrinterStore.shared.printers.filter { $0.kind != .none } }
    private var model: SliceModel { workspace.model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if printers.isEmpty {
                    Text("No printer has a connection. Add one with Add a Printer in the printer menu, or set a connection in Settings > Printers: printdeck, OctoPrint, Moonraker (Klipper), or Bambu Lab.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(printers.count) with a connection. The tiles read again every 10 s.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(printers) { tile($0) }
                    }
                    queue
                }
            }
            .padding(12)
        }
        // While the page shows: now, then every 10 s, and at once when a
        // printer comes or goes.
        .task(id: printers.map(\.id)) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - the tiles

    private func tile(_ p: Printer) -> some View {
        let st = status[p.id]
        let printing = st.map(isPrinting) ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Text(p.name).font(.headline).lineLimit(1)
            Text(p.kind.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let st {
                    Text(st.line)
                } else if silent.contains(p.id) {
                    Text("No answer, or the printer refused the key: check the address and the key in Settings > Printers.")
                } else {
                    Text("…")
                }
            }
            .font(.callout)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            if printing, let st {
                ProgressView(value: st.progress).progressViewStyle(.linear)
            }
            Button("Send the Plate") { send(plate: model.active, to: p) }
                .controlSize(.small)
                .disabled(model.state != .done || busy.contains(p.id))
                .help("Send the G-code of the active plate to this printer, and start it after you confirm that its bed is clear")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(printing ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .opacity(silent.contains(p.id) ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private func isPrinting(_ st: PrinterStatus) -> Bool {
        (!st.job.isEmpty && st.progress > 0 && st.progress < 1) || st.state.range(of: "print|running|busy", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func free(_ p: Printer) -> Bool {
        guard let st = status[p.id] else { return false }
        return !isPrinting(st) && st.state.range(of: "pause", options: .caseInsensitive) == nil
    }

    /// The status of each printer, all at once.
    private func refresh() async {
        // Each tile changes when its own answer comes.
        let asks = printers.map { p in
            Task { @MainActor in
                let st = await PrinterLink.status(p)
                status[p.id] = st
                if st == nil { silent.insert(p.id) } else { silent.remove(p.id) }
            }
        }
        for ask in asks { await ask.value }
    }

    /// Known to be printing or paused.
    private func busyNow(_ p: Printer) -> Bool { status[p.id] != nil && !free(p) }

    // MARK: - the plates to print

    @ViewBuilder private var queue: some View {
        let list = model.plates.enumerated().filter { $0.element.parts > 0 }
        Text("Plates to Print").font(.headline).padding(.top, 6)
        if list.isEmpty {
            Text("No plate has parts.").foregroundStyle(.secondary)
        }
        ForEach(list, id: \.element.id) { i, plate in
            let fit = printers.filter { fits($0, plate) }.sorted { rank($0) < rank($1) }
            HStack {
                VStack(alignment: .leading) {
                    Text("\(i + 1). \(plate.name.isEmpty ? "Plate \(i + 1)" : plate.name)").lineLimit(1)
                    Text(plateLine(i, plate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sent = workspace.sentPlates[plate.id] {
                        Text("✓ " + sent).font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer()
                Picker("Printer", selection: Binding(get: { picks[plate.id] ?? fit.first?.id }, set: { picks[plate.id] = $0 })) {
                    ForEach(fit) { p in Text(p.name + (busyNow(p) ? " (\(busyText(p)))" : silent.contains(p.id) ? " (no answer)" : "")).tag(Optional(p.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                Button("Send") {
                    if let id = picks[plate.id] ?? fit.first?.id, let p = printers.first(where: { $0.id == id }) { send(plate: i, to: p) }
                }
                .disabled(plate.status != ZS_PLATE_STATUS_DONE.rawValue || fit.isEmpty)
                .help(fit.isEmpty ? "No printer with a connection fits this plate" : "Send this plate to the printer, after you confirm that its bed is clear")
            }
        }
    }

    private func parts(_ n: Int) -> String { n == 1 ? "1 part" : "\(n) parts" }

    /// "3 parts · 1h 13m · 30.0 g", or "not sliced yet".
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

    /// The order of the printers for a plate: free, busy, then no answer.
    private func rank(_ p: Printer) -> Int {
        status[p.id] == nil ? 2 : busyNow(p) ? 1 : 0
    }

    /// "busy, free in 1 h 5 min", or "busy".
    private func busyText(_ p: Printer) -> String {
        guard let st = status[p.id], st.timeLeft > 0 else { return "busy" }
        return "busy, free in \(duration(st.timeLeft))"
    }

    /// A printer whose bed is known and smaller than the plate does not fit.
    private func fits(_ p: Printer, _ plate: PlateInfo) -> Bool {
        guard let st = status[p.id], st.bedX > 0 else { return true }
        return st.bedX + 0.5 >= plate.bedX && st.bedY + 0.5 >= plate.bedY
    }

    // MARK: - the send

    private func send(plate i: Int, to p: Printer) {
        guard let data = model.gcode(plate: i) else {
            workspace.showNote("No G-code: the plate has no slice yet.")
            return
        }
        let title = model.gcodeName(plate: i)
        // A fresh confirmation each time. G-code for another printer can
        // have another bed, nozzle, or temperatures: say so.
        let a = NSAlert()
        a.messageText = "Send \"\(title)\" to \(p.name)?"
        var info = "Is the bed of \(p.name) clear? The print can start when the file is there."
        if let current = PrinterStore.shared.current, current.id != p.id {
            info = "The plate is sliced for \(current.name), not for \(p.name). Choose \(p.name) in the printer menu to slice it for that printer first.\n\n" + info
        }
        if let app = zs_set_app(model.set, i), zs_app_plate_fits(app) == 0 {
            info = "A part is off the bed or on another part. The printer can hit its frame or the other part.\n\n" + info
        }
        if busyNow(p) { info = "\(p.name) looks busy now (\(busyText(p))).\n\n" + info }
        if p.kind == .bambu { info += " (Bambu support is untested with a real printer.)" }
        a.informativeText = info
        a.addButton(withTitle: "The Bed Is Clear: Send")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy.insert(p.id)
        Task { @MainActor in
            let r = await workspace.transfer(data, title: title, to: p, print: true)
            busy.remove(p.id)
            if r.ok, model.plates.indices.contains(i) {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                workspace.sentPlates[model.plates[i].id] = "\(title) sent to \(p.name) at \(f.string(from: Date()))"
            }
            workspace.showNote(r.message)
            await refresh()
        }
    }
}
