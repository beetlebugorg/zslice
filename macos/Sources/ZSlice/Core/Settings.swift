//! The settings, as the core describes them: the infos of all settings
//! (zs_setting_get_info), the value of each one in a plate with its source
//! (zs_app_setting_source), and what a setting changes in the toolpaths
//! (zs_setting_get_effect). The shell lists no setting: all of it comes
//! from the core.
//!
//! ValueText writes a value as an editor shows it, and reads an edit back,
//! with the rules of linux/src/ui/setting-editor.c and web/app/format.js:
//! a ratio ("%") shows as a percentage, a line width of 0 shows as "auto",
//! and a unit follows the value. These rules may move to the core.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation
import SwiftUI

/// The text of a C string of the core ("" for NULL).
func coreText(_ p: UnsafePointer<CChar>?) -> String {
    guard let p else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: p, count: strlen(p)), as: UTF8.self)
}

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
    var isAuto: Bool { name.hasSuffix("line_width") }
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
        if let formula { return "= \(formula)" }
        switch level {
        case 1: return "Global"
        case 2: return profile.isEmpty ? "Printer" : profile
        case 3: return profile.isEmpty ? "Filament" : profile
        case 4: return profile.isEmpty ? "Quality" : profile
        case 5: return "This print"
        case 6: return "This part"
        default: return ""
        }
    }
}

/// The text of setting values (setting-editor.c, format.js).
enum ValueText {
    static func parsesAsNumber(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && Double(s)?.isFinite == true
    }

    /// A number with no more digits than it needs (%.6g).
    static func number(_ v: Double) -> String {
        var s = String(format: "%.6g", v)
        if s == "-0" { s = "0" }
        return s
    }

    /// The value as an editor shows it.
    static func display(_ info: SettingInfo, _ value: String) -> String {
        if info.isAuto, let v = Double(value), v == 0 { return "auto" }
        if info.isRatio, let v = Double(value) { return number(v * 100) }
        if info.kind == .text && info.multiline, let nl = value.firstIndex(of: "\n") {
            return value[..<nl] + " …"
        }
        return value
    }

    /// The value with its unit: "0.8 mm", "1 layer", "auto".
    static func withUnit(_ info: SettingInfo, _ value: String) -> String {
        let shown = display(info, value)
        if info.unit.isEmpty || shown == "auto" { return shown }
        let one = shown == "1" && info.unit.count > 1 && info.unit.hasSuffix("s") && info.kind == .integer
        return "\(shown) \(one ? String(info.unit.dropLast()) : info.unit)"
    }

    /// The core value of the text of an editor.
    static func toCore(_ info: SettingInfo, _ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if info.isAuto && t.lowercased() == "auto" { return "0" }
        guard info.isRatio, let v = Double(t) else { return t }
        return String(format: "%.10g", v / 100)
    }
}

extension SliceModel {
    /// The value of a setting and its source.
    func entry(_ name: String) -> SettingEntry {
        _ = settingsGeneration
        let value = setting(name)
        var level: Int32 = 0
        var profile = [CChar](repeating: 0, count: 256)
        let rc = profile.withUnsafeMutableBufferPointer { zs_app_setting_source(core, -1, name, &level, $0.baseAddress, $0.count) }
        let base = coreString { zs_app_setting_base_get(core, name, $0, $1, $2) } ?? value
        let formula = coreString { zs_app_formula_get(core, name, $0, $1, $2) }
        return SettingEntry(value: value, level: rc == 0 ? level : 0,
                            profile: rc == 0 ? profile.withUnsafeBufferPointer { coreText($0.baseAddress) } : "",
                            base: base, formula: formula)
    }

    /// Sets a setting for this print, and slices again. Returns the error
    /// in words, or nil.
    @discardableResult
    func set(_ name: String, _ value: String) -> String? {
        let rc = zs_app_setting_set(core, name, value)
        guard rc == 0 else {
            return rc == ZS_OUT_OF_RANGE.rawValue ? "The value is out of the limits." : "The value is not valid (\(statusText(rc)))."
        }
        settingsChanged()
        return nil
    }

    /// Sets a setting back to the value without the change of this print.
    func reset(_ name: String) {
        set(name, entry(name).base)
    }

    /// The print time and the plastic of each feature in the last slice.
    func featureStats() -> [zs_feature_stats]? {
        var out = [zs_feature_stats](repeating: zs_feature_stats(), count: Feature.count)
        return zs_app_feature_stats(core, &out) == 0 ? out : nil
    }
}
