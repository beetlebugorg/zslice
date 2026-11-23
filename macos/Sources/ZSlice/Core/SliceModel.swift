//! SliceModel: the plates of a window, over one plate set of the core
//! (zs_set, src/app/plate_set.zig), and the active plate.
//!
//! Each plate has its own zs_app: its own settings, parts, undo list, and
//! slice. The active plate is the plate that the window shows and
//! changes; `core` is its app. The set slices the other plates in the
//! background, one at a time, so the view shows all plates in a row.
//!
//! The core slices on its own threads and calls the event function there.
//! The event function only moves the event to the main queue. All calls
//! into the core run on the main thread, as include/zslice-app.h asks.
//!
//! A change of a plate calls zs_set_changed: the active plate slices again
//! at once (a slice that runs stops first), so the view always shows the
//! current settings, and the main thread never waits for a slice. During a
//! drag of a part, zs_set_changed_held, and zs_set_release at the end: the
//! part slices once.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Foundation
import Observation

/// Takes the events of the core from its threads to the main queue. The
/// core holds an unretained pointer to it, and zs_set_free stops the slices
/// before the model releases it.
private final class EventBridge: @unchecked Sendable {
    weak var model: SliceModel?

    func post(_ plate: Int, _ event: Int32, _ progress: Double, _ status: Int32) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.model?.handle(plate: plate, event: event, progress: progress, status: status) }
        }
    }
}

private func onSetEvent(user: UnsafeMutableRawPointer?, plate: Int, event: Int32, progress: Double, status: Int32) {
    guard let user else { return }
    Unmanaged<EventBridge>.fromOpaque(user).takeUnretainedValue().post(plate, event, progress, status)
}

/// One plate of the set, for the plate bar.
struct PlateInfo: Identifiable, Equatable {
    var id: UInt64
    var status: Int32
    var name: String
    var bedX: Double, bedY: Double
    var parts: Int
    var message: String
}

@MainActor
@Observable
final class SliceModel {
    enum State: Equatable {
        case empty, ready, slicing, done, failed(String)
    }

    @ObservationIgnored let set: OpaquePointer
    @ObservationIgnored private let bridge: Unmanaged<EventBridge>

    /// The app of the active plate.
    var core: OpaquePointer { zs_set_app(set, active)! }

    private(set) var plates: [PlateInfo] = []
    private(set) var active = 0
    var name = ""
    /// What the editors change (Settings.swift).
    var scope = SettingScope.print {
        didSet { settingsGeneration += 1 }
    }
    /// The open project, or nil (Project.swift).
    var project: ProjectState?
    private(set) var state = State.empty
    private(set) var progress = 0.0
    private(set) var stats: zs_stats?
    /// Counts the changes of the settings, so a view that shows a value
    /// reads it again.
    var settingsGeneration = 0
    /// The undo list of each plate, by the id of the plate.
    @ObservationIgnored private var histories: [UInt64: History] = [:]
    /// Runs on the main thread after each new slice of the active plate.
    @ObservationIgnored var onSliced: (() -> Void)?
    /// The simulated print of the last slice of the active plate is in the
    /// toolpaths (zs_app_sim_adopt).
    @ObservationIgnored var onSimulated: (() -> Void)?
    /// True while a drag, a hold, or a fall slices live: a simulation then
    /// waits, so the view does not switch between the plan and the plastic
    /// under the pointer. The slice at the end brings its own.
    @ObservationIgnored var holdSimulation: (() -> Bool)?
    /// Runs on the main thread after a change of the plates, or a new slice
    /// of another plate (the view shows the row again).
    @ObservationIgnored var onPlates: (() -> Void)?
    /// Runs on the main thread after another plate became active.
    @ObservationIgnored var onActivePlate: (() -> Void)?
    /// After a change of a setting or of the plates: the window checks
    /// for a part that cannot stand now (zs_app_fall_pending).
    @ObservationIgnored var onChanged: (() -> Void)?
    /// The selection and focus model of the core, next to the set.
    @ObservationIgnored let sel: OpaquePointer

