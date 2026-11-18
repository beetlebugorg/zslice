//! The settings, as the core describes them: the infos of all settings
//! (zs_setting_get_info), the value of each one in a plate with its source
//! (zs_app_setting_source), and what a setting changes in the toolpaths
//! (zs_setting_get_effect). The shell lists no setting: all of it comes
//! from the core.
//!
//! ValueText writes a value as an editor shows it, and reads an edit back.
//! The rules are in the core (src/app/setting_text.zig): a ratio ("%")
//! shows as a percentage, a line width of 0 shows as "auto", and a unit
//! follows the value.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation
import SwiftUI

/// Calls a core function with the buffer rules of zs_app_setting_get: a
/// first call for the length, then one with a buffer.
func coreString(_ call: (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>?) -> Int32) -> String? {
    var len = 0
    guard call(nil, 0, &len) == 0 else { return nil }
    var buf = [CChar](repeating: 0, count: len + 1)
    guard buf.withUnsafeMutableBufferPointer({ call($0.baseAddress, $0.count, nil) }) == 0 else { return nil }
    return buf.withUnsafeBufferPointer { b in
        String(decoding: UnsafeRawBufferPointer(start: b.baseAddress, count: len), as: UTF8.self)
    }
}

struct SettingInfo: Identifiable, Hashable {
    enum Kind: Int32 { case number = 0, integer, boolean, choice, text }

    let name: String
    let group: String
    let section: String
    let label: String
    let doc: String
    let kind: Kind
    let multiline: Bool
    let choices: [String]
    let unit: String
    let defaultValue: String
    let sliderMin: Double, sliderMax: Double, sliderStep: Double
    let perLayer: Bool, perPart: Bool

    var id: String { name }
    var isNumber: Bool { kind == .number || kind == .integer }
    var isRatio: Bool { isNumber && unit == "%" }
    var hasSlider: Bool { isNumber && sliderMax > sliderMin }

    /// All settings, in the order to show them.
    static let all: [SettingInfo] = (0 ..< zs_setting_count()).compactMap { i in
        var c = zs_setting_info()
        guard zs_setting_get_info(i, &c) == 0 else { return nil }
        return SettingInfo(name: coreText(c.name), group: coreText(c.group), section: coreText(c.section),
                           label: coreText(c.label), doc: coreText(c.doc), kind: Kind(rawValue: c.kind) ?? .text,
                           multiline: c.multiline != 0,
                           choices: coreText(c.choices).split(separator: "\n").map(String.init),
                           unit: coreText(c.unit), defaultValue: coreText(c.default_value),
                           sliderMin: c.slider_min, sliderMax: c.slider_max, sliderStep: c.slider_step,
                           perLayer: c.per_layer != 0, perPart: c.per_part != 0)
    }

    static let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    /// The settings that match a query, best first (zs_setting_search: the
    /// words, their other names, and a boost for the common settings).
    /// partOnly: only the settings that a part can have of its own.
    static func search(_ query: String, partOnly: Bool = false, max: Int = 60) -> [SettingInfo] {
        var out = [UInt32](repeating: 0, count: max)
        let n = zs_setting_search(query, partOnly ? 1 : 0, &out, nil, max)
        return out.prefix(min(n, max)).compactMap { i in
            var c = zs_setting_info()
            guard zs_setting_get_info(Int(i), &c) == 0 else { return nil }
            return byName[coreText(c.name)]
        }
    }

    /// The groups of the settings browser, in order, with their titles.
    static let groups: [(key: String, title: String)] = [
        ("project", "Part"), ("filament", "Filament"), ("machine", "Printer"), ("engine", "Engine"),
    ]

    static func groupTitle(_ g: String) -> String { groups.first { $0.key == g }?.title ?? g }

    /// The step of an editor and a slider, in core units.
    var step: Double {
        sliderStep > 0 ? sliderStep : (kind == .integer ? 1 : (hasSlider ? (sliderMax - sliderMin) / 100 : 0.1))
    }
}

/// What a setting changes in the toolpaths.
struct SettingEffect {
    let features: UInt32
    let firstLayerOnly: Bool
    let note: String

