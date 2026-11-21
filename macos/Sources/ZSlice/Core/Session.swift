//! The session of the app: after Command-Q, or a crash, the app comes back
//! exactly as it was, with each window, its plates, the last scene of each
//! plate, the camera, and the state of the window (zs_session_write and
//! zs_session_read).
//!
//! The files are in Application Support/zslice/session: one session file
//! for each window (the zip of the core, with the window state as its app
//! text), and index.json with the order of the windows. Each file is
//! written to a temporary file first, then renamed, so a crash never
//! leaves half a file.
//!
//! Two files for each window: the session file of the core (the plates
//! and their scenes) and a small view file (the camera and the state of
//! the window, as JSON). The view file comes 1 s after a move of the
//! camera, the page, or the layers, on the main thread: it is small. The
//! session file comes only after a change of the plates or a new slice,
//! 1.5 s after the last one and not while a slice runs, on a background
//! queue (the core reads the set under its lock). At a quit, the app
//! writes both once more before the windows close.
//!
//! At launch, the first window takes the first session, and the app opens
//! a window for each other one. The view shows the last scene of the
//! active plate and the camera at once; the slices run after it.
//!
//! No file is written until each session of the last run is back in its
//! window: a window takes its session, then waits for its NSWindow before
//! it restores it, and a write in that time listed no window with plates
//! and removed the files of the last run. A change in that time writes
//! once after the last restore (web/app/session.js does the same).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import QuartzCore

/// The state of a window, besides its plates: the app text of the session.
struct WindowState: Codable {
    var frame: [Double]?
    var page: String?
    var lo: Int?, hi: Int?
    var tool: String?
    var colorMode: Int?
    var showSettings: Bool?
    var historyOpen: Bool?
    var farmOpen: Bool?
    var selectedPart: Int?
    /// The file of the document, if it has one, and its unsaved changes.
    var file: String?
    var edited: Bool?
    var name: String?
    /// The camera (8 floats of zs_view_get_camera), in the view file.
    var camera: [Float]?
    /// The ids of the projects of the plates in the store of refinements.
    var refineIDs: [String: String]?
}

@MainActor
final class SessionStore {
    static let shared = SessionStore()

    /// The time of the start of the app, for the time of the first frame.
    static var launch: CFTimeInterval { launchTime }

    private struct Entry {
        weak var workspace: Workspace?
        let id: String
    }

    /// A session of the last run: the plates, and the newer view state.
    struct Pending {
        var plates: Data
        var view: WindowState?
    }

    private var windows: [Entry] = []
    /// The sessions of the last run that no window has taken yet.
    private(set) var pending: [Pending] = []
    private var platesTimer: DispatchWorkItem?
    private var viewTimer: DispatchWorkItem?
    /// The plates changed since the last write of the session files.
    private var platesDirty = false
    /// The sessions that a window took and has not restored yet.
    private var restoring = 0
    /// A write came before the last restore: it comes after it.
    private var writeAfterRestore = false
    /// Each session of the last run is back in its window: writes may go.
    private var restored: Bool { pending.isEmpty && restoring == 0 }
    /// A write of the session files runs on `queue`.
    private var writing = false
    private let queue = DispatchQueue(label: "zslice.session", qos: .utility)
    private var terminating = false
    private let timing = ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil
    private let off = ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil
        && ProcessInfo.processInfo.environment["ZSLICE_SESSION"] == nil

    private var folder: URL {
        if let d = ProcessInfo.processInfo.environment["ZSLICE_SESSION"] { return URL(fileURLWithPath: d) }
        return SavedSettings.folder.appendingPathComponent("session")
    }

    private init() {
        guard !off else { return }
        // The sessions of the last run, in the order of their windows.
        let index = folder.appendingPathComponent("index.json")
        guard let d = try? Data(contentsOf: index), let ids = try? JSONDecoder().decode([String].self, from: d) else { return }
        pending = ids.compactMap { id in
            guard let plates = try? Data(contentsOf: folder.appendingPathComponent("\(id).zss")) else { return nil }
            let view = (try? Data(contentsOf: folder.appendingPathComponent("\(id).json"))).flatMap { try? JSONDecoder().decode(WindowState.self, from: $0) }
            return Pending(plates: plates, view: view)
        }
    }

    // MARK: - the windows

    func register(_ ws: Workspace) {
        windows.removeAll { $0.workspace == nil }
        guard !windows.contains(where: { $0.workspace === ws }) else { return }
        windows.append(Entry(workspace: ws, id: UUID().uuidString))
    }

    /// A window that the user closed leaves the session (not at a quit).
    func closed(_ ws: Workspace) {
        guard !terminating else { return }
        windows.removeAll { $0.workspace == nil || $0.workspace === ws }
        changedView()
    }

    /// Each session of the last run is back in its window (for a link).
    var isRestored: Bool { restored }

    /// The workspace of a window, and the first window.
    func workspace(of w: NSWindow) -> Workspace? {
        windows.first { $0.workspace?.canvas.window === w }?.workspace
    }

