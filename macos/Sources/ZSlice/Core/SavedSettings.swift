//! The settings stay after a restart (docs/user/getting-started.md, "Your
//! settings stay"). The app keeps the machine, filament, and project
//! settings that differ from the defaults, each as a profile text of the
//! core (zs_app_state_write, with the help of each setting as a comment),
//! in ~/Library/Application Support/zslice: machine.toml, filament.toml,
//! and project.toml. A new window applies them to its first plate
//! (zs_app_profile_apply). The app saves them after each step of the
//! history. A file that does not load is kept with the extension .bad.
//!
//! global.toml has the global settings of the user: project settings for
//! all prints, under the quality profile (zs_app_global_set). The Global
//! scope of the drawer changes them, and saves the file at once.
//!
//! Some settings moved to another group (the accelerations of the
//! features are printer settings now). An old text still loads, and the
//! core puts each value in its new group. When the project text or
//! global.toml has such keys (zs_profile_moved), the app saves the groups
//! and global.toml once after the load, in their new form.
//!
//! A test run (ZSLICE_FRESH) neither reads nor writes these files, unless
//! ZSLICE_SETTINGS_DIR gives it a folder of its own.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation

enum SavedSettings {
    static let groups: [(group: Int32, file: String)] = [
        (Int32(ZS_GROUP_MACHINE.rawValue), "machine.toml"),
        (Int32(ZS_GROUP_FILAMENT.rawValue), "filament.toml"),
        (Int32(ZS_GROUP_PROJECT.rawValue), "project.toml"),
    ]

    static var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["ZSLICE_SETTINGS_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("zslice", isDirectory: true)
    }

    /// The files are on: not in a test run, except with a folder of its own.
    static var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ZSLICE_FRESH"] == nil || env["ZSLICE_SETTINGS_DIR"] != nil
    }

    static var globalFile: URL { folder.appendingPathComponent("global.toml") }

    /// Applies the global settings of the user to an app. True if the text
    /// has settings that moved to another group.
    @MainActor
    @discardableResult
    static func loadGlobal(into core: OpaquePointer) -> Bool {
        guard let text = try? String(contentsOf: globalFile, encoding: .utf8), !text.isEmpty else { return false }
        let moved = text.withCString { zs_profile_moved(Int32(ZS_GROUP_PROJECT.rawValue), $0, strlen($0)) } > 0
        var message = [CChar](repeating: 0, count: 256)
        let rc = text.withCString { zs_app_global_set(core, $0, strlen($0), &message, message.count) }
        if rc != 0 { NSLog("zslice: global.toml did not load: %@", message.withUnsafeBufferPointer { coreText($0.baseAddress) }) }
        return moved
    }

    @MainActor
    static func saveGlobal(from core: OpaquePointer) {
        guard enabled,
              let text = coreString({ zs_app_global_write(core, $0, $1, $2) }) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: globalFile, atomically: true, encoding: .utf8)
    }

    /// Applies the saved settings to an app.
    @MainActor
    static func load(into core: OpaquePointer) {
        let globalMoved = loadGlobal(into: core)
        var moved = globalMoved
        for g in groups {
            let url = folder.appendingPathComponent(g.file)
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            if text.withCString({ zs_profile_moved(g.group, $0, strlen($0)) }) > 0 { moved = true }
            var message = [CChar](repeating: 0, count: 256)
            let rc = text.withCString { zs_app_profile_apply(core, g.group, $0, strlen($0), &message, message.count) }
            if rc != 0 {
                NSLog("zslice: %@ did not load: %@", g.file, message.withUnsafeBufferPointer { coreText($0.baseAddress) })
                let bad = url.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: url, to: bad)
            }
        }
        // The values of the moved settings are in their new group now: save
        // the texts once in their new form.
        if moved {
            NSLog("zslice: the accelerations of the features are printer settings now; the saved values moved to the printer")
            save(from: core)
            if globalMoved { saveGlobal(from: core) }
        }
    }

    /// Writes the settings of an app that differ from the defaults.
    @MainActor
    static func save(from core: OpaquePointer) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for g in groups {
            guard let text = coreString({ zs_app_state_write(core, g.group, $0, $1, $2) }) else { continue }
            let url = folder.appendingPathComponent(g.file)
            if (try? String(contentsOf: url, encoding: .utf8)) == text { continue }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The defaults of the window state (the page, the color mode, the panes).
/// A test run (ZSLICE_FRESH) has its own domain, empty at each start, so it
/// never changes the state of the app of the user.
// UserDefaults is thread safe.
nonisolated(unsafe) let prefs: UserDefaults = {
    guard ProcessInfo.processInfo.environment["ZSLICE_FRESH"] != nil else { return .standard }
    let name = "org.beetlebug.zslice.test"
    UserDefaults.standard.removePersistentDomain(forName: name)
    return UserDefaults(suiteName: name) ?? .standard
}()
