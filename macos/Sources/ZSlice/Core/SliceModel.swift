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

/// The text of a status code of the core.
func statusText(_ rc: Int32) -> String {
    coreText(zs_status_string(rc))
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
    /// Runs on the main thread after a change of the plates, or a new slice
    /// of another plate (the view shows the row again).
    @ObservationIgnored var onPlates: (() -> Void)?
    /// Runs on the main thread after another plate became active.
    @ObservationIgnored var onActivePlate: (() -> Void)?

    init() {
        let b = EventBridge()
        bridge = Unmanaged.passRetained(b)
        var s: OpaquePointer?
        let rc = zs_set_new(onSetEvent, bridge.toOpaque(), &s)
        guard rc == 0, let s else { fatalError("zslice: zs_set_new failed: \(statusText(rc))") }
        set = s
        b.model = self
        readPlates()
        // The settings of the last session (SavedSettings.swift); a test
        // run (ZSLICE_FRESH=1) starts from the defaults.
        if ProcessInfo.processInfo.environment["ZSLICE_FRESH"] == nil { SavedSettings.load(into: core) }
    }

    isolated deinit {
        zs_set_free(set)
        bridge.release()
    }

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
        active = zs_set_active(set)
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
    }

    /// Makes plate i the active plate.
    func select(_ i: Int) {
        guard i != active, i >= 0, i < plates.count else { return }
        history.commit()
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
    }

    /// Removes plate i (no undo). The plate on its left becomes active.
    func removePlate(_ i: Int) {
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
        // Opening a file is a step of the history.
        history.noteChange()
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
        zs_set_changed_held(set, active)
    }

    /// The end of a drag: the plate slices once.
    func release() {
        settingsGeneration += 1
        history.noteChange()
        sliceStart = Date()
        zs_set_release(set)
    }

    @ObservationIgnored private var sliceStart = Date()
    /// The time of the last slice, from the request to the result.
    private(set) var sliceSeconds: Double?

    func requestSlice() {
        sliceStart = Date()
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
            }
        case Int(ZS_EVENT_SLICED.rawValue):
            guard zs_app_state(core) == Int32(ZS_STATE_DONE.rawValue) else { return }
            var s = zs_stats()
            stats = zs_app_stats(core, &s) == 0 ? s : nil
            state = .done
            self.progress = 1
            sliceSeconds = Date().timeIntervalSince(sliceStart)
            if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
                NSLog("zslice timing: sliced in %.3f s", sliceSeconds ?? 0)
            }
            onSliced?()
            onPlates?()
        case Int(ZS_EVENT_FAILED.rawValue):
            if zs_app_state(core) == Int32(ZS_STATE_FAILED.rawValue) { state = .failed(statusText(status)) }
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