    var firstWorkspace: Workspace? { windows.lazy.compactMap(\.workspace).first }

    /// The next session of the last run, for a new window.
    func takePending() -> Pending? {
        guard !pending.isEmpty else { return nil }
        restoring += 1
        return pending.removeFirst()
    }

    /// The window that took a session restored it, or gave up. After the
    /// last restore, a write that waited comes.
    func restoreDone() {
        restoring = max(0, restoring - 1)
        if restored, writeAfterRestore {
            writeAfterRestore = false
            changed()
        }
    }

    // MARK: - the writes

    /// The plates changed (an edit, a new slice): the session files, 1.5 s
    /// after the last change, on a background queue.
    func changed() {
        guard !off, !terminating else { return }
        platesDirty = true
        platesTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writePlatesWhenIdle() }
        platesTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
        changedView()
    }

    /// The camera, the page, or the layers moved: the small view files, 1 s
    /// after the last change. The session files stay.
    func changedView() {
        guard !off, !terminating else { return }
        viewTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeViews() }
        viewTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func writePlatesWhenIdle() {
        guard platesDirty else { return }
        guard restored else {
            writeAfterRestore = true
            return
        }
        if writing || windows.contains(where: { $0.workspace?.model.state == .slicing }) {
            changed()
            return
        }
        platesDirty = false
        writing = true
        // The state of each window comes from the main thread; the core
        // writes the files on the queue (it reads each set under its lock).
        let jobs = windows.compactMap { e -> (String, SliceModel, String, [Float]?)? in
            guard let ws = e.workspace else { return nil }
            let (text, cam) = ws.sessionState()
            return (e.id, ws.model, text, cam)
        }
        let folder = folder
        let timing = timing
        queue.async {
            let t = CACurrentMediaTime()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var ok = true
            for (id, model, text, cam) in jobs {
                guard let bytes = Self.sessionFile(model.set, text, cam),
                      Self.atomicWrite(bytes, to: folder.appendingPathComponent("\(id).zss")) else {
                    ok = false
                    continue
                }
            }
            if timing { NSLog("zslice session: wrote %d session files in %.0f ms (background)%@", jobs.count, (CACurrentMediaTime() - t) * 1000, ok ? "" : ", with an error") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.writing = false
                    // A failed write comes again with the next change.
                    if !ok { self.platesDirty = true }
                    self.writeViews()
                }
            }
        }
    }

    /// The view file of each window, and the index (main thread: small).
    @discardableResult
    private func writeViews() -> Bool {
        guard !off else { return false }
        guard restored else {
            writeAfterRestore = true
            return false
        }
        windows.removeAll { $0.workspace == nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var all = true
        var ids: [String] = []
        for e in windows {
            guard let ws = e.workspace else { continue }
            var state = ws.windowState()
            state.camera = ws.camera()
            guard let d = try? JSONEncoder().encode(state), Self.atomicWrite(d, to: folder.appendingPathComponent("\(e.id).json")) else {
                all = false
                continue
            }
            // A window whose session file is not written yet waits for it.
            if fm.fileExists(atPath: folder.appendingPathComponent("\(e.id).zss").path) { ids.append(e.id) }
        }
        if let d = try? JSONEncoder().encode(ids), Self.atomicWrite(d, to: folder.appendingPathComponent("index.json")) {} else { all = false }
        // The files of windows that are gone.
        let live = Set(windows.map(\.id))
        for f in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".zss") || f.hasSuffix(".json") {
            let id = (f as NSString).deletingPathExtension
            if id != "index", !live.contains(id) { try? fm.removeItem(at: folder.appendingPathComponent(f)) }
        }
        return all
    }

    /// At a quit, on the main thread: the session files if the plates
    /// changed, then the view files. Returns false if a write failed.
    private func writeAllNow() -> Bool {
        guard !off, restored else { return false }
        platesTimer?.cancel()
        viewTimer?.cancel()
        queue.sync {}
        var all = true
        if platesDirty || windows.contains(where: { e in !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(e.id).zss").path) }) {
            platesDirty = false
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let t = CACurrentMediaTime()
            for e in windows {
                guard let ws = e.workspace else { continue }
                let (text, cam) = ws.sessionState()
                guard let bytes = Self.sessionFile(ws.model.set, text, cam),
                      Self.atomicWrite(bytes, to: folder.appendingPathComponent("\(e.id).zss")) else {
                    all = false
                    continue
                }
            }
            if timing { NSLog("zslice session: wrote the session files at the quit in %.0f ms", (CACurrentMediaTime() - t) * 1000) }
        }
        return writeViews() && all
    }

    /// The text of index.json, for a test.
    func indexText() -> String {
        (try? String(contentsOf: folder.appendingPathComponent("index.json"), encoding: .utf8)) ?? "none"
    }

    /// At a quit: one last write, and no window leaves the session.
    func terminate() {
        guard !off, !terminating else { return }
        _ = writeAllNow()
        terminating = true
    }

    /// Command-Q, and the Quit of the Dock or of a logout: the session
    /// keeps the unsaved changes of each window, so the app quits with no
    /// "Save changes?" alert. If the write fails, the alerts come as usual.
    func quit() {
        if !off, !terminating {
            let ok = writeAllNow()
            terminating = true
            if ok { for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared) } }
        }
        NSApp.terminate(nil)
    }

    /// The session file of a set (any thread).
    nonisolated private static func sessionFile(_ set: OpaquePointer, _ text: String, _ cam: [Float]?) -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = cam.map { zs_session_write(set, $0, text, &out, &len) } ?? zs_session_write(set, nil, text, &out, &len)
        guard rc == 0, let out else { return nil }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
    }

    nonisolated private static func atomicWrite(_ d: Data, to url: URL) -> Bool {
        let tmp = url.appendingPathExtension("tmp")
        let fm = FileManager.default
        do {
            try d.write(to: tmp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

extension Workspace {
    /// The state of this window, besides its plates and its camera.
    func windowState() -> WindowState {
        var state = WindowState()
        if let f = canvas.window?.frame { state.frame = [f.minX, f.minY, f.width, f.height] }
        state.page = page.rawValue
        state.lo = lo
        state.hi = hi
        state.tool = tool.rawValue
        state.colorMode = colorMode
        state.showSettings = showSettings
        state.historyOpen = historyOpen
        state.farmOpen = farmOpen
        state.selectedPart = selectedPart
        state.refineIDs = refineIDs
        if let doc = model.document {
            state.file = doc.fileURL?.path
            state.edited = doc.isDocumentEdited
            state.name = doc.displayName
        }
        return state
    }

    /// The camera of the view (8 floats of zs_view_get_camera), or nil.
    func camera() -> [Float]? {
        guard let v = canvas.view else { return nil }
        var cam = [Float](repeating: 0, count: 8)
        zs_view_get_camera(v, &cam)
        return cam
    }

    /// The app text and the camera for the session file.
    func sessionState() -> (String, [Float]?) {
        let text = (try? JSONEncoder().encode(windowState())).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return (text, camera())
    }

    /// Puts a session back into this window. Returns the state of the
    /// window for its document (its file, its unsaved changes).
    @discardableResult
    func restoreSession(_ session: SessionStore.Pending) -> WindowState? {
        let bytes = session.plates
        var cam = [Float](repeating: 0, count: 8)
        var hasCamera: Int32 = 0
        var text: UnsafeMutablePointer<UInt8>?
        var textLen = 0
        var message = [CChar](repeating: 0, count: 512)
        restoring = true
        let t0 = CACurrentMediaTime()
        defer {
            restoring = false
            if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
                NSLog("zslice session: read in %.0f ms, started at %.0f ms", (CACurrentMediaTime() - t0) * 1000, (t0 - SessionStore.launch) * 1000)
            }
        }
        let rc = bytes.withUnsafeBytes {
            zs_session_read(model.set, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &cam, &hasCamera, &text, &textLen, &message, message.count)
        }
        guard rc == 0 else {
            NSLog("zslice session: %@", message.withUnsafeBufferPointer { coreText($0.baseAddress) })
            return nil
        }
        var state = WindowState()
        if let text {
            if let s = try? JSONDecoder().decode(WindowState.self, from: Data(bytes: text, count: textLen)) { state = s }
            zs_buffer_free(text, textLen)
        }
        // The view file is newer than the session file: its state wins.
        if let v = session.view {
            state = v
            if let c = v.camera, c.count == 8 {
                cam = c
                hasCamera = 1
            }
        }
        model.readPlatesAfterLoad()
        // The window as it was.
        if let p = state.page.flatMap(MetalSliceView.Page.init) { page = p }
        if let t = state.tool.flatMap(Tool.init) { setTool(t) }
        if let m = state.colorMode { colorMode = m }
        if let s = state.showSettings { showSettings = s }
        historyOpen = state.historyOpen ?? false
        farmOpen = state.farmOpen ?? false
        if let lo = state.lo, let hi = state.hi { restoredRange = (lo, hi) }
        restoredPart = state.selectedPart
        if let ids = state.refineIDs { refineIDs = ids }
        // The last scene of the active plate, at once, and the camera.
        if let v = canvas.view {
            zs_view_set_mode(v, Int32(colorMode))
            var p: UnsafePointer<UInt8>?
            var n = 0
            if zs_set_plate_scene(model.set, model.active, &p, &n) == 0, let p {
                if zs_view_scene_read(v, p, n) == 0 { canvas.sceneLoaded() }
                if let lo = state.lo, let hi = state.hi { zs_view_set_layer_range(v, lo, hi) }
            }
            syncPlates()
            if hasCamera != 0 { zs_view_set_camera(v, cam) }
            canvas.requestFrame()
        }
        if let f = state.frame, f.count == 4, let w = canvas.window {
            w.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: true)
        }
        return state
    }
}