    init() {
        let b = EventBridge()
        bridge = Unmanaged.passRetained(b)
        var s: OpaquePointer?
        let rc = zs_set_new(onSetEvent, bridge.toOpaque(), &s)
        guard rc == 0, let s else { fatalError("zslice: zs_set_new failed: \(statusName(rc))") }
        set = s
        var m: OpaquePointer?
        guard zs_sel_new(&m) == 0, let m else { fatalError("zslice: zs_sel_new failed") }
        sel = m
        b.model = self
        readPlates()
        // The settings of the last session (SavedSettings.swift); a test
        // run (ZSLICE_FRESH=1) starts from the defaults.
        if SavedSettings.enabled { SavedSettings.load(into: core) }
        autoSimulate()
    }

    /// The print as it forms after each slice of the active plate, on the
    /// thread of the slice (docs/internals/print-sim.md). A change stops it,
    /// and ZS_EVENT_SIMULATED tells when it is ready.
    private func autoSimulate() {
        // ZSLICE_NO_SIM=1: the plan only, to compare.
        zs_app_set_auto_simulate(core, ProcessInfo.processInfo.environment["ZSLICE_NO_SIM"] == nil ? 1 : 0)
    }

    /// After a change of the set. scene: the view has loaded this slice
    /// (docs/internals/selection.md).
    func syncSelection(scene: Bool = false) {
        zs_sel_sync(sel, set, scene ? 1 : 0)
    }

    isolated deinit {
        zs_sel_free(sel)
        zs_set_free(set)
        bridge.release()
    }

    /// The document of the window: its UndoManager has the steps of the
    /// active plate, and a save writes the plates.
    @ObservationIgnored weak var document: NSDocument? {
        didSet {
            history.attach()
            refreshSaveBytes()
        }
    }
    /// The time of the last open or save of the window: the count of the
    /// history button starts there. Before one (a session that comes
    /// back), each change counts.
    private(set) var savedAt = Date.distantPast

    func markSaved() { savedAt = Date() }

    /// Why the slice of the active plate failed (the short line, a line
    /// feed, then what to do), or nil.
    var failure: String? {
        if case let .failed(why) = state { return why }
        return nil
    }

    /// Why the plate cannot print, or nil (zs_app_plate_printable). A part
    /// that does not fit still slices and shows, but Export and Print stay
    /// off, and the core refuses its G-code.
    private(set) var unprintable: String?

    func readPrintable() {
        var buf = [CChar](repeating: 0, count: 1024)
        var len = 0
        let rc = zs_app_plate_printable(core, &buf, buf.count, &len)
        let why = rc == Int32(ZS_PART_TOO_LARGE.rawValue) ? String(cString: buf) : nil
        if why != unprintable { unprintable = why }
        // ZSLICE_FIT_LOG=1: the reason, and whether Export is on.
        if ProcessInfo.processInfo.environment["ZSLICE_FIT_LOG"] != nil {
            NSLog("zslice fit: export %d, gcode %d, %@", canExport ? 1 : 0, gcode() == nil ? 0 : 1, why ?? "fits")
        }
    }

    /// The project file of the plates for a save (ProjectFile.swift).
    @ObservationIgnored let saveBytes = SaveBytes()
    @ObservationIgnored var saveBytesDue = false
    @ObservationIgnored var saveBytesTimer: DispatchWorkItem?
    @ObservationIgnored var saveBytesBusy = false

    /// The undo list of the active plate.
    var history: History {
        let id = plates.indices.contains(active) ? plates[active].id : 0
        if let h = histories[id] { return h }
        let h = History(model: self)
        histories[id] = h
        return h
    }

    // MARK: - the plates

