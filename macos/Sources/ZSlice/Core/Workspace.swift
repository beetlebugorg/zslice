//! Workspace: the model of one window. It holds the plate (a SliceModel),
//! the 3D view, the layer range, and the replay.
//!
//! The layer range is two numbers: the top layer that shows (hi) and the
//! lowest layer that shows (lo). The view shows the layers lo to hi. After a
//! new slice, the top knob stays where it was if it can; a top knob at the
//! top layer stays at the top (web/app/layers.js, linux/src/ui/layer-range.c).
//!
//! The replay moves the nozzle along the print in time (zs_view_set_time).
//! The scrub bar shows the time in the top layer: layer l prints from the
//! end time of the last path of layer l - 1 to the end time of its own last
//! path (zs_toolpaths.path_end_time). The replay runs on the frames of the
//! display link of the view, and the layer slider follows it.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import ImageIO
import CZslice
import Observation

@MainActor
@Observable
final class Workspace {
    let model = SliceModel()
    @ObservationIgnored let canvas = MetalSliceView(frame: .zero)

    // The layers of the last slice, and the range that shows.
    private(set) var layerCount = 0
    /// After each slice: each part is on the bed and on no other part
    /// (zs_app_plate_fits).
    private(set) var plateFits = true
    static let offBed = "A part is off the bed or on another part. Move it, turn it, scale it, or cut it (the part card) before you print."

    /// Before an export or a send of a plate whose parts do not fit: the
    /// user goes on only after a warning.
    func goOnOffBed() -> Bool {
        guard !plateFits else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "A part is off the bed or on another part"
        a.informativeText = "The printer can hit its frame or the other part. Go on?"
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Go On")
        return a.runModal() == .alertSecondButtonReturn
    }

    /// Fit the view to the plate after the next slice (after a fill).
    @ObservationIgnored var fitAfterSlice = false
    /// The Support tool (Support.swift): the areas of the core, the points
    /// of the area that the user draws now, the selected area, the kind of
    /// the next area, and "See through the support".
    var supportAreas: [SupportArea] = []
    var supportDraft: [SIMD3<Double>] = []
    var supportSelected: Int?
    var supportKind = Int32(ZS_MARK_GRID.rawValue)
    /// The overhang under the pointer in the Support tool: its outline and
    /// z range (zs_app_support_pick). A click adds it as an area.
    @ObservationIgnored var supportHover: (points: [Double], n: Int, zLo: Double, zHi: Double)?
    @ObservationIgnored var hoverAt: CGPoint?
    @ObservationIgnored var hoverDue = false
    var supportSee = true {
        didSet { applyFocus() }
    }
    @ObservationIgnored var supportDrag: SupportDrag?
    /// The support trees (SupportTrees.swift): the nodes of each part, the
    /// selected node, the rules that limited the last edit, the note of a
    /// drop of the trees, "Add a Branch" and its foot, and the drag.
    var supportTrees: [Int: SupportTree] = [:]
    var treeSelected: (part: Int, node: UInt32)?
    var treeClamp: UInt32 = 0
    var treeNote: String?
    var treeAdding = false
    var treeFoot: SIMD2<Double>?
    @ObservationIgnored var treeDrag: TreeDrag?
    @ObservationIgnored var treeTimer: Task<Void, Never>?
    /// The Cut popover of the part card is open.
    var cutOpen = false
    private(set) var lo = 0
    private(set) var hi = 0
    @ObservationIgnored private(set) var layerEnd: [Double] = []
    @ObservationIgnored private(set) var layerZ: [Float] = []
    @ObservationIgnored private(set) var layerSlowed: [Bool] = []

    // The replay: the print time that the view shows (nil: the whole layer
    // range), and its speed.
    private(set) var time: Double?
    private(set) var playing = false
    var speed = 10.0

    static let speeds: [Double] = [1, 2, 5, 10, 25, 50, 100]

    /// The state of the last send to the printer, for the print card.
    var sendState: String?
    /// The status of the current printer, and its estimate of the plate.
    var printerStatus: PrinterStatus?
    var printerEstimate: PrinterEstimate?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// A printer of a test (ZSLICE_STATUS_URL), not in the store.
    @ObservationIgnored var testPrinter: Printer?
    /// The sheet of the printer picker shows.
    var pickerOpen = false

    // The tools (Tools.swift).
    var tool = Tool.select
    /// The details of the print show above the bottom bar.
    var detailsOpen = false
    /// The usual refinements of the user for this plate (Refinements.swift).
    var refinements: [Refinement] = []
    /// The id of the project of each plate in the store of refinements, by
    /// the id of the plate (kept with the session).
    @ObservationIgnored var refineIDs: [String: String] = [:]
    @ObservationIgnored var refineTask: Task<Void, Never>?
    @ObservationIgnored var refineApplied = false
    @ObservationIgnored var issuesTask: Task<Void, Never>?
    /// The card of the Support tool shows (S again hides it; kept).
    var supportPaneOpen = UserDefaults.standard.object(forKey: "supportPane") as? Bool ?? true {
        didSet { UserDefaults.standard.set(supportPaneOpen, forKey: "supportPane") }
    }
    var selectedPart: Int?
    @ObservationIgnored var partDrag: PartDrag?
    @ObservationIgnored var tapeDrag: Int?
    /// A drag of a ring of the Turn tool: its axis, and the degrees sent.
    @ObservationIgnored var ringDrag: (axis: Int, sent: Double)?
    /// A part that falls in the view (Tools.swift, settle), and what comes
    /// at its rest.
    @ObservationIgnored var falling: (part: Int, then: (() -> Void)?)?
    @ObservationIgnored var fallClock = 0.0
    @ObservationIgnored var fallCheckDue = false
    /// The Grab tool holds a part (it moves with zs_app_grab_move), at the
    /// height of the hand.
    @ObservationIgnored var grabbing = false
    @ObservationIgnored var grabZ = 0.0
    /// The last place of the pointer of the hand, and the turn of the
    /// hand (Option and a drag) so far, and the part of it sent.
    @ObservationIgnored var handAt: CGPoint?
    @ObservationIgnored var handTurn: (yaw: Double, tilt: Double, sentYaw: Double, sentTilt: Double) = (0, 0, 0, 0)
    @ObservationIgnored var fallIsGrab = false
    @ObservationIgnored var fallSteps = 0
    @ObservationIgnored var fallFrame = 0
    /// The label of a ring drag ("+30° about Z") and its place.
    var ringLabel: (text: String, at: CGPoint)?
    @ObservationIgnored let wheelSlice = Throttle(.milliseconds(300))
    @ObservationIgnored let keySlice = Throttle(.milliseconds(600))
    /// The fall of a part 0.6 s after the last turn key (Tools.swift).
    @ObservationIgnored var settleTask: Task<Void, Never>?
    var tape: [TapePoint] = []
    /// The points of the tape in the view (points), for the readout.
    var tapeScreen: [CGPoint] = []

    // Gaps and Check (Checks.swift).
    var gapsOn = false
    var gapSummary: (count: Int, area: Double)?
    var gapCard: GapInfo?
    var checkOpen = false
    var issues: [Issue] = []

    // The selected line and its card (Selection.swift).
    var selection: Selection?
    var lineInfo: LineInfo?
    @ObservationIgnored var refindKey: RefindKey?
    var cardOpen = false
    /// Where the click was (points in the view), and where the user moved
    /// the card to; the card keeps that place until it closes.
    var cardAt = CGPoint(x: 120, y: 120)
    var cardMoved: CGPoint?
    /// "Fade the others": the app keeps the choice.
    var isolate = UserDefaults.standard.bool(forKey: "isolate") {
        didSet { UserDefaults.standard.set(isolate, forKey: "isolate") }
    }

    /// The page of the view: 3D, or one layer from the top. The app keeps
    /// the choice for the next window.
    var page: MetalSliceView.Page = MetalSliceView.Page(rawValue: UserDefaults.standard.string(forKey: "view") ?? "") ?? .threeD {
        didSet {
            canvas.page = page
            UserDefaults.standard.set(page.rawValue, forKey: "view")
            SessionStore.shared.changedView()
        }
    }

