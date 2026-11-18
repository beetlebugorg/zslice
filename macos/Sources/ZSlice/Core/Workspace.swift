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
import CZslice
import Observation

@MainActor
@Observable
final class Workspace {
    let model = SliceModel()
    @ObservationIgnored let canvas = MetalSliceView(frame: .zero)

    // The layers of the last slice, and the range that shows.
    private(set) var layerCount = 0
    /// Fit the view to the plate after the next slice (after a fill).
    @ObservationIgnored var fitAfterSlice = false
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
    var selectedPart: Int?
    @ObservationIgnored var partDrag: PartDrag?
    @ObservationIgnored var tapeDrag: Int?
    /// A drag of a ring of the Turn tool: its axis, and the degrees sent.
    @ObservationIgnored var ringDrag: (axis: Int, sent: Double)?
    /// The label of a ring drag ("+30° about Z") and its place.
    var ringLabel: (text: String, at: CGPoint)?
    @ObservationIgnored let wheelSlice = Throttle(.milliseconds(300))
    @ObservationIgnored let keySlice = Throttle(.milliseconds(600))
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
        model.onActivePlate = { [weak self] in self?.activePlateChanged() }
    }

    // MARK: - the slice

    private func sliced() {
        stopReplay()
        if let v = canvas.view { zs_view_set_mode(v, Int32(colorMode)) }
        canvas.load(model.core)
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
        let wasTop = hi >= layerCount - 1
        layerCount = n
        if wasTop || hi >= n { hi = max(0, n - 1) }
        lo = min(lo, hi)
        applyRange()
        applyFocus()
        refindSelection()
        askEstimate()
        gapCard = nil
        showGaps()
        readIssues()
        if let i = selectedPart { selectPart(i < zs_app_part_count(model.core) ? i : nil) }
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
        framePlate(model.active)
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
                    showSettings = true
                    drawerPage = .project
                }
            } catch {
                sendState = nil
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

    enum DrawerPage: String { case settings, history, project }

    /// The pages of the settings browser that show, from its first page.
    var settingsPath: [SettingsRoute] = []

    /// Opens the drawer on all settings of the selected line.
    func showLineSettings() {
        showSettings = true
        drawerPage = .settings
        settingsPath = [.line]
    }

    /// The page of the drawer.
    var drawerPage = DrawerPage(rawValue: ProcessInfo.processInfo.environment["ZSLICE_PAGE"] ?? "") ?? .settings

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

    private func applyFocus() {
        guard let v = canvas.view else { return }
        let mask = focusMask != 0 ? focusMask : shownTypes
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
        guard !p.machine.isEmpty else { return }
        zs_app_group_reset(model.core, Int32(ZS_GROUP_MACHINE.rawValue))
        var message = [CChar](repeating: 0, count: 256)
        let rc = p.machine.withCString { zs_app_profile_apply(model.core, Int32(ZS_GROUP_MACHINE.rawValue), $0, strlen($0), &message, message.count) }
        if rc != 0 { NSLog("zslice: the printer %@ did not load: %@", p.name, message.withUnsafeBufferPointer { coreText($0.baseAddress) }) }
        model.settingsChanged()
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
        guard let p = PrinterStore.shared.current, p.kind != .none, let data = model.gcode() else { return }
        if p.kind == .bambu {
            sendBambu(p, gcode: data, print: print)
            return
        }
        let base = (model.name as NSString).deletingPathExtension
        let name = (base.isEmpty ? "plate" : base) + ".gcode"
        sendState = print ? "Sending to \(p.name)…" : "Uploading to \(p.name)…"
        Task { @MainActor in
            let r = await PrinterLink.send(p, filename: name, gcode: data, print: print)
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
        let base = (model.name as NSString).deletingPathExtension
        let title = base.isEmpty ? "plate" : base
        let file = title.replacingOccurrences(of: " ", with: "_") + ".gcode.3mf"
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard gcode.withUnsafeBytes({ zs_bambu_file($0.bindMemory(to: UInt8.self).baseAddress, $0.count, title, &out, &len) }) == 0, let out else {
            sendState = "The file for the printer did not build"
            return
        }
        let bytes = Data(bytes: out, count: len)
        zs_buffer_free(out, len)
        sendState = "Uploading to \(p.name)…"
        Task { @MainActor in
            var pinned: String?
            do {
                try await BambuLink.upload(p, name: file, data: bytes, pinned: &pinned)
                if print {
                    sendState = "Starting the print on \(p.name)…"
                    try await BambuLink.start(p, file: file, title: title, gcode: gcode, pinned: &pinned)
                    sendState = "Printing on \(p.name)"
                } else {
                    sendState = "Uploaded to \(p.name)"
                }
                if let pinned { showNote("zslice trusts the certificate of \(p.name) from now on (SHA-256 \(pinned.prefix(11))…)", seconds: 8) }
            } catch {
                sendState = error.localizedDescription
                let a = NSAlert()
                a.messageText = print ? "The print did not start" : "The upload failed"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
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
        let data = Data(bytes: out, count: len)
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

    /// Exports the G-code of the last slice with a save panel.
    func exportGcode(from window: NSWindow?) {
        guard let data = model.gcode() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gcode]
        let base = (model.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "plate" : base) + ".gcode"
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
        case .turn, .move:
            // A click on a part selects it; a click on a line selects it too.
            if let i = partAt(p) { selectPart(i) } else { selectPart(nil); pick(at: p) }
        case .select:
            pick(at: p)
        }
    }
    func sliceViewPress(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> Bool { press(p, flags) }
    func sliceViewDrag(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) { drag(p, flags) }
    func sliceViewRelease(_ p: CGPoint) { release(p) }
    func sliceViewTurnWheel(_ dy: CGFloat) -> Bool { turnWheel(dy) }
    func sliceViewMenu(_ p: CGPoint) -> NSMenu? { contextMenu(at: p) }
    func sliceViewDidDraw() { if !tape.isEmpty { placeTape() } }
    func sliceViewDoubleClick(_ p: CGPoint) -> Bool { lookAtSide(p) }

    func sliceViewTick(_ dt: Double) -> Bool { stepReplay(dt) }

    func sliceViewAppearanceChanged() {
        if model.state == .done { canvas.load(model.core); applyRange() }
    }

    /// The keys of the preview (docs/user/getting-started.md, "Keys in the
    /// preview"), for the case with no selected line.
    func sliceViewKey(_ event: NSEvent) -> Bool {
        if turnKey(event) { return true }
        if selection == nil, partKey(event) { return true }
        if event.charactersIgnoringModifiers == "\u{1b}", !tape.isEmpty {
            clearTape()
            return true
        }
        if selectionKey(event) { return true }
        // The keys of the tools (with no modifier).
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let t = Tool.allCases.first(where: { $0.key == event.charactersIgnoringModifiers }) {
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
            case "h": scrubStep(-0.02)
            case "l": scrubStep(0.02)
            case "C" where shift: setRange(lo: 0, hi: layerCount - 1)
            case "n" where !shift: showSettings.toggle()
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