    func readPlates() {
        scheduleSaveBytes()
        active = zs_set_active(set)
        syncSelection()
        plates = (0 ..< zs_set_count(set)).compactMap { i in
            var p = zs_plate_info()
            guard zs_set_plate_info(set, i, &p) == 0 else { return nil }
            return PlateInfo(id: p.id, status: p.status, name: coreText(p.name), bedX: p.bed_x, bedY: p.bed_y,
                             parts: p.part_count, message: coreText(p.message))
        }
        let ids = Set(plates.map(\.id))
        histories = histories.filter { ids.contains($0.key) }
    }

    /// The state of the active plate from its app, after it became active.
    private func readActive() {
        scope = .print
        autoSimulate()
        switch Int(zs_app_state(core)) {
        case Int(ZS_STATE_EMPTY.rawValue): state = .empty
        case Int(ZS_STATE_SLICING.rawValue): state = .slicing
        case Int(ZS_STATE_DONE.rawValue): state = .done
        case Int(ZS_STATE_FAILED.rawValue): state = .failed(plates.indices.contains(active) ? plates[active].message : "")
        default: state = .ready
        }
        var s = zs_stats()
        stats = zs_app_stats(core, &s) == 0 ? s : nil
        name = plates.indices.contains(active) ? plates[active].name : ""
        settingsGeneration += 1
        history.attach()
    }

    /// Makes plate i the active plate.
    func select(_ i: Int) {
        guard i != active, i >= 0, i < plates.count else { return }
        settle()
        history.commit()
        zs_sel_plate_request(sel, i)
        zs_set_select(set, i)
        readPlates()
        readActive()
        onActivePlate?()
        onPlates?()
        if state == .done { onSliced?() }
    }

    /// A new empty plate after the others, with the settings of the active
    /// plate. It becomes the active plate.
    func addPlate() {
        history.commit()
        guard zs_set_add(set) >= 0 else { return }
        readPlates()
        readActive()
        onActivePlate?()
        onPlates?()
    }

    /// After a project loads: the new plates, the active plate, and the view.
    func readPlatesAfterLoad() {
        readPlates()
        readActive()
        onActivePlate?()
        onPlates?()
        onChanged?()
    }

    /// Removes plate i (no undo). The plate on its left becomes active.
    func removePlate(_ i: Int) {
        // The exact slice of a draft first: the plate list changes.
        settle()
        let was = active
        zs_set_remove(set, i)
        readPlates()
        readActive()
        if active != was || i == was { onActivePlate?() }
        onPlates?()
        if state == .done { onSliced?() }
    }

    // MARK: - the models

    /// Loads an STL or 3MF file in place of the parts of the active plate.
    func load(name: String, data: Data) throws {
        let isProject = data.withUnsafeBytes { zs_project_file_is($0.bindMemory(to: UInt8.self).baseAddress, $0.count) } == 1
        if isProject {
            try openProjectFile(data)
            return
        }
        let rc = data.withUnsafeBytes { buf in
            zs_app_load_stl(core, name, buf.bindMemory(to: UInt8.self).baseAddress, buf.count)
        }
        guard rc == 0 else { throw CoreError(code: rc) }
        zs_set_name(set, active, name)
        self.name = name
        project = nil
        stats = nil
        state = .ready
        // Opening a file is a step of the history, and the count of the
        // history button starts after it.
        history.noteChange()
        history.commit()
        markSaved()
        requestSlice()
    }

    /// Adds the parts of an STL or 3MF file to the active plate.
    func add(name: String, data: Data) throws {
        let rc = data.withUnsafeBytes { buf in
            zs_app_add_stl(core, name, buf.baseAddress, buf.count)
        }
        guard rc >= 0 else { throw CoreError(code: Int32(rc)) }
        settingsChanged()
    }

    /// After a change of a setting: the views read the values again, and
    /// the plate slices again.
    func settingsChanged() {
        settingsGeneration += 1
        history.noteChange()
        requestSlice()
        onChanged?()
    }

    /// After an undo, a redo, or a jump in the history: the core restored
    /// the settings or the plate. The views read the values again, and the
    /// plate slices again.
    func restored() {
        settingsGeneration += 1
        requestSlice()
    }