    init() {
        canvas.delegate = self
        // For tests: ZSLICE_STATUS_URL=http://… is a printdeck printer with
        // no key, and ZSLICE_GZIP=path writes the gzip of the G-code there.
        if let u = ProcessInfo.processInfo.environment["ZSLICE_STATUS_URL"] {
            testPrinter = Printer(name: "test", kind: .printdeck, url: u)
        }
        startStatus()
        if ProcessInfo.processInfo.environment["ZSLICE_PANEL"] != nil { showSettings = true }
        // ZSLICE_SEARCH=text opens the search with that text (the field reads it).
        if ProcessInfo.processInfo.environment["ZSLICE_SEARCH"] != nil { searchOpen = true }
        // ZSLICE_DISCOVER=1 searches the network and logs the printers.
        if ProcessInfo.processInfo.environment["ZSLICE_DISCOVER"] != nil {
            let d = Discovery()
            d.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) {
                NSLog("zslice discovery: %d printers: %@", d.found.count, d.found.map { "\($0.name) \($0.kindTitle) \($0.url) \($0.model) \($0.serial)" }.joined(separator: "; "))
            }
        }
        // ZSLICE_PRINTER=id: the printer of that model of the library.
        if let id = ProcessInfo.processInfo.environment["ZSLICE_PRINTER"], let i = PrinterLibrary.shared.find(id: id),
           let m = PrinterLibrary.shared.model(i), let prof = PrinterLibrary.shared.profile(i) {
            usePrinter(Printer(name: coreText(m.title), model: id, machine: prof))
        }
        // ZSLICE_GAPS=1 shows the gaps, and ZSLICE_CHECK=1 the check.
        if ProcessInfo.processInfo.environment["ZSLICE_GAPS"] != nil { gapsOn = true }
        if ProcessInfo.processInfo.environment["ZSLICE_CHECK"] != nil { checkOpen = true }
        // For screenshots: ZSLICE_DARK=1 or 0 sets the look of the app.
        if let d = ProcessInfo.processInfo.environment["ZSLICE_DARK"] {
            NSApp.appearance = NSAppearance(named: d == "1" ? .darkAqua : .aqua)
        }
        if let m = ProcessInfo.processInfo.environment["ZSLICE_MODE"].flatMap(Int.init) { colorMode = m }
        if let p = ProcessInfo.processInfo.environment["ZSLICE_VIEW"].flatMap(MetalSliceView.Page.init) { page = p }
        canvas.page = page
        model.onSliced = { [weak self] in self?.sliced() }
        model.onPlates = { [weak self] in self?.syncPlates() }
        model.onActivePlate = { [weak self] in
            self?.activePlateChanged()
            self?.checkPendingFall()
        }
        model.onChanged = { [weak self] in self?.checkPendingFall() }
        SessionStore.shared.register(self)
        if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
            NSLog("zslice timing: window model ready %.0f ms after the start", (CACurrentMediaTime() - SessionStore.launch) * 1000)
        }
    }

    /// A session goes back into the window (Session.swift): the camera of
    /// the session stays, and the first slice takes its layers and part.
    @ObservationIgnored var restoring = false
    @ObservationIgnored var restoredRange: (Int, Int)?
    @ObservationIgnored var restoredPart: Int?

    // MARK: - the slice

    private func sliced() {
        let t0 = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
                NSLog("zslice timing: after the slice %.1f ms on the main thread", (CACurrentMediaTime() - t0) * 1000)
            }
        }
        stopReplay()
        if let v = canvas.view { zs_view_set_mode(v, Int32(colorMode)) }
        let tl = CACurrentMediaTime()
        canvas.load(model.core)
        if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
            NSLog("zslice timing: view load %.1f ms", (CACurrentMediaTime() - tl) * 1000)
        }
        // The bed model of the printer (it needs the bed size of the load).
        if let v = canvas.view { PrinterLibrary.shared.showBed(of: model.core, in: v) }
        readLegend()
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0 else { return }
        let n = tp.layer_count
        layerZ = Array(UnsafeBufferPointer(start: tp.layer_z, count: tp.layer_z == nil ? 0 : n))
        layerSlowed = tp.layer_slowed == nil ? Array(repeating: false, count: n) : (0 ..< n).map { tp.layer_slowed[$0] != 0 }
        layerEnd = (0 ..< n).map { l in
            let end = Int(tp.layer_ends[l])
            return end > 0 && tp.path_end_time != nil ? Double(tp.path_end_time[end - 1]) : 0
        }
        if ProcessInfo.processInfo.environment["ZSLICE_LAYER_LOG"] != nil {
            NSLog("zslice layers: %d, times %@, last ends %@, path_end_time %d", n, layerEnd.suffix(3).map { String(format: "%.1f", $0) }.joined(separator: " "),
                  (0 ..< min(3, n)).map { String(tp.layer_ends[n - 1 - $0]) }.joined(separator: " "), tp.path_end_time == nil ? 0 : 1)
        }
        let wasTop = hi >= layerCount - 1
        layerCount = n
        if wasTop || hi >= n { hi = max(0, n - 1) }
        lo = min(lo, hi)
        if let r = restoredRange {
            restoredRange = nil
            hi = max(0, min(r.1, n - 1))
            lo = max(0, min(r.0, hi))
        }
        applyRange()
        applyFocus()
        refindSelection()
        askEstimate()
        gapCard = nil
        showGaps()
        // The checks (about 10 ms on a large part) come after the frame of
        // the new slice, so the slice shows at once.
        issuesTask?.cancel()
        issuesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, model.state == .done else { return }
            readIssues()
        }
        if let i = selectedPart { selectPart(i < zs_app_part_count(model.core) ? i : nil) }
        if let i = restoredPart {
            restoredPart = nil
            if i < zs_app_part_count(model.core) { selectPart(i) }
        }
        readSupportTrees()
        readSupportAreas()
        refreshRefinementsSoon()
        SessionStore.shared.changed()
        if ProcessInfo.processInfo.environment["ZSLICE_EDIT"] != nil {
            let n = zs_app_edit_count(model.core)
            var line = "zslice edits: \(n), \(tp.path_count) paths"
            for i in 0 ..< n {
                var kind: Int32 = 0, value = 0.0, layer = 0, applied: Int32 = 0
                zs_app_edit_get(model.core, i, &kind, &value, &layer, &applied)
                line += "; kind \(kind) value \(value) layer \(layer) applied \(applied)"
            }
            NSLog("%@", line)
        }
        plateFits = zs_app_plate_fits(model.core) != 0
        if ProcessInfo.processInfo.environment["ZSLICE_GCODE_NAME"] != nil { NSLog("zslice gcode name: %@", model.gcodeName()) }
        if fitAfterSlice {
            fitAfterSlice = false
            fit()
        }
        // For tests of memory and time: ZSLICE_RESLICE=n changes the wall
        // count after each slice, n times, so the plate slices n times more.
        if reslices > 0 {
            reslices -= 1
            model.set("project.wall_count", reslices % 2 == 0 ? "2" : "3")
            model.history.commit()
        }
        // After the first frames of the new slice: a pick needs the camera.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.applyTestHooks() }
    }

    /// For development and screenshots, once after the first slice:
    /// ZSLICE_LAYERS=lo,hi sets the layer range (layer numbers from 1), and
    /// ZSLICE_TIME=t shows the replay at t seconds (as in the GTK app).
    @ObservationIgnored private var hooked = false
    @ObservationIgnored private var reslices = ProcessInfo.processInfo.environment["ZSLICE_RESLICE"].flatMap(Int.init) ?? 0

    private func applyTestHooks() {
        guard !hooked else { return }
        hooked = true
        let env = ProcessInfo.processInfo.environment
        if let r = env["ZSLICE_LAYERS"]?.split(separator: ",").compactMap({ Int($0) }), r.count == 2 {
            setRange(lo: r[0] - 1, hi: r[1] - 1)
        }
        // ZSLICE_SET="name=value;name=value" makes each change a step, and
        // ZSLICE_UNDO=n then undoes n steps through the UndoManager.
        if let sets = env["ZSLICE_SET"] {
            model.history.commit()
            for pair in sets.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { model.set(kv[0], kv[1]) }
                model.history.commit()
            }
            for _ in 0 ..< (env["ZSLICE_UNDO"].flatMap(Int.init) ?? 0) { model.history.undoManager.undo() }
        }
        // ZSLICE_TOOL=name picks a tool, ZSLICE_CLICKS="x,y;x,y" clicks with
        // it, and ZSLICE_DRAG="x0,y0;x1,y1" is a Command-drag (points).
        let points = { (key: String) -> [CGPoint] in
            (env[key] ?? "").split(separator: ";").compactMap { pair -> CGPoint? in
                if pair == "center" { return CGPoint(x: self.canvas.bounds.midX, y: self.canvas.bounds.midY) }
                let xy = pair.split(separator: ",").compactMap { Double($0) }
                return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
            }
        }
        if let t = env["ZSLICE_TOOL"].flatMap(Tool.init) { setTool(t) }
        for p in points("ZSLICE_CLICKS") { sliceViewClick(p) }
        // ZSLICE_SUPPORT_CLOSE=1 closes the area that the clicks drew.
        if env["ZSLICE_SUPPORT_CLOSE"] != nil {
            NSLog("zslice support: draft %d", supportDraft.count)
            closeSupportArea()
            NSLog("zslice support: areas %d", zs_app_support_area_count(model.core))
        }
        let drag = points("ZSLICE_DRAG")
        if drag.count == 2, press(drag[0], .command) {
            self.drag(drag[1], .command)
            release(drag[1])
        }
        // ZSLICE_CUT=1 opens the Cut popover of a selected part.
        // ZSLICE_CUT=z cuts it at z mm, with the top over and 2 pegs.
        if let c = env["ZSLICE_CUT"], let i = selectedPart {
            if let z = Double(c), z > 1 {
                let n = zs_app_part_cut(model.core, i, z, 1, 2, 5)
                NSLog("zslice cut: %ld", n)
                if n > 0 { model.settingsChanged() }
            } else {
                cutOpen = true
            }
        }
        // ZSLICE_MOVE=i moves part i to a new plate; ZSLICE_SAVE=path saves
        // the project file there.
        if let m = env["ZSLICE_MOVE"], let i = Int(m) { movePartToNewPlate(i) }
        // ZSLICE_FILL=n: n of the selected part in all.
        if let f = env["ZSLICE_FILL"], let n = Int(f) { fillPart(n) }
        if let path = env["ZSLICE_SAVE"], let data = model.projectFileData(name: model.name) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        // ZSLICE_TEST_PRINT=path writes the test print of layers 10 to 12.
        if let path = env["ZSLICE_TEST_PRINT"] {
            var out: UnsafeMutablePointer<UInt8>?
            var len = 0
            if zs_app_debug_gcode(model.core, 9, 12, &out, &len) == 0, let out {
                try? Data(bytes: out, count: len).write(to: URL(fileURLWithPath: path))
                zs_buffer_free(out, len)
            }
        }
        // ZSLICE_BAMBU=address:serial:code runs the link of Bambu.swift on
        // the plate: the upload, the start, and the status, with logs.
        if let b = env["ZSLICE_BAMBU"], let data = model.gcode() {
            let f = b.split(separator: ":").map(String.init)
            var p = Printer(name: "bambu-test", model: f.count > 3 ? f[3] : "", kind: .bambu, url: f[0])
            p.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
            p.serial = f[1]
            p.apiKey = f[2]
            Task { @MainActor in
                var out: UnsafeMutablePointer<UInt8>?
                var len = 0
                _ = data.withUnsafeBytes { zs_bambu_file($0.bindMemory(to: UInt8.self).baseAddress, $0.count, "test", &out, &len) }
                let bytes = out.map { Data(bytes: $0, count: len) } ?? Data()
                if let out { zs_buffer_free(out, len) }
                var pinned: String?
                do {
                    try await BambuLink.upload(p, name: "test.gcode.3mf", data: bytes, pinned: &pinned)
                    NSLog("zslice bambu: uploaded %d bytes, pinned %@", bytes.count, pinned ?? "no")
                    try await BambuLink.start(p, file: "test.gcode.3mf", title: "test", gcode: data, pinned: &pinned)
                    NSLog("zslice bambu: started")
                } catch {
                    NSLog("zslice bambu: error %@", error.localizedDescription)
                }
                let st = await PrinterLink.status(p)
                NSLog("zslice bambu: status %@", st?.line ?? "none")
                let t = await PrinterLink.test(p)
                NSLog("zslice bambu: test %@", t.message)
                p.apiKey = "wrong"
                let bad = await PrinterLink.test(p)
                NSLog("zslice bambu: wrong code: %@", bad.message)
                p.apiKey = ""
            }
        }
        // ZSLICE_FARM="url;bambu:address:serial:code" adds printers (in a
        // fresh run only), for the Printers page.
        if let farm = env["ZSLICE_FARM"], env["ZSLICE_FRESH"] != nil, PrinterStore.shared.printers.isEmpty {
            for (i, item) in farm.split(separator: ";").map(String.init).enumerated() {
                let f = item.split(separator: ":", maxSplits: 3).map(String.init)
                if f.first == "bambu", f.count == 4 {
                    var p = Printer(name: "Bambu \(i + 1)", model: "bambu-lab-p1s", kind: .bambu, url: f[1])
                    p.serial = f[2]
                    p.apiKey = f[3]
                    PrinterStore.shared.add(p)
                } else {
                    PrinterStore.shared.add(Printer(name: "Printer \(i + 1)", kind: .printdeck, url: item))
                }
            }
        }
        // ZSLICE_EDIT=kind edits the selected line (0: do not print it);
        // ZSLICE_EDIT_UNDO=1 undoes it 3 s later. The edits log after each slice.
        if let k = env["ZSLICE_EDIT"].flatMap(Int32.init), selection != nil {
            editLine(kind: k, value: 0.9)
            if env["ZSLICE_EDIT_UNDO"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.model.history.undoManager.undo() }
            }
        }
        // ZSLICE_POPULAR=1 logs the popular printers of the picker.
        if env["ZSLICE_POPULAR"] != nil {
            let lib = PrinterLibrary.shared
            NSLog("zslice popular: %@", lib.popular.compactMap { lib.model($0).map { coreText($0.title) } }.joined(separator: "; "))
        }
        // ZSLICE_INCHES=1 presses "Inches (×25.4)" of the print card.
        if env["ZSLICE_INCHES"] != nil { scaleParts(tinyParts.map(\.index), by: 25.4) }
        // ZSLICE_ASSIGN="plate:printer;..." assigns plates (0-based) to the
        // printers of the store (0-based), after a project loads.
        if let spec = env["ZSLICE_ASSIGN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                for pair in spec.split(separator: ";") {
                    let f = pair.split(separator: ":").compactMap { Int($0) }
                    let list = PrinterStore.shared.printers
                    if f.count == 2, f[1] < list.count { assign(plate: f[0], to: list[f[1]]) }
                }
                // ZSLICE_SAVE_AFTER=path saves the project after the assignments.
                if let path = env["ZSLICE_SAVE_AFTER"], let data = model.projectFileData(name: model.name) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // ZSLICE_FLEET=path adds the printers of a fleet file (the farm
        // simulator writes one).
        if let f = env["ZSLICE_FLEET"] { FarmMonitor.shared.addFleet(URL(fileURLWithPath: f)) }
        // ZSLICE_QUEUE=1 puts all plates in the queue of the farm, 4 s later
        // (after the slices).
        if env["ZSLICE_QUEUE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                let n = FarmMonitor.shared.queue(self, plates: Array(model.plates.indices), customer: "test")
                NSLog("zslice queue: %d jobs, %d proposals", n, FarmMonitor.shared.proposals.count)
                Task { @MainActor in
                    await FarmMonitor.shared.refresh()
                    // ZSLICE_QUEUE_SEND=1 (tests only): sends each proposal
                    // with no question, as if the user pressed Send.
                    guard env["ZSLICE_QUEUE_SEND"] != nil else { return }
                    let m = FarmMonitor.shared
                    for s in m.proposals {
                        guard let p = m.printer(at: s.printer), let ref = m.plate(of: s.job),
                              let i = ref.workspace.model.plates.firstIndex(where: { $0.id == ref.plate }),
                              let data = ref.workspace.model.gcode(plate: i) else { continue }
                        let r = await transfer(data, title: model.gcodeName(plate: i), to: p, print: true)
                        if r.ok { m.sent(job: s.job, to: p) }
                        NSLog("zslice queue: sent job %u to %@: %@", s.job, p.name, r.message)
                    }
                }
            }
        }
        if env["ZSLICE_ORBIT_TEST"] != nil {
            // ZSLICE_ORBIT_TEST=n: n zoom steps first (any other value: 14).
            let n = Int(env["ZSLICE_ORBIT_TEST"] ?? "") ?? 14
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.canvas.orbitTest(zoomSteps: n) }
        }
        // ZSLICE_HOVER_SCAN=1: the Support tool, a hover over a grid of the
        // view (a pick at each place), and a click on the first overhang.
        if env["ZSLICE_HOVER_SCAN"] != nil {
            setTool(.support)
            var hits = 0, first: CGPoint?
            let t = CACurrentMediaTime()
            var n = 0
            for gy in stride(from: 0.15, through: 0.85, by: 0.05) {
                for gx in stride(from: 0.15, through: 0.85, by: 0.05) {
                    let p = CGPoint(x: canvas.bounds.width * gx, y: canvas.bounds.height * gy)
                    hoverAt = p
                    hoverDue = false
                    supportHover(at: p)
                    hoverDue = false
                    hoverAt = p
                    n += 1
                    // The pick at once, as the next main loop turn would.
                    pickOverhangForTest()
                    if supportHover != nil {
                        hits += 1
                        if first == nil { first = p }
                    }
                }
            }
            NSLog("zslice hover scan: %d places, %d over an overhang, %.2f ms each", n, hits, (CACurrentMediaTime() - t) * 1000 / Double(max(n, 1)))
            if let p = first {
                hoverAt = p
                pickOverhangForTest()
                let before = zs_app_support_area_count(model.core)
                supportClick(p, snap: true)
                NSLog("zslice hover scan: click at %.0f,%.0f, areas %ld -> %ld", p.x, p.y, before, zs_app_support_area_count(model.core))
            }
        }
        // ZSLICE_RESLICE=1 changes the infill 3 times, one change after each
        // slice, and logs the longest wait of the main thread (with
        // ZSLICE_TIMING, the time of each slice).
        if env["ZSLICE_RESLICE"] != nil {
            Task { @MainActor in
                var worst = 0.0
                var last = CACurrentMediaTime()
                let watch = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
                    let now = CACurrentMediaTime()
                    worst = max(worst, now - last)
                    last = now
                }
                // ZSLICE_RESLICE=name=a,b,c changes that setting instead.
                var name = "project.infill_density"
                var values = ["0.3", "0.15", "0.25"]
                if let spec = env["ZSLICE_RESLICE"], spec.contains("=") {
                    let kv = spec.split(separator: "=", maxSplits: 1).map(String.init)
                    name = kv[0]
                    values = kv[1].split(separator: ",").map(String.init)
                }
                for d in values {
                    try? await Task.sleep(for: .seconds(1.5))
                    zs_app_setting_set(model.core, name, d)
                    model.settingsChanged()
                }
                try? await Task.sleep(for: .seconds(3))
                watch.invalidate()
                NSLog("zslice reslice: longest main thread wait %.0f ms", worst * 1000)
            }
        }
        // ZSLICE_PAGE_FLIP=dir: a turn, then 2D and back to 3D, then a turn;
        // writes a.png (before the flip), b.png (after it), and c.png (after
        // the second turn) there. The camera must not move with the page.
        if let dir = env["ZSLICE_PAGE_FLIP"], let v = canvas.view {
            Task { @MainActor in
                func shot(_ name: String) async {
                    guard let img = await canvas.captureWindow(),
                          let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir).appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) else { return }
                    CGImageDestinationAddImage(d, img, nil)
                    CGImageDestinationFinalize(d)
                }
                zs_view_orbit(v, 120, 40)
                await shot("a.png")
                page = .twoD
                try? await Task.sleep(for: .seconds(1))
                page = .threeD
                try? await Task.sleep(for: .seconds(1))
                await shot("b.png")
                zs_view_orbit(v, 120, 0)
                await shot("c.png")
                NSLog("zslice flip: done")
            }
        }
        // ZSLICE_TURN_KEYS=n: the Turn tool, n presses of the Up arrow on the
        // selected part (15° each about X), then the part 1 s later.
        if let n = env["ZSLICE_TURN_KEYS"].flatMap(Int.init), let i = selectedPart {
            setTool(.turn)
            selectPart(i)
            for _ in 0 ..< n {
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                            characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                                            isARepeat: false, keyCode: 126) {
                    _ = sliceViewKey(e)
                }
            }
            // ZSLICE_DESELECT=1: a click elsewhere at once (the settle must
            // still come).
            if env["ZSLICE_DESELECT"] != nil { setTool(.select) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                var p = zs_part()
                _ = zs_app_part_get(self.model.core, i, &p)
                NSLog("zslice turn keys: support %@, size z %.1f, note %@", self.model.setting("project.support"), p.size_z, self.note ?? "none")
            }
        }
        // ZSLICE_RING=axis,deg: the Turn tool, a press on that ring of the
        // selected part, a drag around the part until the turn is deg, and
        // a release (as a user does); the part 3 s later.
        if let spec = env["ZSLICE_RING"]?.split(separator: ",").compactMap({ Double($0) }), spec.count == 2, let i = selectedPart, let v = canvas.view {
            setTool(.turn)
            selectPart(i)
            canvas.requestFrame()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                let s = self.canvas.window?.backingScaleFactor ?? 2
                var start: CGPoint?
                outer: for gy in stride(from: 0.05, through: 0.95, by: 0.01) {
                    for gx in stride(from: 0.05, through: 0.95, by: 0.01) {
                        let p = CGPoint(x: self.canvas.bounds.width * gx, y: self.canvas.bounds.height * gy)
                        if zs_view_ring_at(v, Float(p.x * s), Float(p.y * s), Float(4 * s)) == Int32(spec[0]) { start = p; break outer }
                    }
                }
                var info = zs_part()
                _ = zs_app_part_get(self.model.core, i, &info)
                guard let p0 = start, self.press(p0, []),
                      let c = self.canvas.viewPoint(x: info.x, y: info.y, z: info.size_z / 2) else {
                    NSLog("zslice ring: no ring %.0f found", spec[0])
                    return
                }
                // Around the center on the screen, in small steps.
                let r = hypot(p0.x - c.x, p0.y - c.y), a0 = atan2(p0.y - c.y, p0.x - c.x)
                var p = p0
                for k in 1 ... 360 {
                    let a = a0 + Double(k) * .pi / 180 * (spec[1] >= 0 ? 1 : -1)
                    p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    self.drag(p, [])
                    if let rd = self.ringDrag, abs(rd.sent) >= abs(spec[1]) { break }
                }
                NSLog("zslice ring: axis %.0f, turned %.0f°", spec[0], self.ringDrag?.sent ?? 0)
                self.release(p)
                try? await Task.sleep(for: .seconds(3))
                _ = zs_app_part_get(self.model.core, i, &info)
                NSLog("zslice ring: after, size z %.1f, note %@", info.size_z, self.note ?? "none")
            }
        }
        // ZSLICE_TURN=deg turns the selected part about X, then lets it settle
        // and logs the note; ZSLICE_SUPPORT=1 turns support on first.
        // ZSLICE_KEYS=chars: each key in turn, as typed in the view, and the
        // tool after it (the tool keys must win over the keys of a line).
        if let keys = env["ZSLICE_KEYS"] {
            var log: [String] = []
            for ch in keys {
                let s = String(ch)
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                            characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                    _ = sliceViewKey(e)
                }
                log.append("\(s)→\(tool.rawValue)")
            }
            NSLog("zslice keys: selection %d, %@", selection == nil ? 0 : 1, log.joined(separator: " "))
        }
        // ZSLICE_GRAB=1: the Grab tool, a press on the part at the center,
        // a drag of 200 points to the right in 0.5 s, and a release; the
        // part 3 s later.
        if env["ZSLICE_TREE_TEST"] != nil { runTreeTest() }
        if env["ZSLICE_GRAB"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self.setTool(.grab)
                let c = CGPoint(x: self.canvas.bounds.midX, y: self.canvas.bounds.midY)
                var before = zs_part()
                _ = zs_app_part_get(self.model.core, 0, &before)
                // A click takes the part; the pointer carries it with no
                // button; a second click lets go.
                let took = self.press(c, [])
                self.release(c)
                NSLog("zslice grab: took %d, holding %d after the click", took ? 1 : 0, self.grabbing ? 1 : 0)
                var p = c
                for k in 1 ... 30 {
                    p = CGPoint(x: c.x + Double(k) * 200 / 30, y: c.y)
                    self.sliceViewHover(p)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                _ = self.press(p, [])
                self.release(p)
                NSLog("zslice grab: let go, holding %d", self.grabbing ? 1 : 0)
                try? await Task.sleep(for: .seconds(3))
                var after = zs_part()
                _ = zs_app_part_get(self.model.core, 0, &after)
                NSLog("zslice grab: x %.1f -> %.1f, y %.1f -> %.1f, size z %.1f -> %.1f, falling %d", before.x, after.x, before.y, after.y, before.size_z, after.size_z, self.falling == nil ? 0 : 1)
            }
        }
        // ZSLICE_SUPPORT_OFF_AFTER=s turns support off s seconds later, as
        // the settings do (a part that support held must fall then).
        if let s = env["ZSLICE_SUPPORT_OFF_AFTER"].flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(s))
                self.model.set("project.support", "off")
                NSLog("zslice support off: set")
                try? await Task.sleep(for: .seconds(2.5))
                var p = zs_part()
                _ = zs_app_part_get(self.model.core, 0, &p)
                NSLog("zslice support off: size z %.1f, note %@", p.size_z, self.note ?? "none")
            }
        }
        if let t = env["ZSLICE_TURN"].flatMap(Double.init), let i = selectedPart {
            if env["ZSLICE_SUPPORT"] != nil { zs_app_setting_set(model.core, "project.support", "everywhere") }
            zs_app_part_turn(model.core, i, 0, t)
            NSLog("zslice settle: support %@, stands %d", model.setting("project.support"), zs_app_part_stands(model.core, i))
            settle()
            NSLog("zslice settle: %@", note ?? "no note")
            selectPart(i)
            model.settingsChanged()
        }
        // ZSLICE_SIGN_TEST=1 signs the G-code of the plate, and checks it,
        // and checks a copy with one byte changed.
        if env["ZSLICE_SIGN_TEST"] != nil, let g = model.gcode(), let pk = Signer.publicKey {
            let signed = Signer.sign(g)
            func verify(_ d: Data) -> (Int32, String) {
                var result: Int32 = -1
                var id = [CChar](repeating: 0, count: 17)
                _ = d.withUnsafeBytes { zs_verify_gcode($0.bindMemory(to: UInt8.self).baseAddress, $0.count, pk, &result, &id) }
                return (result, id.withUnsafeBufferPointer { coreText($0.baseAddress) })
            }
            var bad = signed
            bad[bad.count / 2] ^= 1
            let last = String(decoding: signed.suffix(120), as: UTF8.self).split(separator: "\n").last ?? ""
            NSLog("zslice sign: key %@; last line %@; good %d (%@); changed %d", Signer.keyID, String(last.prefix(60)), verify(signed).0, verify(signed).1, verify(bad).0)
        }
        // ZSLICE_DECK_JSON=path logs the printers that a printer.json of a
        // printdeck gives (Discovery.deckPrinters).
        if let path = env["ZSLICE_DECK_JSON"], let d = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let f = FoundPrinter(name: "Deck", kind: Int32(ZS_FOUND_PRINTDECK.rawValue), kindTitle: "printdeck", url: "http://deck.local",
                                 model: "", bedX: 0, bedY: 0, height: 0)
            let list = Discovery.deckPrinters(f, json: d) ?? [f]
            NSLog("zslice deck: %@", list.map { "\($0.name) \($0.url) \($0.color)" }.joined(separator: "; "))
        }
        // ZSLICE_PICKER=1 opens the printer picker.
        if env["ZSLICE_PICKER"] != nil { pickerOpen = true }
        // ZSLICE_RECORD=path.mov records the demo of Recorder.swift.
        if let path = env["ZSLICE_RECORD"] {
            Task { @MainActor in await Recorder.record(self, to: URL(fileURLWithPath: path)) }
        }
        // ZSLICE_ADD_PLATE="path;path": each file on a new plate.
        for path in (env["ZSLICE_ADD_PLATE"] ?? "").split(separator: ";") {
            model.addPlate()
            if let data = FileManager.default.contents(atPath: String(path)) {
                try? model.load(name: (String(path) as NSString).lastPathComponent, data: data)
            }
        }
        if env["ZSLICE_ADD_PLATE"] != nil { framePlate(-1) }
        // ZSLICE_PROJECT=folder opens a project.
        if let p = env["ZSLICE_PROJECT"] {
            if p.hasPrefix("/") { openProject(URL(fileURLWithPath: p)) } else { openGitHub(p) }
        }
        // ZSLICE_MENU="x,y;Title" runs an item of the context menu there.
        if let spec = env["ZSLICE_MENU"]?.split(separator: ";"), spec.count == 2 {
            // "center": the middle of the view.
            let mid = [Double(canvas.bounds.midX), Double(canvas.bounds.midY)]
            let xy = spec[0] == "center" ? mid : spec[0].split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 {
                let menu = contextMenu(at: CGPoint(x: xy[0], y: xy[1]))
                let all = menu.items + menu.items.flatMap { $0.submenu?.items ?? [] }
                if let item = all.first(where: { $0.title == spec[1] }) as? ClosureItem {
                    _ = item.target?.perform(item.action)
                }
            }
        }
        // ZSLICE_PICK=x,y picks the line at that point of the view (points),
        // as a click does (as in the GTK app).
        if let xy = env["ZSLICE_PICK"]?.split(separator: ",").compactMap({ Double($0) }), xy.count == 2 {
            pick(at: CGPoint(x: xy[0], y: xy[1]))
        }
        // ZSLICE_LINE_PAGE=1 opens the page of the picked line.
        if env["ZSLICE_LINE_PAGE"] != nil, selection != nil { showLineSettings() }
        // ZSLICE_DOUBLE_CLICK=x,y: a double click there (as in the GTK app).
        if let xy = env["ZSLICE_DOUBLE_CLICK"]?.split(separator: ",").compactMap({ Double($0) }), xy.count == 2, let v = canvas.view {
            if !lookAtSide(CGPoint(x: xy[0], y: xy[1])) { zs_view_reset_smooth(v) }
            canvas.startAnimation()
        }
        if let t = env["ZSLICE_TIME"].flatMap(Double.init), let v = canvas.view {
            time = t
            zs_view_set_time(v, t)
            hi = Int(zs_view_layer_at_time(v, t))
            lo = min(lo, hi)
            canvas.layer2D = hi
            canvas.requestFrame()
        }
    }

    // MARK: - the plates

    /// The other plates of the set in the row of the view.
    func syncPlates() {
        guard let v = canvas.view else { return }
        zs_set_view_sync(model.set, v)
        // A plate with no parts (Clear the Plate): no layers, and the
        // controls of the layers go.
        if model.state == .empty, layerCount > 0 {
            stopReplay()
            clearSelection()
            layerCount = 0
            lo = 0
            hi = 0
            layerZ = []
            layerEnd = []
            layerSlowed = []
            canvas.load(model.core)
            readLegend()
        }
        canvas.requestFrame()
    }

    /// Another plate became active: the selection and the tools are of the
    /// plate that was active.
    private func activePlateChanged() {
        // The printer menu of the toolbar shows the printer of this plate.
        if let p = assigned(plate: model.active) { PrinterStore.shared.currentID = p.id }
        stopReplay()
        clearSelection()
        selectPart(nil)
        clearTape()
        gapCard = nil
        if model.state != .done, let v = canvas.view {
            // No slice yet: the view shows the row, and this plate empty.
            zs_view_load(v, model.core)
            canvas.requestFrame()
        }
        if !restoring { framePlate(model.active) }
    }

    /// Moves the camera to plate i (-1: all plates).
    func framePlate(_ i: Int) {
        guard let v = canvas.view else { return }
        zs_view_frame_plate(v, i < 0 ? -1 : i)
        canvas.startAnimation()
    }

    func selectPlate(_ i: Int) {
        if i == model.active { framePlate(i) } else { model.select(i) }
    }

    /// Asks before it removes a plate with parts (the plates are not in the
    /// undo list).
    func removePlate(_ i: Int) {
        guard model.plates.indices.contains(i) else { return }
        if model.plates[i].parts > 0 {
            let a = NSAlert()
            a.messageText = "Remove \(model.plates[i].name.isEmpty ? "Plate \(i + 1)" : model.plates[i].name)?"
            a.informativeText = "The plate has \(model.plates[i].parts) part\(model.plates[i].parts == 1 ? "" : "s"). Undo cannot bring a removed plate back."
            a.addButton(withTitle: "Remove")
            a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        model.removePlate(i)
    }

    /// Opens the project of a folder (a repository with a printdeck.yml)
    /// with an open panel.
    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder of a project: a repository with a printdeck.yml."
        panel.prompt = "Open Project"
        let open = { [weak self] (r: NSApplication.ModalResponse) in
            guard let self, r == .OK, let url = panel.url else { return }
            openProject(url)
        }
        if let w = canvas.window { panel.beginSheetModal(for: w, completionHandler: open) } else { open(panel.runModal()) }
    }

    func openProject(_ url: URL) {
        openProject(FolderSource(url))
    }

    /// Opens a project from a folder or from GitHub. While it reads the
    /// files, the print card says so.
    func openProject(_ source: ProjectSource, counts: [Int?]? = nil) {
        sendState = "Opening \(source.label)…"
        Task { @MainActor in
            do {
                try await model.openProject(source, counts: counts)
                sendState = nil
                if counts == nil {
                    framePlate(-1)
                    // A note, not a sheet: the plates are what the user wants to see.
                    showNote("Opened \(model.name): \(model.plates.count) plates. File > Show Project lists its parts.", seconds: 6)
                }
            } catch {
                sendState = nil
                NSLog("zslice: the project did not open: %@", error.localizedDescription)
                let a = NSAlert()
                a.messageText = "The project did not open"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    /// Opens a public repository on GitHub (owner/repo, or its address).
    func openGitHub(_ text: String) {
        sendState = "Reading \(text) on GitHub…"
        Task { @MainActor in
            do {
                openProject(try await GitHubSource.open(text))
            } catch {
                sendState = nil
                let a = NSAlert()
                a.messageText = "The project did not open"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    /// Asks for owner/repo, and opens it.
    func askGitHub() {
        let a = NSAlert()
        a.messageText = "Open a Project from GitHub"
        a.informativeText = "Type owner/repo, or the address of a public repository on github.com. An address with /tree/<branch> opens that branch."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "beetlebugorg/bittlex"
        a.accessoryView = field
        a.addButton(withTitle: "Open")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { openGitHub(field.stringValue) }
    }

    /// Adds a model file to the active plate.
    func addModel(_ url: URL) {
        do {
            try model.add(name: url.lastPathComponent, data: Data(contentsOf: url))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Adds models to the active plate with an open panel.
    func addModels() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.stl, .threeMF]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the models to add to the plate."
        let add = { [weak self] (r: NSApplication.ModalResponse) in
            guard let self, r == .OK else { return }
            for url in panel.urls {
                do {
                    try model.add(name: url.lastPathComponent, data: Data(contentsOf: url))
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
        if let w = canvas.window { panel.beginSheetModal(for: w, completionHandler: add) } else { add(panel.runModal()) }
    }

    // MARK: - the layer range

    /// Sets the layers that show: lo to hi.
    func setRange(lo newLo: Int, hi newHi: Int) {
        let top = max(0, layerCount - 1)
        hi = min(top, max(0, newHi))
        lo = min(hi, max(0, newLo))
        stopReplay()
        time = nil
        applyRange()
    }

    /// Moves the top knob by `step` layers (the bottom knob follows down).
    func moveTop(_ step: Int) { setRange(lo: min(lo, hi + step), hi: hi + step) }

    /// Moves the bottom knob by `step` layers (the top knob follows up).
    func moveBottom(_ step: Int) { setRange(lo: lo + step, hi: max(hi, lo + step)) }

    private func applyRange() {
        guard let v = canvas.view else { return }
        zs_view_set_layer_range(v, lo, hi)
        if gapsOn { showGaps() }
        canvas.layer2D = hi
        canvas.dim2D = focusMask != 0 && focusFirst && hi > 0
        canvas.requestFrame()
    }

    func z(of layer: Int) -> Float { layer < layerZ.count ? layerZ[layer] : 0 }
    func isSlowed(_ layer: Int) -> Bool { layer < layerSlowed.count && layerSlowed[layer] }

    // MARK: - the replay

    /// The start and end time of a layer, in seconds from the start.
    func layerTimes(_ l: Int) -> (Double, Double) {
        guard l < layerEnd.count else { return (0, 0) }
        return (l > 0 ? layerEnd[l - 1] : 0, layerEnd[l])
    }

    /// Where the scrub bar is in the top layer: 0 at its start, 1 at its end.
    var scrubFraction: Double {
        let (t0, t1) = layerTimes(hi)
        guard let time, t1 > t0 else { return 1 }
        return min(1, max(0, (time - t0) / (t1 - t0)))
    }

    /// A drag of the scrub bar: the nozzle at fraction f of the top layer.
    func scrub(to f: Double) {
        stopReplay()
        guard let v = canvas.view else { return }
        page = .threeD
        let (t0, t1) = layerTimes(hi)
        if f >= 1 {
            time = nil
            zs_view_set_layer_range(v, lo, hi)
        } else {
            time = t0 + f * (t1 - t0)
            zs_view_set_time(v, time!)
        }
        canvas.requestFrame()
    }

    func togglePlay() { playing ? stopReplay() : startReplay() }

    func startReplay() {
        guard let v = canvas.view, layerCount > 0 else { return }
        page = .threeD
        let d = zs_view_duration(v)
        var t = time ?? 0
        if t <= 0 || t >= d { t = 0 }
        // After a move of the slider: from the start of the top layer.
        if t <= 0 && hi + 1 < layerCount { t = layerTimes(hi).0 }
        time = t
        playing = true
        canvas.startTicking()
    }

    func stopReplay() {
        playing = false
    }

    private func stepReplay(_ dt: Double) -> Bool {
        guard playing, let v = canvas.view, var t = time else { return false }
        let d = zs_view_duration(v)
        t += dt * speed
        if t >= d {
            playing = false
            time = nil
            hi = max(0, layerCount - 1)
            applyRange()
            return false
        }
        time = t
        zs_view_set_time(v, t)
        let layer = Int(zs_view_layer_at_time(v, t))
        hi = layer
        lo = min(lo, layer)
        canvas.layer2D = layer
        return true
    }

    // MARK: - the settings drawer

    /// The drawer shows. The app keeps the choice for the next window.
    var showSettings = UserDefaults.standard.bool(forKey: "panel") {
        didSet {
            UserDefaults.standard.set(showSettings, forKey: "panel")
            if !showSettings { focus(0, firstLayer: false) }
        }
    }


    /// The pages of the settings browser that show, from its first page.
    var settingsPath: [SettingsRoute] = []

    /// Opens the drawer on all settings of the selected line. The card
    /// closes: the pane has the same facts, and the line stays selected.
    /// The pane shows the page of the selected line.
    var lineInPane: Bool {
        guard showSettings, let last = settingsPath.last, case .line = last else { return false }
        return true
    }

    /// The × or Esc of the card: with the line in the pane, only the card
    /// closes; else the selection goes too.
    func closeCard() {
        if lineInPane { cardOpen = false } else { clearSelection() }
    }

    func showLineSettings() {
        showSettings = true
        settingsPath = [.line]
        cardOpen = false
    }

    /// The right pane has only the settings. The history is a popover of
    /// the timeline, the project a sheet, and the printers a page over the
    /// view. ZSLICE_PAGE=history, project, or printers opens one, for tests.
    var historyOpen = ProcessInfo.processInfo.environment["ZSLICE_PAGE"] == "history"
    var projectOpen = ProcessInfo.processInfo.environment["ZSLICE_PAGE"] == "project"
    var farmOpen = ProcessInfo.processInfo.environment["ZSLICE_PAGE"] == "printers"
    /// The plates sent from the Printers page in this session, by plate id:
    /// "sent to Workhorse at 06:41".
    var sentPlates: [UInt64: String] = [:]
    /// Counts the changes of the printers of the plates, which the core
    /// keeps (zs_set_plate_printer), so the views read them again.
    private(set) var assignGeneration = 0
    /// The plate that each printer prints (printer id to plate id): the
    /// last plate sent to it in this session.
    var printing: [UUID: UInt64] = [:]

    // MARK: - the colors and the line types

    /// The colors of the view (enum zs_view_mode): the filament, one color
    /// for each line type, or a ramp of a value. The app keeps the choice.
    static let colorModes = ["Filament", "Line Type", "Speed", "Flow", "Layer Time", "Line Width"]
    static let legendUnits = ["", "", "mm/s", "mm³/s", "s", "mm"]

    var colorMode = UserDefaults.standard.integer(forKey: "mode") {
        didSet {
            UserDefaults.standard.set(colorMode, forKey: "mode")
            applyMode()
        }
    }

    /// The range of the ramp of a value mode, after a load.
    private(set) var legend: (lo: Double, hi: Double)?

    /// The line types that show (a bit for each feature and mark; 0: all
    /// in their colors). The others fade to ghosts.
    var shownTypes: UInt32 = 0 {
        didSet { applyFocus() }
    }

    func toggleType(_ f: Int) {
        let bit = UInt32(1) << UInt32(f)
        var m = shownTypes == 0 ? Feature.all : shownTypes
        m ^= bit
        shownTypes = m == Feature.all || m == 0 ? 0 : m
    }

    /// Sets the color mode of the view, and loads the slice again (the
    /// colors come with the data).
    private func applyMode() {
        guard let v = canvas.view else { return }
        zs_view_set_mode(v, Int32(colorMode))
        if model.state == .done {
            canvas.load(model.core)
            applyRange()
            applyFocus()
            showSelection()
        }
        readLegend()
    }

    private func readLegend() {
        var lo = 0.0, hi = 0.0
        if let v = canvas.view, colorMode >= 2, zs_view_legend(v, &lo, &hi) != 0 { legend = (lo, hi) } else { legend = nil }
    }

    /// The lines that the drawer points at: a bit for each feature and mark
    /// (0: all lines, in their colors). firstLayer: only the lines of the
    /// first layer.
    @ObservationIgnored private var focusMask: UInt32 = 0
    /// The focus that the last "no lines" note was for, so it shows once.
    @ObservationIgnored private var notedMask: UInt32 = 0

    /// A short note at the top of the view, which goes after a few seconds.
    private(set) var note: String?
    /// A long action runs on the main thread: the note shows a spinner.
    var busy = false
    @ObservationIgnored private var noteTask: Task<Void, Never>?

    func showNote(_ text: String, seconds: Double = 4) {
        note = text
        noteTask?.cancel()
        noteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.note = nil }
        }
    }
    @ObservationIgnored private var focusFirst = false

    /// The search: open, and the setting whose eye is on (its lines show,
    /// the others fade, while the search is open).
    /// The sheet of the keyboard shortcuts shows.
    var shortcutsOpen = false

    var searchOpen = false {
        didSet { if !searchOpen { searchEye = nil } }
    }
    var searchEye: String? {
        didSet {
            if let n = searchEye {
                let e = SettingEffect(n)
                focus(e.features, firstLayer: e.firstLayerOnly, always: true)
            } else {
                focus(0, firstLayer: false, always: true)
            }
        }
    }

    /// always: also with the drawer hidden (the eye of the search).
    func focus(_ mask: UInt32, firstLayer: Bool, always: Bool = false) {
        // A hidden drawer shows the whole print.
        let m = showSettings || always ? mask : 0
        focusMask = m
        focusFirst = firstLayer
        applyFocus()
    }

    func applyFocus() {
        guard let v = canvas.view else { return }
        var mask = focusMask != 0 ? focusMask : shownTypes
        // The Support tool: the support lines are faint, so the outlines of
        // the areas show through them.
        if tool == .support, supportSee, focusMask == 0 {
            mask = (mask == 0 ? Feature.all : mask) & ~Workspace.supportFeatures
        }
        let zmax = focusMask != 0 && focusFirst && !layerZ.isEmpty ? Double(layerZ[0]) : -1
        // 0: the plate has no line of those features; the view keeps the
        // whole print, and a note says why, once for each new focus.
        if zs_view_focus(v, mask, zmax) == 0, focusMask != 0 {
            if notedMask != focusMask {
                notedMask = focusMask
                showNote("No lines of this setting on this plate")
            }
        } else if focusMask == 0 {
            notedMask = 0
        }
        // In 2D, a focus on the first layer while the view shows another
        // layer: all lines are faint (web/app/view2d.js, dim).
        canvas.focus2D = mask
        canvas.dim2D = focusMask != 0 && focusFirst && hi > 0
        canvas.requestFrame()
    }

    /// Fits the part in the view: the 2D page fits the layer, and the 3D
    /// page moves the camera back to the start view.
    func fit() {
        if page == .twoD {
            canvas.fit2D()
        } else if let v = canvas.view {
            zs_view_reset_smooth(v)
            canvas.startAnimation()
        }
    }

    // MARK: - the printer

    /// Makes a printer of the user the printer of the active plate: its
    /// machine settings replace the machine settings of the plate.
    func usePrinter(_ p: Printer) {
        PrinterStore.shared.currentID = p.id
        setPlatePrinter(model.active, p)
        guard applyMachine(p, to: model.core) else { return }
        model.settingsChanged()
    }

    /// The machine profile of a printer on the app of a plate.
    @discardableResult
    private func applyMachine(_ p: Printer, to app: OpaquePointer) -> Bool {
        guard !p.machine.isEmpty else { return false }
        zs_app_group_reset(app, Int32(ZS_GROUP_MACHINE.rawValue))
        var message = [CChar](repeating: 0, count: 256)
        let rc = p.machine.withCString { zs_app_profile_apply(app, Int32(ZS_GROUP_MACHINE.rawValue), $0, strlen($0), &message, message.count) }
        if rc != 0 { NSLog("zslice: the printer %@ did not load: %@", p.name, message.withUnsafeBufferPointer { coreText($0.baseAddress) }) }
        return rc == 0
    }

    /// The printer of plate i in the core (its key: the id of the printer),
    /// kept in the project file.
    private func setPlatePrinter(_ i: Int, _ p: Printer?) {
        guard model.plates.indices.contains(i) else { return }
        zs_set_plate_printer(model.set, i, p?.id.uuidString)
        assignGeneration += 1
    }

    /// Plate i prints on printer p: the plate slices for it (its machine
    /// profile), and the Printers page sends it there.
    func assign(plate i: Int, to p: Printer) {
        guard model.plates.indices.contains(i) else { return }
        if i == model.active {
            usePrinter(p)
            return
        }
        setPlatePrinter(i, p)
        if let app = zs_set_app(model.set, i), applyMachine(p, to: app) { zs_set_changed(model.set, i) }
    }

    /// The printer that plate i prints on, if the user chose one.
    func assigned(plate i: Int) -> Printer? {
        _ = assignGeneration
        guard model.plates.indices.contains(i),
              let key = coreString({ zs_set_plate_printer_get(model.set, i, $0, $1, $2) }), let id = UUID(uuidString: key) else { return nil }
        return PrinterStore.shared.printers.first { $0.id == id }
    }


    /// The current printer with a connection, or nil.
    var connectedPrinter: Printer? {
        if let testPrinter { return testPrinter }
        guard let p = PrinterStore.shared.current, p.kind != .none else { return nil }
        return p
    }

    /// Asks the current printer for its status every 10 s while the window
    /// is open.
    func startStatus() {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let p = connectedPrinter {
                    let s = await PrinterLink.status(p)
                    if s != printerStatus { printerStatus = s }
                } else if printerStatus != nil {
                    printerStatus = nil
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// "Use the printer's bed, nozzle, and motion" (what 1) and "Use the
    /// filament in the printer" (what 2): the core applies the status of
    /// the printer to the settings of the plate (zs_app_apply_printer_status),
    /// as one step of the history, and the plate slices again.
    func applyPrinterStatus(_ what: Int32) {
        guard let p = connectedPrinter else { return }
        Task { @MainActor in
            guard let s = await PrinterLink.statusObject(p) else {
                let a = NSAlert()
                a.messageText = "The printer did not answer"
                a.informativeText = "Check its address and its API key (Settings > Printers)."
                a.runModal()
                return
            }
            defer { zs_printer_status_free(s) }
            if zs_app_apply_printer_status(model.core, s, what) == 0 { model.settingsChanged() }
        }
    }

    /// After a slice: the estimate of a printdeck for the G-code.
    private func askEstimate() {
        if let path = ProcessInfo.processInfo.environment["ZSLICE_GZIP"], let g = model.gcode(), let gz = Gzip.compress(g) {
            try? gz.write(to: URL(fileURLWithPath: path))
        }
        printerEstimate = nil
        guard let p = connectedPrinter, p.kind == .printdeck, let g = model.gcode() else { return }
        Task { @MainActor [weak self] in
            let e = await PrinterLink.estimate(p, gcode: g)
            self?.printerEstimate = e
        }
    }

    /// Sends the G-code to the current printer; print: start the print.
    func send(print: Bool) {
        guard let p = PrinterStore.shared.current, p.kind != .none, let data = model.gcode(), goOnOffBed() else { return }
        if p.kind == .bambu {
            sendBambu(p, gcode: data, print: print)
            return
        }
        // Before each print: is the bed clear? A printdeck starts at once
        // when it allows a start from the slicer; a deck set to ask waits.
        if print {
            let a = NSAlert()
            a.messageText = "Is the bed of \(p.name) clear?"
            a.informativeText = "The print starts when the file is there."
                + (p.kind == .printdeck ? " A deck set to ask waits for a press of Print on it." : "")
            a.addButton(withTitle: "The Bed Is Clear: Print")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let title = model.gcodeName()
        sendState = print ? "Sending to \(p.name)…" : "Uploading to \(p.name)…"
        Task { @MainActor in
            // transfer signs the G-code (Signing.swift).
            let r = await transfer(data, title: title, to: p, print: print)
            sendState = r.message
            if !r.ok {
                let a = NSAlert()
                a.messageText = print ? "The print did not start" : "The upload failed"
                a.informativeText = r.message
                a.runModal()
            }
        }
    }

    /// A Bambu printer: the .gcode.3mf over FTPS, then the start over MQTT
    /// (Bambu.swift). A print starts only after the user says, each time,
    /// that the plate is clear.
    private func sendBambu(_ p: Printer, gcode: Data, print: Bool) {
        if print {
            let a = NSAlert()
            a.messageText = "Is the plate of \(p.name) clear?"
            a.informativeText = "The printer starts at once, and its nozzle and bed move into anything on the plate. (Bambu support is untested with a real printer.)"
            a.addButton(withTitle: "The Plate Is Clear: Print")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let title = model.gcodeName()
        sendState = "Uploading to \(p.name)…"
        Task { @MainActor in
            let r = await transfer(gcode, title: title, to: p, print: print)
            sendState = r.message
            if !r.ok {
                let a = NSAlert()
                a.messageText = print ? "The print did not start" : "The upload failed"
                a.informativeText = r.message
                a.runModal()
            }
        }
    }

    /// Sends G-code to a printer of any kind, and starts it with `print`.
    /// The caller asked the user that the plate is clear.
    func transfer(_ unsigned: Data, title: String, to p: Printer, print: Bool) async -> LinkResult {
        // Each print that leaves the app is signed (Signing.swift).
        let gcode = Signer.sign(unsigned)
        guard p.kind == .bambu else {
            return await PrinterLink.send(p, filename: title + ".gcode", gcode: gcode, print: print)
        }
        let file = title.replacingOccurrences(of: " ", with: "_") + ".gcode.3mf"
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard gcode.withUnsafeBytes({ zs_bambu_file($0.bindMemory(to: UInt8.self).baseAddress, $0.count, title, &out, &len) }) == 0, let out else {
            return LinkResult(ok: false, message: "The file for the printer did not build.")
        }
        let bytes = Data(bytes: out, count: len)
        zs_buffer_free(out, len)
        var pinned: String?
        do {
            try await BambuLink.upload(p, name: file, data: bytes, pinned: &pinned)
            if print { try await BambuLink.start(p, file: file, title: title, gcode: gcode, pinned: &pinned) }
            if let pinned { showNote("zslice trusts the certificate of \(p.name) from now on (SHA-256 \(pinned.prefix(11))…)", seconds: 8) }
            return LinkResult(ok: true, message: (print ? "Printing on \(p.name)" : "Uploaded to \(p.name)") + ". Not verified: Bambu printers do not check signatures.")
        } catch {
            return LinkResult(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - the G-code

    /// A test print: the G-code of layers lo to hi - 1 alone, lowered to
    /// the bed, with the start and end G-code (zs_app_debug_gcode), to a
    /// file. It checks a few layers before a long print.
    func saveTestPrint(lo: Int, hi: Int) {
        guard hi > lo else { return }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard zs_app_debug_gcode(model.core, lo, hi, &out, &len) == 0, let out else {
            showNote("The test print did not work")
            return
        }
        let data = Signer.sign(Data(bytes: out, count: len))
        zs_buffer_free(out, len)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gcode]
        panel.nameFieldStringValue = hi == lo + 1 ? "test-layer-\(lo + 1).gcode" : "test-layers-\(lo + 1)-\(hi).gcode"
        panel.message = hi == lo + 1 ? "Layer \(lo + 1) alone, on the bed." : "Layers \(lo + 1) to \(hi) alone, lowered to the bed."
        let write = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
        if let w = canvas.window { panel.beginSheetModal(for: w, completionHandler: write) } else { write(panel.runModal()) }
    }

    /// An edit of the selected line (zs_app_edit_add): kind 0, the line
    /// does not print; kind 1, `value` times its plastic. The core keeps
    /// the edit with the plate and makes a step of the history; the plate
    /// slices again.
    func editLine(kind: Int32, value: Double = 1) {
        // By the key of the line, read when it was selected: it works while
        // a new slice runs.
        guard let s = selection, s.key != 0, s.layer >= 0 else { return }
        let rc = zs_app_edit_add_key(model.core, s.key, s.layer, kind, value)
        guard rc == 0 else {
            showNote("The edit did not work. \(statusText(rc))")
            return
        }
        if kind == 0 { clearSelection() }
        editsChanged(kind == 0 ? "The line does not print now." : (value < 1 ? "The line has \(Int(((1 - value) * 100).rounded())) % less plastic now." : "The line has \(Int(((value - 1) * 100).rounded())) % more plastic now."))
    }

    /// After the core added or removed an edit: it made the step of the
    /// history, so the undo actions follow; the plate slices again.
    func editsChanged(_ what: String) {
        model.history.commit()
        model.history.attach()
        model.settingsGeneration += 1
        model.requestSlice()
        let n = zs_app_edit_count(model.core)
        showNote("\(what) \(n) edit\(n == 1 ? "" : "s") on this plate; undo with ⌘Z.", seconds: 6)
    }

    /// The edits of the plate, for the History page.
    struct LineEdit: Identifiable {
        var id: Int
        var text: String
        var waits: Bool
    }

    var lineEdits: [LineEdit] {
        _ = model.settingsGeneration
        _ = model.history.generation
        _ = layerCount
        return (0 ..< zs_app_edit_count(model.core)).map { i in
            var kind: Int32 = 0, value = 0.0, layer = 0, applied: Int32 = 0
            zs_app_edit_get(model.core, i, &kind, &value, &layer, &applied)
            let what = switch kind {
            case 0: "does not print"
            case 1: "\(Int((value * 100).rounded())) % plastic"
            default: String(format: "a drop of %.1f mm", value)
            }
            return LineEdit(id: i, text: "Layer \(layer + 1): \(what)", waits: applied == 0)
        }
    }

    func removeEdit(_ i: Int) {
        guard zs_app_edit_remove(model.core, i) == 0 else { return }
        editsChanged("The edit is gone.")
    }

    /// Exports the G-code of the last slice with a save panel.
    func exportGcode(from window: NSWindow?) {
        guard let unsigned = model.gcode(), goOnOffBed() else { return }
        let data = Signer.sign(unsigned)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gcode]
        panel.nameFieldStringValue = model.gcodeName() + ".gcode"
        let write = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }
}

extension Workspace: SliceViewDelegate {
    func sliceViewClick(_ p: CGPoint) {
        if model.plates.count > 1, page == .threeD, let v = canvas.view {
            let s = canvas.window?.backingScaleFactor ?? 2
            let i = zs_view_plate_at(v, Float(p.x * s), Float(p.y * s))
            if i >= 0 && Int(i) != model.active {
                model.select(Int(i))
                return
            }
        }
        if gapsOn && pickGap(at: p) { return }
        switch tool {
        case .measure:
            measureClick(p, snap: !NSEvent.modifierFlags.contains(.shift))
        case .support:
            supportClick(p, snap: !NSEvent.modifierFlags.contains(.shift))
        case .turn, .move:
            // A click on a part selects it; a click on a line selects it too.
            if let i = partAt(p) { selectPart(i) } else { selectPart(nil); pick(at: p) }
        case .select:
            pick(at: p)
        case .grab:
            // A press on a part takes it (press); a click off the parts
            // does nothing.
            break
        }
    }
    func sliceViewPress(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> Bool { press(p, flags) }
    func sliceViewDrag(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) { drag(p, flags) }
    func sliceViewRelease(_ p: CGPoint) { release(p) }
    func sliceViewTurnWheel(_ dy: CGFloat) -> Bool { turnWheel(dy) }
    func sliceViewHandWheel(_ dy: CGFloat) -> Bool { handWheel(dy) }
    func sliceViewMenu(_ p: CGPoint) -> NSMenu? { contextMenu(at: p) }
    func sliceViewHover(_ p: CGPoint?) {
        // The hand carries its part with the pointer, with no button down.
        if grabbing {
            if let p { drag(p, NSEvent.modifierFlags) }
            return
        }
        supportHover(at: p)
    }

    func sliceViewDidDraw() {
        if !tape.isEmpty { placeTape() }
        // The camera, the layers, or the page moved: the view file follows.
        SessionStore.shared.changedView()
    }
    func sliceViewDoubleClick(_ p: CGPoint) -> Bool { lookAtSide(p) }

    func sliceViewTick(_ dt: Double) -> Bool {
        // A fall, else the replay.
        falling != nil ? fallTick(dt) : stepReplay(dt)
    }

    func sliceViewAppearanceChanged() {
        if model.state == .done { canvas.load(model.core); applyRange() }
    }

    /// The keys of the preview (docs/user/getting-started.md, "Keys in the
    /// preview"), for the case with no selected line.
    func sliceViewKey(_ event: NSEvent) -> Bool {
        // Esc lets go of the part in the hand.
        if grabbing, event.charactersIgnoringModifiers == "\u{1b}" {
            letGo()
            return true
        }
        if supportKey(event) { return true }
        if turnKey(event) { return true }
        if selection == nil, partKey(event) { return true }
        // Delete on a selected line (with no part card): the line does not print.
        if selection != nil, selectedPart == nil, event.specialKey == .delete || event.specialKey == .deleteForward {
            editLine(kind: 0)
            return true
        }
        if event.charactersIgnoringModifiers == "\u{1b}", !tape.isEmpty {
            clearTape()
            return true
        }
        if selectionKey(event) { return true }
        // The keys of the tools (with no modifier).
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let t = Tool.of(key: event.charactersIgnoringModifiers ?? "") {
            setTool(t)
            return true
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .upArrow?: shift ? moveBottom(1) : moveTop(1)
        case .downArrow?: shift ? moveBottom(-1) : moveTop(-1)
        case .home?: framePlate(-1)
        case .pageUp?: moveTop(10)
        case .pageDown?: moveTop(-10)
        case .leftArrow?: scrubStep(-0.02)
        case .rightArrow?: scrubStep(0.02)
        default:
            switch event.charactersIgnoringModifiers {
            case "k": shift ? moveBottom(1) : moveTop(1)
            case "j": shift ? moveBottom(-1) : moveTop(-1)
            case "C" where shift: setRange(lo: 0, hi: layerCount - 1)
            case "n" where !shift: showSettings.toggle()
            // Esc with nothing else to close: the settings pane.
            case "\u{1b}" where showSettings: showSettings = false
            case "/": searchOpen.toggle()
            case "?": shortcutsOpen = true
            case "g" where !shift: toggleGaps()
            case "[": selectPlate(max(0, model.active - 1))
            case "]": selectPlate(min(model.plates.count - 1, model.active + 1))
            case "f" where !shift: framePlate(model.active)
            default: return false
            }
        }
        return true
    }

    private func scrubStep(_ df: Double) { scrub(to: min(1, max(0, scrubFraction + df))) }
}
