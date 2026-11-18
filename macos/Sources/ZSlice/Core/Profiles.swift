//! The Filament and Quality profiles (docs/user/getting-started.md,
//! "Printer, filament, and quality"): the built-in profiles of the core
//! (zs_builtin_profile_*) and the profiles of the user, in
//! ~/Library/Application Support/zslice/profiles/filament and
//! profiles/project, as profile texts of the core.
//!
//! A filament: the group goes back to the defaults, then the profile
//! applies (zs_app_group_reset, zs_app_profile_apply); the diameter stays,
//! as it is a property of the printer. A quality: zs_app_quality_set, which
//! keeps the changes of this print on top. Save as Profile writes the
//! group of the plate (zs_app_profile_write) to a file of the user, and a
//! saved quality is then the quality of the plate.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Foundation

enum Profiles {
    static let filament = Int32(ZS_GROUP_FILAMENT.rawValue)
    static let quality = Int32(ZS_GROUP_PROJECT.rawValue)

    static func folder(_ group: Int32) -> URL {
        SavedSettings.folder.appendingPathComponent("profiles").appendingPathComponent(group == filament ? "filament" : "project")
    }

    static func builtin(_ group: Int32) -> [String] {
        (0 ..< zs_builtin_profile_count(group)).map { coreText(zs_builtin_profile_name(group, $0)) }
    }

    /// The names of the profiles of the user (the file names).
    static func mine(_ group: Int32) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder(group).path)) ?? []
        return files.filter { $0.hasSuffix(".toml") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func text(of name: String, group: Int32) -> String? {
        try? String(contentsOf: folder(group).appendingPathComponent(name + ".toml"), encoding: .utf8)
    }
}

extension SliceModel {
    /// The material of the filament of the plate, in upper case ("PLA").
    var materialName: String {
        _ = settingsGeneration
        return setting("filament.material").uppercased()
    }

    var qualityName: String {
        _ = settingsGeneration
        return coreText(zs_app_quality_name(core))
    }

    /// A filament profile: a built-in name, or a text of the user. The
    /// diameter stays.
    @discardableResult
    func useFilament(name: String, text: String? = nil) -> String? {
        let diameter = setting("filament.diameter")
        let body = (text ?? "extends = \"\(name)\"\n") + (diameter.isEmpty ? "" : "\ndiameter = \(diameter)\n")
        zs_app_group_reset(core, Profiles.filament)
        var message = [CChar](repeating: 0, count: 256)
        let rc = body.withCString { zs_app_profile_apply(core, Profiles.filament, $0, strlen($0), &message, message.count) }
        guard rc == 0 else { return message.withUnsafeBufferPointer { coreText($0.baseAddress) } }
        settingsChanged()
        return nil
    }

    /// A quality profile; the changes of this print stay on top.
    @discardableResult
    func useQuality(name: String, text: String? = nil) -> String? {
        let body = text ?? "extends = \"\(name)\"\n"
        var message = [CChar](repeating: 0, count: 256)
        let rc = body.withCString { zs_app_quality_set(core, name, $0, strlen($0), true, &message, message.count) }
        guard rc == 0 else { return message.withUnsafeBufferPointer { coreText($0.baseAddress) } }
        settingsChanged()
        return nil
    }

    /// Saves the filament or the quality of the plate as a profile of the
    /// user. A saved quality is then the quality of the plate, with no
    /// changes on top.
    func saveProfile(group: Int32, name: String) throws {
        guard let text = coreString({ zs_app_profile_write(core, group, $0, $1, $2) }) else {
            throw CoreError(code: Int32(ZS_INVALID_VALUE.rawValue))
        }
        try FileManager.default.createDirectory(at: Profiles.folder(group), withIntermediateDirectories: true)
        try text.write(to: Profiles.folder(group).appendingPathComponent(name + ".toml"), atomically: true, encoding: .utf8)
        if group == Profiles.quality {
            var message = [CChar](repeating: 0, count: 256)
            _ = text.withCString { zs_app_quality_set(core, name, $0, strlen($0), false, &message, message.count) }
            settingsChanged()
        }
    }
}

/// Asks for the name of a new profile.
@MainActor
func askProfileName(_ title: String) -> String? {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = "The profile is saved in your profiles, and the menu lists it."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "my-profile"
    a.accessoryView = field
    a.addButton(withTitle: "Save")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = field
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
    return name.isEmpty ? nil : name
}
