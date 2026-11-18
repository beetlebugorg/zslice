//! The Printers page (web/app/farm.js): the first step of a
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
//! The page covers the window (the settings pane hides), from the Printers
//! button of the toolbar (Option-Command-P), with a header: Plate (back),
//! the count and the time of the last read, and Refresh.
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

    private var printers: [Printer] { PrinterStore.shared.printers.filter { $0.kind != .none } }
    private var model: SliceModel { workspace.model }

    @State private var updated: Date?
    @State private var refreshing = false

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
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12, alignment: .top)],
                                  alignment: .leading, spacing: 12) {
                            ForEach(printers) { tile($0) }
                        }
                        queue
                    }
                    .padding(20)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // While the page shows: now, then every 10 s, and at once when a
        // printer comes or goes.
        .task(id: printers.map(\.id)) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - the header

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
            Button { Task { await refresh() } } label: {
                if refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .frame(width: 70, alignment: .trailing)
            .buttonStyle(.borderless)
            .disabled(refreshing || printers.isEmpty)
            .help("Read the printers again now (they read every 10 s)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let n = printers.count
        var s = n == 1 ? "1 printer" : "\(n) printers"
        if let updated { s += " · updated " + updated.formatted(date: .omitted, time: .shortened) }
        return s
    }

    // MARK: - the tiles

    private enum Look {
        case unknown, silent, free, printing, paused

        var color: Color {
            switch self {
            case .unknown, .silent: .secondary
            case .free: .green
            case .printing: .accentColor
            case .paused: .orange
            }
        }
    }

    private func look(_ p: Printer) -> Look {
        guard let st = status[p.id] else { return silent.contains(p.id) ? .silent : .unknown }
        if st.state.range(of: "pause", options: .caseInsensitive) != nil { return .paused }
        return isPrinting(st) ? .printing : .free
    }

    private func tile(_ p: Printer) -> some View {
        let st = status[p.id]
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
            case .printing, .paused:
                if let st {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(st.job.isEmpty ? st.state : st.job).lineLimit(1)
                        ProgressView(value: min(max(st.progress, 0), 1)).progressViewStyle(.linear)
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
                if let st {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(st.state.isEmpty ? "Ready" : st.state.capitalized)
                        if !st.roll.isEmpty || !st.material.isEmpty {
                            Text(st.roll.isEmpty ? st.material : st.roll + (st.rollLeft > 0 ? " · \(Int(st.rollLeft.rounded())) g left" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            // What it prints (a plate sent from here), and its plates to come.
            let now = workspace.printing[p.id].flatMap { id in model.plates.firstIndex { $0.id == id } }
            let next = model.plates.indices.filter { k in workspace.plateAssign[model.plates[k].id] == p.id && k != now && workspace.sentPlates[model.plates[k].id] == nil }
            if now != nil || !next.isEmpty {
                HStack(spacing: 6) {
                    if let now { PlatePreview(workspace: workspace, plate: now, size: 44).help("Printing plate \(now + 1)") }
                    if !next.isEmpty {
                        Text(now == nil ? "Up next:" : "Next:").font(.caption).foregroundStyle(.secondary)
                        ForEach(next.prefix(4), id: \.self) { k in
                            PlatePreview(workspace: workspace, plate: k, size: 30).help("Plate \(k + 1), assigned to \(p.name)")
                        }
                        if next.count > 4 { Text("+\(next.count - 4)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(busy.contains(p.id) ? "Sending…" : "Send Plate \(model.active + 1)") { send(plate: model.active, to: p) }
                    .controlSize(.small)
                    .disabled(model.state != .done || busy.contains(p.id) || l == .silent)
                    .help("Send the active plate to this printer, and start it after you confirm that its bed is clear")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(l == .printing ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)))
        .opacity(l == .silent ? 0.7 : 1)
        .accessibilityElement(children: .contain)
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
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            updated = Date()
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Plates to Print").font(.title3.weight(.semibold))
            if list.isEmpty {
                Text("No plate has parts.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.element.id) { k, item in
                        if k > 0 { Divider().padding(.leading, 44) }
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
                if let a = workspace.assigned(plate: i), workspace.sentPlates[plate.id] == nil {
                    Label("For \(a.name)", systemImage: "printer").font(.caption).foregroundStyle(.secondary)
                }
                if let sent = workspace.sentPlates[plate.id] {
                    Label(sent, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            Spacer(minLength: 12)
            if fit.isEmpty {
                Text("No printer fits").font(.callout).foregroundStyle(.secondary)
            } else {
                // The printer of the plate (the plate bar sets it too); a new
                // pick assigns the plate to it, so it slices for it.
                Picker("Printer", selection: Binding(get: { workspace.assigned(plate: i).map(\.id).flatMap { id in fit.contains { $0.id == id } ? id : nil } ?? fit.first?.id },
                                                     set: { id in if let p = printers.first(where: { $0.id == id }) { workspace.assign(plate: i, to: p) } })) {
                    ForEach(fit) { p in Text(p.name + (busyNow(p) ? " (\(busyText(p)))" : silent.contains(p.id) ? " (not answering)" : "")).tag(Optional(p.id)) }
                }
                .labelsHidden()
                .frame(width: 230)
                Button("Send") {
                    if let p = workspace.assigned(plate: i).flatMap({ a in fit.first { $0.id == a.id } }) ?? fit.first { send(plate: i, to: p) }
                }
                .disabled(!ready)
                .help(ready ? "Send this plate to the printer, after you confirm that its bed is clear" : "The plate has no slice yet")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        if let current = workspace.assigned(plate: i) ?? PrinterStore.shared.current, current.id != p.id {
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
                workspace.sentPlates[model.plates[i].id] = "Sent to \(p.name) at \(f.string(from: Date()))"
                workspace.printing[p.id] = model.plates[i].id
            }
            workspace.showNote(r.message)
            await refresh()
        }
    }
}

/// A small picture of a plate, for the Printers page. Until the core draws
/// plates (a thumbnail call), it is the number of the plate on a bed.
struct PlatePreview: View {
    let workspace: Workspace
    let plate: Int
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.18)
            .fill(Color.secondary.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: size * 0.18).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay {
                VStack(spacing: 0) {
                    Image(systemName: "cube.fill").font(.system(size: size * 0.32)).foregroundStyle(.orange)
                    if size >= 40 {
                        Text("\(plate + 1)").font(.system(size: size * 0.24, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Plate \(plate + 1)")
    }
}
