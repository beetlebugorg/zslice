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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("zslice", isDirectory: true)
    }

    static var globalFile: URL { folder.appendingPathComponent("global.toml") }

    /// Applies the global settings of the user to an app.
    @MainActor
    static func loadGlobal(into core: OpaquePointer) {
        guard let text = try? String(contentsOf: globalFile, encoding: .utf8), !text.isEmpty else { return }
        var message = [CChar](repeating: 0, count: 256)
        let rc = text.withCString { zs_app_global_set(core, $0, strlen($0), &message, message.count) }
        if rc != 0 { NSLog("zslice: global.toml did not load: %@", message.withUnsafeBufferPointer { coreText($0.baseAddress) }) }
    }

    @MainActor
    static func saveGlobal(from core: OpaquePointer) {
        guard ProcessInfo.processInfo.environment["ZSLICE_FRESH"] == nil,
              let text = coreString({ zs_app_global_write(core, $0, $1, $2) }) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: globalFile, atomically: true, encoding: .utf8)
    }

    /// Applies the saved settings to an app.
    @MainActor
    static func load(into core: OpaquePointer) {
        loadGlobal(into: core)
        for g in groups {
            let url = folder.appendingPathComponent(g.file)
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            var message = [CChar](repeating: 0, count: 256)
            let rc = text.withCString { zs_app_profile_apply(core, g.group, $0, strlen($0), &message, message.count) }
            if rc != 0 {
                NSLog("zslice: %@ did not load: %@", g.file, message.withUnsafeBufferPointer { coreText($0.baseAddress) })
                let bad = url.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: url, to: bad)
            }
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