    /// A change during a drag of a part: the slice waits for release().
    func changedHeld() {
        liveChange()
        zs_set_changed_held(set, active)
    }

    /// The end of a drag: the plate slices once, exact, with no draft.
    func release() {
        settingsGeneration += 1
        history.noteChange()
        sliceStart = Date()
        stopDraft()
        zs_set_release(set)
    }

    /// A slice during a drag, so the result follows it: the held change
    /// slices now (a draft), and the step of the history stays open until
    /// release().
    func sliceHeldNow() {
        sliceStart = Date()
        zs_set_release(set)
    }

    // MARK: - the draft slices

    /// A change of a plate that has a slice gives a draft first
    /// (zs_app_set_draft: an outline tolerance of 0.05 mm and no gap fill,
    /// in about a third of the time). The exact slice follows 300 ms after
    /// the last change, or at the end of a drag. A plate with no slice yet
    /// (a new model) slices exact at once. A draft has no G-code, so the
    /// print card keeps the numbers of the last exact slice, and Export and
    /// Print wait for the exact one (as the GTK and web apps).
    static let settleDelay = 0.3

    /// A change of the active plate: its next slices are drafts, if it has
    /// a slice; the exact slice comes after the delay.
    private func liveChange() {
        settleTimer?.invalidate()
        settleTimer = nil
        if let d = draftCore, d != core { settle() }
        let st = zs_app_state(core)
        if draftCore == nil, st == Int32(ZS_STATE_DONE.rawValue) || st == Int32(ZS_STATE_SLICING.rawValue) {
            draftCore = core
            zs_app_set_draft(core, 1)
        }
        guard draftCore != nil else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A draft that still runs: the exact slice waits for it, so
                // the view gets the draft.
                if let d = self.draftCore, zs_app_state(d) == Int32(ZS_STATE_SLICING.rawValue) { return }
                self.settle()
            }
        }
    }

    /// Drafts off for the plate that has them, with no slice (the caller
    /// slices).
    private func stopDraft() {
        settleTimer?.invalidate()
        settleTimer = nil
        if let d = draftCore { zs_app_set_draft(d, 0) }
        draftCore = nil
    }

    /// The exact slice of the plate that has a draft. Before a plate goes,
    /// or another plate becomes active, too.
    func settle() {
        settleTimer?.invalidate()
        settleTimer = nil
        guard let app = draftCore else { return }
        draftCore = nil
        zs_app_set_draft(app, 0)
        for i in 0 ..< zs_set_count(set) where zs_set_app(set, i) == app {
            if i == active { sliceStart = Date() }
            zs_set_changed(set, i)
            return
        }
    }

    @ObservationIgnored private var sliceStart = Date()
    /// The app whose next slices are drafts (nil: none), and the timer of
    /// its exact slice.
    @ObservationIgnored private var draftCore: OpaquePointer?
    @ObservationIgnored private var settleTimer: Timer?
    /// The last slice of the active plate is a draft: no G-code yet.
    private(set) var draft = false
    /// Export and Print: a slice that is not a draft.
    var canExport: Bool { state == .done && !draft && unprintable == nil }
    /// The work bar of the view (WorkBar.swift).
    let work = WorkState()
    /// The time of the last slice, from the request to the result.
    private(set) var sliceSeconds: Double?

    func requestSlice() {
        sliceStart = Date()
        liveChange()
        let rc = zs_set_changed(set, active)
        if rc != 0 { state = .failed(statusText(rc)) }
    }

    fileprivate func handle(plate: Int, event: Int32, progress: Double, status: Int32) {
        if event == Int32(ZS_EVENT_PLATES.rawValue) {
            readPlates()
            if plates.indices.contains(active), plates[active].status == ZS_PLATE_STATUS_SLICING.rawValue, state != .slicing {
                state = .slicing
                self.progress = 0
            }
            if plates.indices.contains(active), plates[active].status == ZS_PLATE_STATUS_EMPTY.rawValue {
                state = .empty
                stats = nil
            }
            onPlates?()
            return
        }
        // Another plate: its new slice shows in the row.
        guard plate == active else {
            if event == Int32(ZS_EVENT_SLICED.rawValue) { onPlates?() }
            return
        }
        // An event of an old slice can still come: the state of the core
        // decides.
        switch Int(event) {
        case Int(ZS_EVENT_PROGRESS.rawValue):
            if zs_app_state(core) == Int32(ZS_STATE_SLICING.rawValue) {
                state = .slicing
                self.progress = progress
                work.slicing(draft: zs_app_is_draft(core) == 1, fraction: progress)
            }
        case Int(ZS_EVENT_SLICED.rawValue):
            guard zs_app_state(core) == Int32(ZS_STATE_DONE.rawValue) else { return }
            let isDraft = zs_app_is_draft(core) == 1
            // A draft keeps the numbers of the last exact slice.
            if !isDraft || stats == nil {
                var s = zs_stats()
                stats = zs_app_stats(core, &s) == 0 ? s : nil
            }
            draft = isDraft
            state = .done
            self.progress = 1
            sliceSeconds = Date().timeIntervalSince(sliceStart)
            work.sliced(draft: isDraft, seconds: sliceSeconds ?? 0, model: self)
            if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
                NSLog("zslice timing: sliced in %.3f s%@", sliceSeconds ?? 0, isDraft ? " (draft)" : "")
            }
            onSliced?()
            onPlates?()
            // The copy for a save, after the view shows the slice.
            if saveBytesDue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.flushSaveBytesIfIdle() }
            }
        case Int(ZS_EVENT_SIMULATED.rawValue):
            // The simulation of the slice that shows, on the slice thread:
            // the toolpaths take it on this thread.
            guard zs_app_state(core) == Int32(ZS_STATE_DONE.rawValue), holdSimulation?() != true, zs_app_sim_adopt(core) == 1 else { return }
            onSimulated?()
        case Int(ZS_EVENT_FAILED.rawValue):
            if zs_app_state(core) == Int32(ZS_STATE_FAILED.rawValue) {
                NSLog("zslice: the slice failed: %@", coreText(zs_app_failure_name(core)))
                state = .failed(statusText(status))
                work.stop()
            }
        default:
            break
        }
    }
}