    init(_ name: String) {
        var e = zs_setting_effect()
        if zs_setting_get_effect(name, &e) == 0 {
            features = e.features
            firstLayerOnly = e.first_layer_only != 0
            note = coreText(e.note)
        } else {
            features = 0
            firstLayerOnly = false
            note = ""
        }
    }
}

/// The features of the toolpaths and the marks (enum zs_feature, then
/// ZS_MARK_SEAM and on), with the colors of feature_rgb in
/// src/render/view.zig.
enum Feature {
    static let count = Int(ZS_FEATURE_COUNT)
    static let all = UInt32((1 << count) - 1)
    static let titles = ["Outer wall", "Inner wall", "Skin", "Sparse infill", "Ironing", "Skirt or brim", "Support",
                         "Support interface", "Slope smoothing", "Slope ironing", "Bridge", "Seams", "Travel moves", "Retractions"]
    static let colors: [Color] = [0xd9480f, 0xf59f00, 0x1c7ed6, 0x2b8a3e, 0xae3ec9, 0x8d6e63, 0xadb5bd, 0x495057,
                                  0x0ca6ae, 0x82c91e, 0x66ccf2, 0xe01a26, 0x3373f2, 0xf240bf].map {
        Color(red: Double($0 >> 16 & 0xff) / 255, green: Double($0 >> 8 & 0xff) / 255, blue: Double($0 & 0xff) / 255)
    }
}

/// The value of a setting in a plate, and where it comes from.
struct SettingEntry: Equatable {
    var value: String
    /// enum zs_level: 0 default, 1 global, 2 printer, 3 filament, 4 quality,
    /// 5 this print, 6 this part.
    var level: Int32
    var profile: String
    /// The value that a reset gives.
    var base: String
    /// The formula after "=", or nil.
    var formula: String?

    /// A change of this print or of this part.
    var isMine: Bool { level == 5 || level == 6 }

    /// The level as a tag: "Global", the name of a profile, "This print".
    var sourceText: String {
        coreString { zs_setting_source_text(level, profile, formula, $0, $1, $2) } ?? ""
    }
}

/// The text of setting values, from the core.
enum ValueText {
    static func parsesAsNumber(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && Double(s)?.isFinite == true
    }

    /// A number with no more digits than it needs (%.6g), for a step of
    /// the arrow keys in an editor.
    static func number(_ v: Double) -> String {
        let s = String(format: "%.6g", v)
        return s == "-0" ? "0" : s
    }

    /// The value as an editor shows it.
    static func display(_ info: SettingInfo, _ value: String) -> String {
        coreString { zs_setting_display(info.name, value, 0, $0, $1, $2) } ?? value
    }

    /// The value with its unit: "0.8 mm", "1 layer", "auto".
    static func withUnit(_ info: SettingInfo, _ value: String) -> String {
        coreString { zs_setting_display(info.name, value, 1, $0, $1, $2) } ?? value
    }

    /// The core value of the text of an editor. A number setting with text
    /// that is not a number keeps the text: the core gives its message on set.
    static func toCore(_ info: SettingInfo, _ text: String) -> String {
        coreString { zs_setting_parse(info.name, text, $0, $1, $2) } ?? text
    }
}

extension SliceModel {
    /// The value of a setting and its source.
    /// The value of a setting and its source, in the scope of the editors:
    /// the print, one part (its own value, else the value of the print), or
    /// the layers of a profile (with their overrides).
    func entry(_ name: String) -> SettingEntry {
        _ = settingsGeneration
        let part: Int = if case let .part(i) = scope { i } else { -1 }
        var value = setting(name)
        var level: Int32 = 0
        var profile = [CChar](repeating: 0, count: 256)
        let rc = profile.withUnsafeMutableBufferPointer { zs_app_setting_source(core, part, name, &level, $0.baseAddress, $0.count) }
        if part >= 0, let own = coreString({ zs_app_part_setting_get(core, part, name, $0, $1, $2) }) { value = own }
        let base = coreString { zs_app_setting_base_get(core, name, $0, $1, $2) } ?? value
        let formula = coreString { zs_app_formula_get(core, name, $0, $1, $2) }
        var e = SettingEntry(value: value, level: rc == 0 ? level : 0,
                             profile: rc == 0 ? profile.withUnsafeBufferPointer { coreText($0.baseAddress) } : "",
                             base: base, formula: formula)
        if scope == .global {
            e.value = coreString { zs_app_global_get(core, name, $0, $1, $2) } ?? value
            e.level = 1
        }
        if case .layers = scope, let z = scope.z {
            e.value = coreString { zs_app_setting_get_at(core, z, name, $0, $1, $2) } ?? value
            // A change of these layers shows as "this print" (the accent).
            if zs_app_override_at(core, z, name) != 0 { e.level = 5 }
        }
        return e
    }

