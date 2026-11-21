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
import UniformTypeIdentifiers
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
    /// The thinned dots of the trees, for a key (SupportTrees.swift).
    @ObservationIgnored var treeDots: (key: TreeDotsKey, pts: [Double])?
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
    /// The printer of the sheet that gets its key (PairSheet), or nil.
    var pairing: UUID?
    /// The printer of the sheet is only the address of a deck (Connect a
    /// Printdeck): it goes, and the printers that the user picks come.
    var pairingFresh = false
    /// The sheet of Connect a Printdeck shows.
    var connectDeckOpen = false

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
    var supportPaneOpen = prefs.object(forKey: "supportPane") as? Bool ?? true {
        didSet { prefs.set(supportPaneOpen, forKey: "supportPane") }
    }
    var selectedPart: Int?
    /// The other selected parts (Shift and a click), the first added first.
    var moreParts: [Int] = []
    /// The support that the Select tool picked (SupportPick.swift).
    var supportPick: SupportPick?
    @ObservationIgnored var supportPicking = false
    /// A drag over layers of the Select tool, and the open range card
    /// (LayerRange.swift).
    @ObservationIgnored var rangeDrag: RangeDrag?
    var rangeCard: (lo: Int, hi: Int)?
    /// The Paint tool (PaintTool.swift), while it is on.
    var paint: PaintSession?
    /// The other lines of a run (Shift and a click) are lit.
    @ObservationIgnored var runLit = false
    /// The card of a history step over its bubble (HistoryCard.swift).
    var historyCard: HistoryCardState?
    @ObservationIgnored var historyCardTask: Task<Void, Never>?
    @ObservationIgnored var historyCardHovered = false
    /// The frame of each bubble of the timeline (global), for the card.
    @ObservationIgnored var historyBubbles: [Int: CGRect] = [:]
    /// The panels over the view (global frames), and the global origin of
    /// the layer of the cards: a card keeps out of each panel.
    var panelFrames: [CGRect] = []
    var cardsOrigin: CGPoint = .zero
    /// The panels in the coordinates of the cards.
    var panels: [CGRect] { panelFrames.map { $0.offsetBy(dx: -cardsOrigin.x, dy: -cardsOrigin.y) } }
    /// The range of Shift+K and Shift+J: the first layer, and the layer
    /// that moves.
    @ObservationIgnored var keyRange: (a: Int, b: Int)?
    /// The start line of the range of the keys, and of the open range.
    @ObservationIgnored var keyLine: RangeLine?
    @ObservationIgnored var rangeLine: RangeLine?
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
    /// The text and the look of the signs of the plates, as last drawn
    /// (PlateSigns.swift).
    @ObservationIgnored var signKey = ""
    /// The place of the Open button of an empty active plate, or nil.
    var openButtonAt: CGPoint?
    /// The view shows the print as it forms (Simulation.swift), and the
    /// numbers of the last simulation of this slice.
    var simulated = false
    var simResult: SimResult?
    /// When the last slice showed, for the log of ZSLICE_SIM.
    @ObservationIgnored var slicedAt = 0.0
    /// The ids of the plates and the active plate, as the session has them.
    @ObservationIgnored var plateIDs: [UInt64] = []

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
    /// The corner of the line card (0 top left, 1 top right, 2 bottom left,
    /// 3 bottom right): it keeps it from click to click.
    @ObservationIgnored var cardCorner: Int?
    /// The height of the bottom bar, for the cards to keep clear of it.
    var dockHeight: CGFloat = 70
    /// "Fade the others": the app keeps the choice.
    var isolate = prefs.bool(forKey: "isolate") {
        didSet { prefs.set(isolate, forKey: "isolate") }
    }

    /// The page of the view: 3D, or one layer from the top. The app keeps
    /// the choice for the next window.
    var page: MetalSliceView.Page = MetalSliceView.Page(rawValue: prefs.string(forKey: "view") ?? "") ?? .threeD {
        didSet {
            canvas.page = page
            prefs.set(page.rawValue, forKey: "view")
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
        if let t = ProcessInfo.processInfo.environment["ZSLICE_SEARCH"] {
            // ZSLICE_SEARCH_UNDOCK=1: the search as a card.
            if ProcessInfo.processInfo.environment["ZSLICE_SEARCH_UNDOCK"] != nil { search.docked = false }
            search.query = t
            search.show()
        }
        // ZSLICE_SEARCH_ENTER=name=value: Return on the first result, the
        // value typed in its field, and Return again; it logs where the
        // focus is after each step, and the value of the setting.
        if let spec = ProcessInfo.processInfo.environment["ZSLICE_SEARCH_ENTER"], let eq = spec.firstIndex(of: "=") {
            let name = String(spec[..<eq]), value = String(spec[spec.index(after: eq)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.runSearchEnterTest(name, value) }
        }
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
        model.onSimulated = { [weak self] in self?.simulatedReady() }
        model.holdSimulation = { [weak self] in
            guard let self else { return false }
            return treeDrag != nil || supportDrag != nil || partDrag != nil || ringDrag != nil || grabbing || falling != nil
        }
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
        // A new slice shows the plan until its simulation is ready.
        simulated = false
        simResult = nil
        slicedAt = CACurrentMediaTime()
        if let v = canvas.view { zs_view_set_mode(v, Int32(colorMode)) }
        let tl = CACurrentMediaTime()
        canvas.load(model.core)
        if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
            NSLog("zslice timing: view load %.1f ms", (CACurrentMediaTime() - tl) * 1000)
        }
        // The bed model of the printer (it needs the bed size of the load).
        if let v = canvas.view { PrinterLibrary.shared.showBed(of: model.core, in: v) }
        readLegend()
        // The load cleared the lit body of an open range.
        relightRange()
        // The labels and the mesh of the pick after the slice.
        reloadLabels()
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
        // The checks (about 20 ms on a large part) come after the frame of
        // the new slice, so the slice shows at once. During a drag, a hold,
        // or a fall they wait for its end: the live slices of a drag come
        // each 150 ms, and the checks would stall each of them.
        issuesTask?.cancel()
        issuesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            while let self, !Task.isCancelled, treeDrag != nil || supportDrag != nil || partDrag != nil || ringDrag != nil || grabbing || falling != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
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
            if env["ZSLICE_UNDO"] != nil { NSLog("zslice undo: history %ld/%ld", model.history.current, model.history.count) }
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
        // ZSLICE_GCODE_AFTER=s:path writes the G-code of the plate s seconds
        // after the start (after the other hooks changed the plate).
        if let spec = env["ZSLICE_GCODE_AFTER"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let path = String(spec[spec.index(after: colon)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
                let ok = (try? self?.model.gcode()?.write(to: URL(fileURLWithPath: path))) != nil
                NSLog("zslice gcode after: %@ %@", path, ok ? "written" : "FAILED")
            }
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
        // ZSLICE_FARM="url;bambu:address:serial:code[:model]" adds printers
        // (in a fresh run only), for the Printers page.
        if let farm = env["ZSLICE_FARM"], env["ZSLICE_FRESH"] != nil, PrinterStore.shared.printers.isEmpty {
            for (i, item) in farm.split(separator: ";").map(String.init).enumerated() {
                let f = item.split(separator: ":", maxSplits: 4).map(String.init)
                if f.first == "bambu", f.count >= 4 {
                    var p = Printer(name: "Bambu \(i + 1)", model: f.count > 4 ? f[4] : "bambu-lab-p1s", kind: .bambu, url: f[1])
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
        // ZSLICE_KEY_REMOVE=1: a printer with a key, then its removal; it
        // logs the key before and after (the key must go with the printer).
        if env["ZSLICE_KEY_REMOVE"] != nil {
            let p = Printer(name: "Key Test", kind: .octoprint, url: "http://127.0.0.1:9")
            p.apiKey = "TESTKEY"
            PrinterStore.shared.add(p)
            let before = Keychain.read(account: p.id.uuidString) != nil
            PrinterStore.shared.remove(p.id)
            NSLog("zslice key remove: key before %d, after %d", before ? 1 : 0, Keychain.read(account: p.id.uuidString) == nil ? 0 : 1)
        }
        // ZSLICE_HISTORY_CARD=i opens the card of history step i over its
        // bubble, 4 s after the start (after ZSLICE_SET makes the steps).
        if let i = env["ZSLICE_HISTORY_CARD"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                historyCard = HistoryCardState(step: i, anchor: historyBubbles[i] ?? .zero)
                NSLog("zslice history card: step %ld of %ld, keys %@, changes %@", i, model.history.count, historyCardKeys(i).joined(separator: ","), model.history.step(i)?.changes.joined(separator: " / ") ?? "-")
            }
        }
        // ZSLICE_USE_FILAMENTS=1 runs Use the Filaments of the printer of
        // the plate 4 s after the start, and logs its note and the list.
        if env["ZSLICE_USE_FILAMENTS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let p = platePrinter else {
                    NSLog("zslice use filaments: no printer")
                    return
                }
                Task { @MainActor in
                    let words = await self.useLoadedFilaments(p)
                    NSLog("zslice use filaments: %@ list %@", words, self.model.filaments.map { "\($0.index + 1) \($0.material) \($0.color)" + ($0.nozzle == 1 ? " 2nd" : "") }.joined(separator: ", "))
                    NSLog("zslice use filaments: nozzle %@ %@", self.model.setting("machine.nozzle_type"), self.model.setting("machine.nozzle_flow"))
                }
            }
        }
        // ZSLICE_SUPPORT_FILAMENT=k: a second filament, support everywhere,
        // and support_filament k (0: the part); logs the grams of each
        // filament after the slice.
        if let k = env["ZSLICE_SUPPORT_FILAMENT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let i = model.addFilament() else { return }
                model.setFilament(i, "filament.color", "#2e7d32")
                model.set("project.support", "everywhere")
                let err = model.set("project.support_filament", k)
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                    guard let self, let st = model.filamentStats else { return }
                    NSLog("zslice support filament: set %@ (%@), value %@, support %@, total %.2f g, grams %@, changes %ld", k, err ?? "ok",
                          model.setting("project.support_filament"), model.setting("project.support"), model.stats?.filament_g ?? 0,
                          st.grams.map { String(format: "%.2f", $0) }.joined(separator: ","), st.changes)
                }
            }
        }
        // ZSLICE_FILAMENT_LOG=1 logs the filaments of the plate and their
        // grams, 5 s after the start (a painted file that opens).
        if env["ZSLICE_FILAMENT_LOG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                let st = model.filamentStats
                NSLog("zslice filaments: %@; grams %@, changes %ld", model.filaments.map { "\($0.index + 1) \($0.material) \($0.color)" }.joined(separator: ", "),
                      st?.grams.map { String(format: "%.2f", $0) }.joined(separator: ",") ?? "-", st?.changes ?? 0)
            }
        }
        // ZSLICE_PAINT_TEST=smart|brush: a red second filament, the Paint
        // tool, and a click (or a stroke) at the middle of the view; it logs
        // the region, the paint, and the grams of each filament after the
        // slice. The tool stays open for a screenshot.
        if let mode = env["ZSLICE_PAINT_TEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let i = model.addFilament() else { return }
                model.setFilament(i, "filament.color", "#e03030")
                setTool(.paint)
                guard let p = paint else {
                    NSLog("zslice paint test: no tool")
                    return
                }
                p.filament = i + 1
                paintColors()
                let mid = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
                let hit = paintHit(mid)
                paintHover(mid)
                NSLog("zslice paint test: %ld triangles, hit %d, hover %ld triangles", p.triangles, hit == nil ? 0 : 1, p.hover?.tris.count ?? 0)
                if mode == "brush" {
                    p.mode = .brush
                    p.size = 4
                    _ = paintPress(mid, [])
                    for k in 1 ... 10 { paintDrag(CGPoint(x: mid.x + CGFloat(k * 6), y: mid.y)) }
                    paintRelease()
                } else {
                    _ = paintPress(mid, [])
                }
                var text: UnsafePointer<CChar>?
                var len = 0
                zs_paint_text(p.session, &text, &len)
                NSLog("zslice paint test: %@ painted, paint text %ld bytes", mode, len)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, let st = model.filamentStats else { return }
                    NSLog("zslice paint test: grams %@, changes %ld", st.grams.map { String(format: "%.2f", $0) }.joined(separator: ","), st.changes)
                    // ZSLICE_PAINT_SAVE=path: the project with its paint, for
                    // the tests of painted files.
                    if let path = env["ZSLICE_PAINT_SAVE"], let data = model.projectFileData(name: "plaque") {
                        try? data.write(to: URL(fileURLWithPath: path))
                        NSLog("zslice paint test: saved %ld bytes", data.count)
                    }
                }
            }
        }
        // ZSLICE_FILAMENT_TEST=lo:hi: a second filament (red PETG) for the
        // layers lo to hi (the card of the range opens), then the grams of
        // each filament and the changes after the slice.
        if let spec = env["ZSLICE_FILAMENT_TEST"] {
            let f = spec.split(separator: ":").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // The card first: a new filament slices again, and a card
                // opens only on a slice.
                guard let self, f.count == 2 else { return }
                openRangeCard(f[0], f[1])
                guard rangeCard != nil, let i = model.addFilament() else {
                    NSLog("zslice filament test: no card")
                    return
                }
                model.setFilament(i, "filament.color", "#e03030")
                model.setFilament(i, "filament.material", "PETG")
                let err = model.set("project.filament", String(i + 1))
                NSLog("zslice filament test: added %ld, set %@", i, err ?? "ok")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, let st = model.filamentStats else { return }
                    closeRangeCard()
                    NSLog("zslice filament test: %ld filaments, grams %@, changes %ld, flush %.2f g", model.filaments.count,
                          st.grams.map { String(format: "%.2f", $0) }.joined(separator: ","), st.changes, st.flushG)
                }
            }
        }
        // ZSLICE_SEND_TO=k[:print] (tests only) sends the active plate to
        // printer k of the store (or "all": each one in turn) 4 s after the
        // start, with no question, and logs each result.
        if let spec = env["ZSLICE_SEND_TO"] {
            // ZSLICE_SEND_DELAY=s waits longer, after other hooks.
            let delay = env["ZSLICE_SEND_DELAY"].flatMap(Double.init) ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let data = model.gcode(plate: model.active) else { return }
                let all = PrinterStore.shared.printers
                let first = spec.split(separator: ":").first.map(String.init) ?? ""
                let list = first == "all" ? all : Int(first).flatMap { all.indices.contains($0) ? [all[$0]] : nil } ?? []
                Task { @MainActor in
                    for p in list {
                        let r = await self.transfer(data, title: self.model.gcodeName(plate: self.model.active), to: p, print: spec.hasSuffix(":print"))
                        NSLog("zslice send to %@ (deck bambu %d): %d %@", p.name, p.bambuDeck ? 1 : 0, r.ok ? 1 : 0, r.message)
                    }
                }
            }
        }
        // ZSLICE_PAGE_CLOSE=s closes the Printers page after s seconds (a
        // test that its cameras stop).
        if let t = env["ZSLICE_PAGE_CLOSE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.farmOpen = false }
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
                        let r = await transfer(data, title: model.gcodeName(plate: i), to: p, print: true, plate: i)
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
        // ZSLICE_BED_BELOW=path.png: the view from under the bed (the bed
        // model draws see-through from there), 2 s after the start.
        if let path = env["ZSLICE_BED_BELOW"], let v = canvas.view {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                zs_view_orbit(v, 30, -160)
                try? await Task.sleep(for: .milliseconds(300))
                guard let img = await canvas.captureWindow(),
                      let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(d, img, nil)
                CGImageDestinationFinalize(d)
                NSLog("zslice bed below: done")
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
        // An upper case letter has Shift, and ^x is Control-x. The log has
        // the layers shown and the range card after each key.
        if let keys = env["ZSLICE_KEYS"] {
            var log: [String] = []
            var control = false
            for ch in keys {
                if ch == "^" {
                    control = true
                    continue
                }
                let s = String(ch)
                var flags: NSEvent.ModifierFlags = []
                if control { flags.insert(.control) }
                if ch.isUppercase { flags.insert(.shift) }
                control = false
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                            characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                    _ = sliceViewKey(e)
                }
                let range = rangeCard.map { " range \($0.lo)-\($0.hi)" } ?? ""
                log.append("\(flags.contains(.control) ? "^" : "")\(s)→\(tool.rawValue) \(lo)-\(hi)\(range) line \(selection.map { String($0.path) } ?? "-")\(page == .twoD ? " 2D" : "")")
            }
            NSLog("zslice keys: selection %d, %@", selection == nil ? 0 : 1, log.joined(separator: " | "))
        }
        // ZSLICE_GRAB=1: the Grab tool, a press on the part at the center,
        // a drag of 200 points to the right in 0.5 s, and a release; the
        // part 3 s later.
        if env["ZSLICE_TREE_TEST"] != nil { runTreeTest() }
        // ZSLICE_STALLS=1 logs each wait of the main thread over 20 ms (a
        // timer each 5 ms, in all run loop modes), with the time from the
        // start, to match with the other logs.
        if env["ZSLICE_STALLS"] != nil {
            var last = CACurrentMediaTime()
            let watch = Timer(timeInterval: 0.005, repeats: true) { _ in
                let now = CACurrentMediaTime()
                if now - last > 0.02 { NSLog("zslice stall: %.0f ms, ending at %.0f ms", (now - last) * 1000, (now - launchTime) * 1000) }
                last = now
            }
            RunLoop.main.add(watch, forMode: .common)
        }
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
        // ZSLICE_CONNECT_DECK=url opens Connect a Printdeck with that address.
        if env["ZSLICE_CONNECT_DECK"] != nil { connectDeckOpen = true }
        // ZSLICE_PAIR=url: a printdeck at url with no key, and the sheet
        // that gets its key.
        if let url = env["ZSLICE_PAIR"] {
            let p = Printer(name: "Test Deck", kind: .printdeck, url: url)
            PrinterStore.shared.add(p)
            pairing = p.id
        }
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
        // ZSLICE_PLATE_HOME=k: plate k becomes active 4 s after the start,
        // and 1.5 s later Fit the Part (the start view, as Command-0 and a
        // double click on no side). Logs the camera target and the center
        // of the active plate.
        if let k = env["ZSLICE_PLATE_HOME"].flatMap({ Int($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.model.select(k)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, let v = canvas.view else { return }
                    fit()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, let v = canvas.view else { return }
                        var cam = [Float](repeating: 0, count: 8)
                        zs_view_get_camera(v, &cam)
                        var b = [Double](repeating: 0, count: 4)
                        let ok = zs_view_bounds(v, &b) == 0
                        NSLog("zslice plate home: plate %ld of %ld, target %.1f, %.1f, %.1f, print bounds %@", model.active, model.plates.count, cam[0], cam[1], cam[2],
                              ok ? String(format: "x %.1f..%.1f y %.1f..%.1f", b[0], b[2], b[1], b[3]) : "none")
                    }
                    _ = v
                }
            }
        }
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
                NSLog("zslice menu: %@", menu.items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ", "))
                if let item = all.first(where: { $0.title == spec[1] }) as? ClosureItem {
                    _ = item.target?.perform(item.action)
                }
            }
        }
        // ZSLICE_REMOVE_SUPPORT=1 selects the longest support line of the
        // middle layer, and runs Remove This Support of its menu ("card":
        // opens its card).
        // It waits 3 s for the slice of a ZSLICE_SET.
        if env["ZSLICE_REMOVE_SUPPORT"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                var tp = zs_toolpaths()
                guard zs_app_toolpaths(model.core, &tp) == 0, tp.layer_count > 2, let ends = tp.path_ends else { return }
                let l = tp.layer_count / 3
                let a = Int(tp.layer_ends[l - 1]), b = Int(tp.layer_ends[l])
                let len = { (i: Int) in ends[i] - (i > 0 ? ends[i - 1] : 0) }
                let support = (a ..< b).filter { tp.path_features[$0] == UInt8(ZS_FEATURE_SUPPORT.rawValue) }
                guard let path = support.max(by: { len($0) < len($1) }) else {
                    NSLog("zslice remove support: no support line on layer %ld", l)
                    return
                }
                // "card": the card of the line only.
                if env["ZSLICE_REMOVE_SUPPORT"] == "card" {
                    cardAt = CGPoint(x: 450, y: 300)
                    select(path: path, seg: 0, openCard: true)
                    NSLog("zslice support card: %@", lineInfo.map { "\($0.title), holds \($0.holds.map { "layer \($0.layer) feature \($0.feature)" } ?? "none")" } ?? "none")
                    return
                }
                select(path: path, seg: 0, openCard: false)
                let areas = zs_app_support_area_count(model.core)
                removeSupportHere()
                NSLog("zslice remove support: layer %ld path %ld, areas %ld -> %ld, note %@", l, path, areas,
                      zs_app_support_area_count(model.core), note ?? "none")
            }
        }
        // ZSLICE_SELECT_TEST runs the Select tool, as in the GTK app:
        // "parts" (a copy of part 0, the plate arranged, and both parts
        // selected with Shift), "range lo hi" (a drag over layers lo to hi),
        // or "support x y [style]" (a click of the Select tool at x, y
        // points, or at the first support line for x "auto"; with a style,
        // the support goes on first). ZSLICE_SELECT_DEL=1 then presses
        // Delete. The log says what the Select tool did.
        if let spec = env["ZSLICE_SELECT_TEST"]?.split(separator: " ").map(String.init) {
            Task { @MainActor in await runSelectTest(spec) }
        }
        // ZSLICE_PICK=x,y picks the line at that point of the view (points),
        // as a click does (as in the GTK app).
        if let xy = env["ZSLICE_PICK"]?.split(separator: ",").compactMap({ Double($0) }), xy.count == 2 {
            pick(at: CGPoint(x: xy[0], y: xy[1]))
        }
        // ZSLICE_USE_PRINTERS="k[:color],..." switches to printer k of the
        // store in turn, 4 s apart, and then sets the color of the filament
        // if one is given. ZSLICE_SWITCH_LOG=1 logs the filament after each
        // switch: each printer keeps the filament it was last used with.
        if let spec = env["ZSLICE_USE_PRINTERS"] {
            for (n, step) in spec.split(separator: ",").enumerated() {
                let f = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard let k = Int(f[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4 * Double(n + 1)) { [weak self] in
                    guard let self, PrinterStore.shared.printers.indices.contains(k) else { return }
                    usePrinter(PrinterStore.shared.printers[k])
                    if f.count == 2 { model.set("filament.color", f[1]) }
                }
            }
        }
        // ZSLICE_CLIP="part:center,copy,paste,pasteat:x:y,cut,dup,copyplate,
        // dupplate,pasteplate,undo,area,range:lo:hi,set:name=value,closerange": each step 1.5 s apart (Clipboard.swift),
        // and after it the parts, the plates, the selection, the clipboard,
        // and the history.
        if let spec = env["ZSLICE_CLIP"] {
            Task { @MainActor in
                for step in spec.split(separator: ",") {
                    try? await Task.sleep(for: .seconds(1.5))
                    let f = step.split(separator: ":").map(String.init)
                    let mid = CGPoint(x: self.canvas.bounds.midX, y: self.canvas.bounds.midY)
                    switch f[0] {
                    case "part": self.selectOnlyPart(self.partAt(mid))
                    case "none": self.selectPart(nil)
                    case "copy": self.clipCopy()
                    case "cut": self.clipCut()
                    case "paste": self.clipPaste()
                    // pasteat:x:y, or pasteat alone: the center of the view.
                    case "pasteat": self.clipPaste(at: f.count > 2 ? CGPoint(x: Double(f[1]) ?? mid.x, y: Double(f[2]) ?? mid.y) : mid, here: true)
                    case "wait": try? await Task.sleep(for: .seconds(4))
                    case "dup": self.clipDuplicate()
                    case "copyplate": self.copyPlate()
                    case "dupplate": self.duplicatePlate()
                    case "pasteplate": self.pasteAsPlate()
                    case "undo": self.model.history.undoManager.undo()
                    // area: a Grid area of 10 mm around the center of part 0,
                    // selected in the Support tool.
                    case "area":
                        self.setTool(.support)
                        if let q = self.part(0) {
                            var pts = [q.x - 5, q.y - 5, 0, q.x + 5, q.y - 5, 0, q.x + 5, q.y + 5, 0, q.x - 5, q.y + 5, 0]
                            let i = zs_app_support_area_add(self.model.core, Int32(ZS_MARK_GRID.rawValue), &pts, 4, 1, 0)
                            self.supportEdited()
                            if i >= 0 { self.supportSelected = Int(i) }
                        }
                    // range:lo:hi opens the range card; set:name=value changes
                    // a setting for its layers.
                    case "range": self.openRangeCard(Int(f[1]) ?? 0, Int(f[2]) ?? 0)
                    case "closerange": self.closeRangeCard()
                    case "set":
                        let kv = f[1].split(separator: "=").map(String.init)
                        if kv.count == 2 { NSLog("zslice clip set: card %@, %@", self.rangeCard.map { "\($0.lo)-\($0.hi)" } ?? "none", self.model.set(kv[0], kv[1]) ?? "ok") }
                    default: break
                    }
                    try? await Task.sleep(for: .seconds(0.6))
                    NSLog("zslice clip %@: areas %ld, overrides %ld", String(step), zs_app_support_area_count(self.model.core), zs_app_override_count(self.model.core))
                    NSLog("zslice clip %@: parts %ld, plates %ld, active %ld, selected %@, clipboard %ld (plate %d), history %ld/%ld, note %@",
                          String(step), zs_app_part_count(self.model.core), self.model.plates.count, self.model.active,
                          self.selectedParts.map(String.init).joined(separator: " "), zs_clipboard_parts(), zs_clipboard_is_plate(),
                          self.model.history.current, self.model.history.count, self.note ?? "-")
                }
            }
        }
        // ZSLICE_LABEL_AT=x,y opens the Label tool and presses there, as a
        // click: a label goes on the face. ZSLICE_LABEL_FILAMENTS=2 adds a
        // filament first, and ZSLICE_LABEL_TEXT=text sets its text. Logs
        // the label after the slice, and its facts.
        if let spec = env["ZSLICE_LABEL_AT"] {
            let xy = spec.split(separator: ",").compactMap { Double($0) }
            Task { @MainActor in
                if env["ZSLICE_LABEL_FILAMENTS"] == "2", self.model.filaments.count < 2 { _ = self.model.addFilament() }
                self.setTool(.label)
                let at = xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : CGPoint(x: self.canvas.bounds.midX, y: self.canvas.bounds.midY)
                _ = self.labelPress(at, [])
                _ = self.labelRelease()
                if let t = env["ZSLICE_LABEL_TEXT"] { _ = self.editLabelItem(0, commit: true) { $0.text = t } }
                // ZSLICE_LABEL_STEPS="turn:15,scale:1.5,drag:dx:dy,handle:40:shift,delete,undo,...":
                // each step 1 s apart, and the label after it.
                for step in (env["ZSLICE_LABEL_STEPS"] ?? "").split(separator: ",") {
                    try? await Task.sleep(for: .seconds(1.2))
                    let f = step.split(separator: ":").map(String.init)
                    switch f[0] {
                    case "turn": for _ in 0 ..< abs(Int(f[1]) ?? 0) { self.turnLabel((Int(f[1]) ?? 0) > 0 ? 1 : -1) }
                    case "scale": if let l = self.labelState.label { self.scaleLabel(from: l, by: Double(f[1]) ?? 1); self.flushLabel() }
                    case "drag":
                        if let c = self.labelScreenCenter() {
                            let to = CGPoint(x: c.x + (Double(f[1]) ?? 0), y: c.y + (Double(f[2]) ?? 0))
                            _ = self.labelPress(c, [])
                            for k in 1 ... 10 { self.labelDrag(CGPoint(x: c.x + (to.x - c.x) * Double(k) / 10, y: c.y + (to.y - c.y) * Double(k) / 10), []) }
                            _ = self.labelRelease()
                        }
                    // handle:deg[:shift]: the turn handle dragged deg degrees
                    // around the center of the label on the screen.
                    case "handle":
                        if let l = self.labelState.label, let c = self.labelScreenCenter(), let t = self.labelState.turnAt {
                            let a0 = atan2(t.y - c.y, t.x - c.x), r = hypot(t.x - c.x, t.y - c.y)
                            let a1 = a0 + (Double(f[1]) ?? 0) * .pi / 180
                            self.turnLabelHandle(from: l, center: c, a0: a0, sign: self.labelTurnSign(l),
                                                 to: CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1)), snap: f.count > 2)
                            self.flushLabel()
                            NSLog("zslice label handle: sign %.0f, angle %.1f to %.1f", self.labelTurnSign(l), l.angle, self.labelState.label?.angle ?? 0)
                        }
                    case "delete": self.removeLabel()
                    case "copy": self.clipCopy()
                    case "cut": self.clipCut()
                    // paste:x:y at a point; paste alone with no point: under the label.
                    case "paste":
                        if f.count > 2 {
                            self.clipPaste(at: CGPoint(x: Double(f[1]) ?? 0, y: Double(f[2]) ?? 0))
                        } else if case let .label(l, part)? = Clip.current {
                            self.pasteLabel(l, at: nil, part: part)
                        }
                    case "dup": self.clipDuplicate()
                    case "blur": self.canvas.window?.makeFirstResponder(self.canvas)
                    case "set": self.model.set("project.wall_count", String(Int.random(in: 3 ... 6))); self.model.history.commit()
                    case "coreundo": NSLog("zslice label step coreundo: bits %d", zs_app_history_undo(self.model.core, Int64(Date().timeIntervalSince1970 * 1000)))
                    case "undo": try? await Task.sleep(for: .seconds(0.5)); self.model.history.undoManager.undo()
                    default: break
                    }
                    try? await Task.sleep(for: .seconds(0.6))
                    let st = self.labelState
                    let coreList = PartLabel.list(coreString { zs_app_part_labels_get(self.model.core, max(st.index, 0), $0, $1, $2) } ?? "[]").count
                    NSLog("zslice label step %@: core %ld, history %ld/%ld, undo %@, kind %@", String(step), coreList, self.model.history.current, self.model.history.count,
                          self.model.history.undoManager.undoActionName, self.model.history.step(self.model.history.current)?.kind ?? "-")
                    NSLog("zslice label step %@: %ld labels, %@", String(step), st.labels.count,
                          st.label.map { String(format: "turn %.0f°, size %.2f, origin %.1f %.1f %.1f", $0.angle, $0.items.first?.size ?? 0, $0.origin[0], $0.origin[1], $0.origin[2]) } ?? "none selected")
                }
                try? await Task.sleep(for: .seconds(5))
                let st = self.labelState
                NSLog("zslice label: part %ld, %ld labels, selected %@, %@", st.index, st.labels.count, st.sel.map { String($0) } ?? "none",
                      st.label.map { "\($0.title), filament \($0.filament), turn \(Int($0.angle.rounded()))°" } ?? "-")
                if let i = st.info {
                    NSLog("zslice label info: %@, thinnest %.2f, clean %.1f, changes %ld (sliced %d), layers %ld, advice %@", i.kind ?? "?", i.thinnest ?? 0,
                          i.clean_size ?? 0, (i.sliced == true ? i.changes : i.estimate_changes) ?? -1, i.sliced == true ? 1 : 0, i.layers ?? 0, i.advice ?? "")
                }
            }
        }
        // ZSLICE_RIGHT_DRAG=1 sends a right drag of 100 points of a mouse to
        // the view, and =touch the same drag from a trackpad (the subtype
        // of two fingers clicked down), and logs the camera: a pan moves the
        // target, an orbit turns the rotation. The events go to the view
        // only, not to the system.
        if env["ZSLICE_RIGHT_DRAG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let v = canvas.view, let win = canvas.window else { return }
                var a = [Float](repeating: 0, count: 8), b = a
                zs_view_get_camera(v, &a)
                let c = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
                let touch = env["ZSLICE_RIGHT_DRAG"] == "touch"
                func send(_ type: NSEvent.EventType, _ dx: CGFloat) {
                    let p = canvas.convert(CGPoint(x: c.x + dx, y: c.y), to: nil)
                    guard var e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    // The subtype of a trackpad: 3, NSEvent.EventSubtype.touch.
                    if touch, let cg = e.cgEvent {
                        cg.setIntegerValueField(.mouseEventSubtype, value: Int64(NSEvent.EventSubtype.touch.rawValue))
                        if let t = NSEvent(cgEvent: cg) { e = t }
                    }
                    switch type {
                    case .rightMouseDown: canvas.rightMouseDown(with: e)
                    case .rightMouseDragged: canvas.rightMouseDragged(with: e)
                    default: canvas.rightMouseUp(with: e)
                    }
                }
                send(.rightMouseDown, 0)
                for k in 1 ... 10 { send(.rightMouseDragged, CGFloat(k) * 10) }
                send(.rightMouseUp, 100)
                zs_view_get_camera(v, &b)
                let moved = (0 ..< 3).map { abs(b[$0] - a[$0]) }.max() ?? 0, turned = (3 ..< 7).map { abs(b[$0] - a[$0]) }.max() ?? 0
                NSLog("zslice right drag (%@): target moved %.2f mm, rotation changed %.4f, %@", touch ? "trackpad" : "mouse", moved, turned, moved > 0.01 && turned < 1e-4 ? "pan" : turned >= 1e-4 ? "orbit" : "none")
            }
        }
        // ZSLICE_PICK_LATER="x,y;rx,y;cx,y;..." picks each point in turn, one
        // a second from 6 s after the slice ("r": the run of the line, as a
        // Shift-click; "c": a whole click of the view, as on a sign), for
        // the tests of the upload of a new selection (with ZSLICE_TIMING).
        if let spec = env["ZSLICE_PICK_LATER"] {
            for (k, item) in spec.split(separator: ";").enumerated() {
                let run = item.hasPrefix("r"), click = item.hasPrefix("c")
                let q = item.drop(while: { $0 == "r" || $0 == "c" }).split(separator: ",").compactMap { Double($0) }
                guard q.count == 2 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(k)) { [weak self] in
                    guard let self else { return }
                    let at = CGPoint(x: q[0], y: q[1])
                    if click { sliceViewClick(at) } else if run { pickRun(at: at) } else { pick(at: at) }
                    NSLog("zslice pick later: %@%.0f, %.0f, path %ld, plate %ld", run ? "run " : click ? "click " : "", q[0], q[1], selection?.path ?? -1, model.active)
                }
            }
        }
        // ZSLICE_RANGE_DRAG="x0,y0;x1,y1" drags over layers from a line, as
        // a user does (press, moves, release). ZSLICE_RANGE_KEYS=n presses
        // Shift-K n times from the picked line instead. Then the infill of
        // the range changes, so a new slice and a load of the view must
        // light the body again. ZSLICE_RANGE_LOG=1 logs each light, and
        // ZSLICE_RANGE_CLOSE=1 closes the card at the end.
        if env["ZSLICE_RANGE_DRAG"] != nil || env["ZSLICE_RANGE_KEYS"] != nil {
            Task { @MainActor in
                if let spec = env["ZSLICE_RANGE_DRAG"] {
                    let pts = spec.split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }
                    guard pts.count == 2, pts[0].count == 2, pts[1].count == 2 else { return }
                    let a = CGPoint(x: pts[0][0], y: pts[0][1]), b = CGPoint(x: pts[1][0], y: pts[1][1])
                    NSLog("zslice range: press %d", self.sliceViewPress(a, []) ? 1 : 0)
                    for k in 1 ... 20 {
                        let t = CGFloat(k) / 20
                        self.sliceViewDrag(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), [])
                    }
                    _ = self.sliceViewRelease(b)
                } else if let n = Int(env["ZSLICE_RANGE_KEYS"] ?? "") {
                    for _ in 0 ..< n {
                        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: "K", charactersIgnoringModifiers: "K", isARepeat: false, keyCode: 40) else { break }
                        _ = self.rangeKey(e)
                    }
                }
                NSLog("zslice range: card %@, start line %@", self.rangeCard.map { "\($0.lo + 1)-\($0.hi + 1)" } ?? "none", self.rangeLine.map { "\($0.path)" } ?? "none")
                guard self.rangeCard != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                NSLog("zslice range: set infill %@", self.model.set("project.infill_density", "0.4") ?? "ok")
                try? await Task.sleep(for: .seconds(6))
                NSLog("zslice range: after the slice, start line %@", self.rangeLine.map { "\($0.path)" } ?? "none")
                // ZSLICE_RANGE_CLOSE=1 closes the card, which clears the body.
                guard env["ZSLICE_RANGE_CLOSE"] != nil else { return }
                self.closeRangeCard()
                NSLog("zslice range: closed")
            }
        }
        // ZSLICE_SPATIAL="kind:x,y,w,h;..." keeps a place (the top left
        // corner) and a size for a kind of card, as a drag and a resize do.
        if let spec = env["ZSLICE_SPATIAL"] {
            for item in spec.split(separator: ";") {
                let kv = item.split(separator: ":", maxSplits: 1)
                let n = kv.count == 2 ? kv[1].split(separator: ",").compactMap { Double($0) } : []
                guard n.count == 4 else { continue }
                let k = String(kv[0])
                SpatialStore.shared.resized(k, to: CGSize(width: n[2], height: n[3]))
                SpatialStore.shared.moved(k, center: CGPoint(x: n[0] + n[2] / 2, y: n[1] + n[3] / 2), size: CGSize(width: n[2], height: n[3]))
            }
        }
        // ZSLICE_RUN_AT=x,y (or center) is a Shift-click of the Select tool:
        // the line and its run; ZSLICE_RUN_LOG=1 logs the run. 1.5 s later
        // a plain pick at the same point checks that the run goes.
        if let spec = env["ZSLICE_RUN_AT"] {
            let xy = spec.split(separator: ",").compactMap { Double($0) }
            let at = xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            pickRun(at: at)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                pick(at: at)
                NSLog("zslice run: after a plain pick, run lit %d", runLit ? 1 : 0)
            }
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
        // A plate added or removed: the session keeps the new list. A slice
        // keeps it too, but an empty plate has no slice.
        let ids = model.plates.map(\.id) + [UInt64(model.active)]
        if ids != plateIDs {
            if !plateIDs.isEmpty { SessionStore.shared.changed() }
            plateIDs = ids
        }
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
    /// Closes the project: its plates stay in the window as plates of the
    /// user, and the session keeps them.
    func closeProject() {
        guard model.project != nil else { return }
        model.project = nil
        projectOpen = false
        SessionStore.shared.changed()
        showNote("The project \(model.name) is closed. Its plates stay.")
    }

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

    func applyRange() {
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
    var showSettings = prefs.bool(forKey: "panel") {
        didSet {
            prefs.set(showSettings, forKey: "panel")
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

    var colorMode = prefs.integer(forKey: "mode") {
        didSet {
            prefs.set(colorMode, forKey: "mode")
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
            relightRange()
        }
        readLegend()
    }

    func readLegend() {
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

    /// The Label tool (LabelTool.swift), and a request for the focus of the
    /// text of its card.
    let labelState = LabelState()
    var labelFocusText = 0
    /// The search of settings and actions (SearchOverlay.swift): the same
    /// text in the toolbar and in the card.
    let search = SearchState()
    /// The results of the search show (docked), or its card (undocked).
    var searchOpen: Bool {
        get { search.open }
        set {
            search.open = newValue
            if !newValue { searchEye = nil }
        }
    }

    /// `/` and Command-F: the field of the toolbar takes the focus, or the
    /// card of the search opens and closes.
    func openSearch() {
        if search.docked || !search.open { search.show() } else { closeSearch() }
        if search.docked { focusSearchField() }
    }

    /// The field of the search in the toolbar takes the focus. It is in the
    /// frame view of the window, over the content view, where a focus of
    /// SwiftUI from the content does not reach: AppKit moves the focus.
    func focusSearchField() {
        guard let w = canvas.window, let root = w.contentView?.superview else { search.focusTick += 1; return }
        func find(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.isEditable, f.placeholderString == "Search settings and actions" { return f }
            for c in v.subviews { if let f = find(c) { return f } }
            return nil
        }
        if let f = find(root) { w.makeFirstResponder(f) } else { search.focusTick += 1 }
    }

    /// Esc, `/` again, or the close button: the results (or the card) go,
    /// and the view takes the keys again.
    func closeSearch() {
        searchOpen = false
        canvas.window?.makeFirstResponder(canvas)
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
    ///
    /// Each printer keeps its filament (as the GTK app and the web app): a
    /// switch saves the filament settings for the printer before, and loads
    /// the ones that the new printer was last used with. A printer with no
    /// saved filament keeps the filament now.
    func usePrinter(_ p: Printer) {
        let store = PrinterStore.shared
        if var before = store.current, before.id != p.id,
           let text = coreString({ zs_app_state_write(model.core, Int32(ZS_GROUP_FILAMENT.rawValue), $0, $1, $2) }) {
            before.filament = text
            store.update(before)
        }
        store.currentID = p.id
        setPlatePrinter(model.active, p)
        let machine = applyMachine(p, to: model.core)
        let filament = applyFilament(of: store.printers.first { $0.id == p.id } ?? p)
        if ProcessInfo.processInfo.environment["ZSLICE_SWITCH_LOG"] != nil {
            NSLog("zslice switch: printer %@, filament %@ %@ (%@), outer_wall_accel %@", p.name, model.setting("filament.material"), model.setting("filament.color"),
                  filament ? "its own" : "kept", model.setting("machine.outer_wall_accel"))
        }
        guard machine || filament else { return }
        model.settingsChanged()
    }

    /// The filament settings that printer p was last used with, on the
    /// active plate. False if it has none (or they do not load: the
    /// filament stays as it was).
    private func applyFilament(of p: Printer) -> Bool {
        guard !p.filament.isEmpty else { return false }
        let group = Int32(ZS_GROUP_FILAMENT.rawValue)
        let before = coreString({ zs_app_state_write(model.core, group, $0, $1, $2) }) ?? ""
        zs_app_group_reset(model.core, group)
        var message = [CChar](repeating: 0, count: 256)
        let rc = p.filament.withCString { zs_app_profile_apply(model.core, group, $0, strlen($0), &message, message.count) }
        guard rc == 0 else {
            NSLog("zslice: the filament of the printer %@ did not load: %@", p.name, message.withUnsafeBufferPointer { coreText($0.baseAddress) })
            zs_app_group_reset(model.core, group)
            _ = before.withCString { zs_app_profile_apply(model.core, group, $0, strlen($0), nil, 0) }
            return false
        }
        return true
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
    func transfer(_ unsigned: Data, title: String, to p: Printer, print: Bool, plate: Int? = nil) async -> LinkResult {
        // Each print that leaves the app is signed (Signing.swift).
        let gcode = Signer.sign(unsigned)
        // A Bambu Lab printer behind a printdeck: the .gcode.3mf with the
        // facts of the plate, to the store of the deck (its API, as for
        // G-code). The deck sends it to the printer, and asks on its screen
        // before the start.
        if p.bambuDeck {
            guard let bytes = bambuFile(gcode, title: title, plate: plate ?? model.active) else {
                return LinkResult(ok: false, message: "The file for the printer did not build.")
            }
            let file = title.replacingOccurrences(of: " ", with: "_") + ".gcode.3mf"
            return await PrinterLink.send(p, filename: file, gcode: bytes, print: print, file: true)
        }
        guard p.kind == .bambu else {
            return await PrinterLink.send(p, filename: title + ".gcode", gcode: gcode, print: print)
        }
        let file = title.replacingOccurrences(of: " ", with: "_") + ".gcode.3mf"
        guard let bytes = bambuFile(gcode, title: title, plate: plate ?? model.active) else {
            return LinkResult(ok: false, message: "The file for the printer did not build.")
        }
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

    /// The .gcode.3mf of a Bambu Lab printer around the signed G-code, with
    /// the filaments of the last slice of the plate in its slice info
    /// (zs_app_bambu_file_gcode): a printdeck reads them to list it and to
    /// pick the trays of the AMS.
    func bambuFile(_ gcode: Data, title: String, plate i: Int) -> Data? {
        guard let app = model.plates.indices.contains(i) ? zs_set_app(model.set, i) : model.core else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = gcode.withUnsafeBytes { zs_app_bambu_file_gcode(app, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, title, &out, &len) }
        guard rc == 0, let out else { return nil }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
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
        var data = Signer.sign(unsigned)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gcode]
        panel.nameFieldStringValue = model.gcodeName() + ".gcode"
        // A Bambu Lab printer prints a .gcode.3mf (the G-code, its MD5, and
        // the filaments of the print in Metadata/slice_info.config).
        if model.setting("machine.model").hasPrefix("bambu-lab"), let file = bambuFile(data, title: model.gcodeName(), plate: model.active) {
            data = file
            panel.allowedContentTypes = [UTType(filenameExtension: "3mf") ?? .data]
            panel.nameFieldStringValue = model.gcodeName() + ".gcode.3mf"
        }
        let write = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }
}

extension Workspace: SliceViewDelegate {
    func sliceViewClick(_ p: CGPoint) {
        // A click elsewhere ends a range of layers.
        closeRangeCard()
        // A click on the sign of a plate makes it the active plate.
        if page == .threeD, let v = canvas.view {
            let s = canvas.window?.backingScaleFactor ?? 2
            let i = zs_view_sign_at(v, Float(p.x * s), Float(p.y * s))
            if i >= 0, Int(i) < model.plates.count {
                if Int(i) != model.active { model.select(Int(i)) }
                return
            }
        }
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
        // The press of the Paint tool painted already, and the press of
        // the Label tool added or picked a label.
        case .paint, .label: break
        case .measure:
            measureClick(p, snap: !NSEvent.modifierFlags.contains(.shift))
        case .support:
            supportClick(p, snap: !NSEvent.modifierFlags.contains(.shift))
        case .turn, .move:
            // A click on a part selects it (Shift: adds it, or takes it
            // out); a click on a line selects it too.
            if NSEvent.modifierFlags.contains(.shift), let i = partAt(p) { togglePart(i) } else if let i = partAt(p) { selectOnlyPart(i) } else { selectPart(nil); pick(at: p) }
        case .select:
            // Shift and a click: the line there and its run, from the
            // retraction before it to the next one (web/app/input.js).
            // Command-Shift and a click add a part (press).
            if NSEvent.modifierFlags.contains(.shift) {
                pickRun(at: p)
            } else if !selectSupport(at: p) {
                clearSupportPick()
                pick(at: p)
            }
        case .grab:
            // A press on a part takes it (press); a click off the parts
            // does nothing.
            break
        }
    }
    func sliceViewPress(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> Bool { press(p, flags) }
    func sliceViewDrag(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) { drag(p, flags) }
    func sliceViewRelease(_ p: CGPoint) -> Bool { release(p) }
    func sliceViewTurnWheel(_ dy: CGFloat) -> Bool { turnWheel(dy) }
    func sliceViewHandWheel(_ dy: CGFloat) -> Bool { handWheel(dy) }
    func sliceViewLabelWheel(_ p: CGPoint, _ dy: CGFloat, shift: Bool) -> Bool { labelWheel(p, dy, shift: shift) }
    func sliceViewMenu(_ p: CGPoint) -> NSMenu? { contextMenu(at: p) }
    func sliceViewHover(_ p: CGPoint?) {
        // The hand carries its part with the pointer, with no button down.
        if grabbing {
            if let p { drag(p, NSEvent.modifierFlags) }
            return
        }
        if tool == .paint {
            paintHover(p)
            return
        }
        supportHover(at: p)
    }

    func sliceViewDidDraw() {
        if !tape.isEmpty { placeTape() }
        updatePlateSigns()
        if tool == .label { placeLabelHandle() }
        // The camera, the layers, or the page moved: the view file follows.
        SessionStore.shared.changedView()
    }
    func sliceViewDoubleClick(_ p: CGPoint) -> Bool { lookAtSide(p) }

    func sliceViewTick(_ dt: Double) -> Bool {
        // A fall, else the replay.
        falling != nil ? fallTick(dt) : stepReplay(dt)
    }

    func sliceViewAppearanceChanged() {
        if model.state == .done {
            canvas.load(model.core)
            applyRange()
            relightRange()
        }
    }

    /// The keys of the preview (docs/user/getting-started.md, "Keys in the
    /// preview"), for the case with no selected line.
    func sliceViewKey(_ event: NSEvent) -> Bool {
        // The Label tool: Delete removes the selected label; Esc closes its
        // card, and Esc again the tool.
        if tool == .label, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let k = event.charactersIgnoringModifiers
            if labelState.sel != nil, event.specialKey == .delete || event.specialKey == .deleteForward {
                removeLabel()
                return true
            }
            if k == "\u{1b}" {
                if labelState.drawing >= 0 { stopLabelDrawing() } else if labelState.sel != nil { selectLabel(nil) } else { setTool(.select) }
                return true
            }
        }
        // Esc lets go of the part in the hand.
        if grabbing, event.charactersIgnoringModifiers == "\u{1b}" {
            letGo()
            return true
        }
        // Esc closes the Paint tool.
        if tool == .paint, event.charactersIgnoringModifiers == "\u{1b}" {
            setTool(.select)
            return true
        }
        if supportKey(event) || supportPickKey(event) { return true }
        if rangeCard != nil, event.charactersIgnoringModifiers == "\u{1b}" {
            closeRangeCard()
            return true
        }
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
        // Ctrl+F and Ctrl+B (as in vi): a page of layers up or down, 5 % of
        // the layers of the print (at least 2). A selected line goes too.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
           let c = event.charactersIgnoringModifiers, c == "f" || c == "b" {
            let n = max(2, Int((Double(layerCount) * 0.05).rounded())) * (c == "f" ? 1 : -1)
            if selection != nil { lineLayer(n) } else { moveTop(n) }
            return true
        }
        if rangeKey(event) { return true }
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
            case "k": moveTop(1)
            case "j": moveTop(-1)
            // Shift+H and Shift+L with no line: the nozzle back or on.
            case "H" where shift: scrubStep(-0.02)
            case "L" where shift: scrubStep(0.02)
            case "C" where shift: setRange(lo: 0, hi: layerCount - 1)
            case "n" where !shift: showSettings.toggle()
            // Esc with nothing else to close: the settings pane.
            case "\u{1b}" where showSettings: showSettings = false
            case "/": if searchOpen { closeSearch() } else { openSearch() }
            // 2 shows the 2D view, and 2 again the 3D view; 3 the 3D view.
            case "2" where !shift: page = page == .twoD ? .threeD : .twoD
            case "3" where !shift: page = .threeD
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

extension Workspace {
    /// ZSLICE_SEARCH_ENTER (see the hook).
    func runSearchEnterTest(_ name: String, _ value: String) {
        guard let w = canvas.window else { return }
        // The window must be the key window for its first responder.
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        func returnKey() {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                w.sendEvent(e)
            }
        }
        func focus() -> String {
            guard let t = w.firstResponder as? NSTextView else { return "none" }
            return "\"\(t.string)\" selected \(t.selectedRange().length)"
        }
        // A test app that macOS did not let come to the front has no focus
        // in its window: the search field takes it, as a click would.
        if !(w.firstResponder is NSTextView) {
            func find(_ v: NSView) -> NSTextField? {
                if let f = v as? NSTextField, f.isEditable, f.placeholderString == "Search settings and actions" { return f }
                for c in v.subviews { if let f = find(c) { return f } }
                return nil
            }
            // The field of the toolbar is in the frame view of the window,
            // over the content view.
            if let root = w.contentView?.superview ?? w.contentView, let f = find(root) { w.makeFirstResponder(f) }
        }
        NSLog("zslice search enter: start, focus %@", focus())
        returnKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSLog("zslice search enter: after Return, focus %@", focus())
            (w.firstResponder as? NSTextView)?.insertText(value, replacementRange: (w.firstResponder as? NSTextView)?.selectedRange() ?? NSRange())
            returnKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                NSLog("zslice search enter: after the value, focus %@, %@ = %@", focus(), name, self.model.entry(name).value)
            }
        }
    }
}