extension SliceModel {
    /// The value of a setting as text ("" if the name is not known).
    func setting(_ name: String) -> String {
        coreString { zs_app_setting_get(core, name, $0, $1, $2) } ?? ""
    }

    /// The G-code of the last slice.
    /// The name of the G-code file of the last slice of plate i (nil: the
    /// active plate), with no extension (zs_app_gcode_name): the model, the
    /// plate with more than one, the layer height, the material, the
    /// printer, and the time, as "3DBenchy_0.2mm_PLA_MK4_50m".
    func gcodeName(plate: Int? = nil) -> String {
        let i = plate ?? active
        guard let app = zs_set_app(set, i) else { return "plate" }
        var p = zs_part()
        let part = zs_app_part_get(app, 0, &p) == 0 ? coreText(p.name) : ""
        let model = part.isEmpty ? name : part
        let n = coreString { zs_app_gcode_name(app, model, plates.count > 1 ? i + 1 : 0, $0, $1, $2) } ?? ""
        return n.isEmpty ? "plate" : n
    }

    /// The G-code of the last slice of plate i.
    func gcode(plate i: Int) -> Data? {
        guard let app = zs_set_app(set, i) else { return nil }
        var ptr: UnsafePointer<UInt8>?
        var len = 0
        guard zs_app_gcode(app, &ptr, &len) == 0, let ptr else { return nil }
        return Data(bytes: ptr, count: len)
    }

    func gcode() -> Data? {
        var ptr: UnsafePointer<UInt8>?
        var len = 0
        guard zs_app_gcode(core, &ptr, &len) == 0, let ptr else { return nil }
        return Data(bytes: ptr, count: len)
    }
}

struct CoreError: LocalizedError {
    let code: Int32
    var errorDescription: String? { statusText(code) }
}