    /// Sets a setting in the scope of the editors, and slices again.
    /// Returns the error in words, or nil.
    @discardableResult
    func set(_ name: String, _ value: String) -> String? {
        let rc: Int32
        switch scope {
        case .print:
            rc = zs_app_setting_set(core, name, value)
        case .global:
            guard name.hasPrefix("project.") else { return "This setting is in the printer or the filament profile: it has no global value." }
            rc = setGlobal(name, value)
        case let .part(i):
            rc = zs_app_part_setting_set(core, i, name, value)
        case let .layers(zMin, zMax, _):
            guard SettingInfo.byName[name]?.perLayer == true else { return "This setting is for the whole print: it cannot change for some layers." }
            rc = zs_app_override_set(core, zMin, zMax, name, value)
        }
        guard rc == 0 else {
            return rc == ZS_OUT_OF_RANGE.rawValue ? "The value is out of the limits." : "The value is not valid. \(statusText(rc))"
        }
        settingsChanged()
        return nil
    }

    /// Sets a setting back: the value with no change of this print, the
    /// value of the print for a part, or no change for the layers.
    func reset(_ name: String) {
        switch scope {
        case .print:
            set(name, entry(name).base)
        case .global:
            if setGlobal(name, nil) == 0 { settingsChanged() }
        case let .part(i):
            zs_app_part_setting_set(core, i, name, nil)
            settingsChanged()
        case let .layers(zMin, zMax, _):
            zs_app_override_remove(core, zMin, zMax, name)
            settingsChanged()
        }
    }

    /// A global setting (nil: the default again), on each plate of the
    /// window, and in global.toml. The other plates slice again.
    private func setGlobal(_ name: String, _ value: String?) -> Int32 {
        let rc = zs_app_global_setting_set(core, name, value)
        guard rc == 0 else { return rc }
        for i in plates.indices where i != active {
            if let app = zs_set_app(set, i) {
                zs_app_global_setting_set(app, name, value)
                zs_set_changed(set, i)
            }
        }
        SavedSettings.saveGlobal(from: core)
        return 0
    }

    /// The layer profiles of the plate.
    var layerProfiles: [(zMin: Double, zMax: Double, name: String)] {
        _ = settingsGeneration
        return (0 ..< zs_app_profile_count(core)).compactMap { i in
            var p = zs_layer_profile()
            guard zs_app_profile_get(core, i, &p) == 0 else { return nil }
            let name = p.name.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: p.name_len), as: UTF8.self) } ?? ""
            return (p.z_min, p.z_max, name)
        }
    }

    /// The print time and the plastic of each feature in the last slice.
    func featureStats() -> [zs_feature_stats]? {
        var out = [zs_feature_stats](repeating: zs_feature_stats(), count: Feature.count)
        return zs_app_feature_stats(core, &out) == 0 ? out : nil
    }
}

/// What the editors of the settings change: the print, one part, or the
/// layers of a layer profile (z_min..z_max).
enum SettingScope: Hashable {
    case print
    /// The global settings of the user: project settings for all prints.
    case global
    case part(Int)
    case layers(zMin: Double, zMax: Double, name: String)

    /// A z in the range of a layer profile, to read its values.
    var z: Double? {
        guard case let .layers(a, b, _) = self else { return nil }
        return a > -1e5 ? a : b
    }
}
