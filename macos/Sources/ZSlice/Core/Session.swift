//! The session of the app: after Command-Q, or a crash, the app comes back
//! exactly as it was, with each window, its plates, the last scene of each
//! plate, the camera, and the state of the window (zs_session_write and
//! zs_session_read; specs: session restore).
//!
//! The files are in Application Support/zslice/session: one session file
//! for each window (the zip of the core, with the window state as its app
//! text), and index.json with the order of the windows. Each file is
//! written to a temporary file first, then renamed, so a crash never
//! leaves half a file.
//!
//! When: 1.5 s after the last change of a window (a change of the plates,
//! a new slice, a move of the camera, a change of the page, the layers,
//! the tool), and not while a slice runs. The core writes all meshes, so
//! the write waits for the window to be idle. At a quit, the app writes
//! once more before the windows close.
//!
//! At launch, the first window takes the first session, and the app opens
//! a window for each other one. The view shows the last scene of the
//! active plate and the camera at once; the slices run after it.
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
}

@MainActor
final class SessionStore {
    static let shared = SessionStore()

    /// The time of the start of the app, for the time of the first frame.
    static let launch = CACurrentMediaTime()

    private struct Entry {
        weak var workspace: Workspace?
        let id: String
    }

    private var windows: [Entry] = []
    /// The sessions of the last run that no window has taken yet.
    private(set) var pending: [Data] = []
    private var timer: DispatchWorkItem?
    private var terminating = false
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
        pending = ids.compactMap { try? Data(contentsOf: folder.appendingPathComponent("\($0).zss")) }
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
        changed()
    }

    /// The next session of the last run, for a new window.
    func takePending() -> Data? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    // MARK: - the writes

    /// A change: a write when the windows are idle.
    func changed() {
        guard !off, !terminating else { return }
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeIfIdle() }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func writeIfIdle() {
        if windows.contains(where: { $0.workspace?.model.state == .slicing }) {
            changed()
            return
        }
        write()
    }

    /// At a quit: one last write, and no window leaves the session.
    func terminate() {
        guard !off, !terminating else { return }
        timer?.cancel()
        write()
        terminating = true
    }

    /// Command-Q, and the Quit of the Dock or of a logout: the session
    /// keeps the unsaved changes of each window, so the app quits with no
    /// "Save changes?" alert. If the write fails, the alerts come as usual.
    func quit() {
        if !off, !terminating {
            timer?.cancel()
            let ok = write()
            terminating = true
            if ok { for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared) } }
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private func write() -> Bool {
        // A session of the last run that no window took stays (a launch
        // with a file opens no empty window).
        guard pending.isEmpty else { return false }
        var all = true
        windows.removeAll { $0.workspace == nil }
        let t = CACurrentMediaTime()
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var ids: [String] = []
        for e in windows {
            guard let ws = e.workspace else { continue }
            guard let bytes = ws.sessionBytes(), atomicWrite(bytes, to: folder.appendingPathComponent("\(e.id).zss")) else {
                all = false
                continue
            }
            ids.append(e.id)
        }
        if let d = try? JSONEncoder().encode(ids), atomicWrite(d, to: folder.appendingPathComponent("index.json")) {} else { all = false }
        // The files of windows that are gone.
        for f in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".zss") {
            if !ids.contains(String(f.dropLast(4))) { try? fm.removeItem(at: folder.appendingPathComponent(f)) }
        }
        if ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
            NSLog("zslice session: wrote %d windows in %.0f ms", ids.count, (CACurrentMediaTime() - t) * 1000)
        }
        return all
    }

    private func atomicWrite(_ d: Data, to url: URL) -> Bool {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try d.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

extension Workspace {
    /// The session of this window: its plates, scenes, camera, and state.
    func sessionBytes() -> Data? {
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
        if let doc = model.document {
            state.file = doc.fileURL?.path
            state.edited = doc.isDocumentEdited
            state.name = doc.displayName
        }
        let text = (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var cam = [Float](repeating: 0, count: 8)
        if let v = canvas.view { zs_view_get_camera(v, &cam) }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let rc = canvas.view == nil
            ? zs_session_write(model.set, nil, text, &out, &len)
            : zs_session_write(model.set, cam, text, &out, &len)
        guard rc == 0, let out else { return nil }
        defer { zs_buffer_free(out, len) }
        return Data(bytes: out, count: len)
    }

    /// Puts a session back into this window. Returns the state of the
    /// window for its document (its file, its unsaved changes).
    @discardableResult
    func restoreSession(_ bytes: Data) -> WindowState? {
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
