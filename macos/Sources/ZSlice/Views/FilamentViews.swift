//! The views of the filaments of the plate (web/app/filaments.js):
//!
//! - FilamentChips: the editor of the setting project.filament, a row of
//!   color chips with the number of each filament. The card of a range of
//!   layers and the part card use it (SettingEditor). A click on a chip
//!   prints the layers or the part with that filament; "+" adds one.
//! - FilamentList: the list on the print card: each filament with its
//!   color, its material, and its grams in the last slice, the number of
//!   filament changes, and Add a Filament. × removes a filament.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

extension Color {
    /// "#rrggbb" of the color, in sRGB.
    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#d0d0cc" }
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2])
    }

    /// Black or white text on a color of "#rrggbb".
    static func ink(on hex: String) -> Color {
        guard let c = NSColor(Color(hex: hex) ?? .gray).usingColorSpace(.sRGB) else { return .black }
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return l > 0.55 ? Color(white: 0.07) : .white
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

/// One chip: the color of a filament with its number.
struct FilamentChip: View {
    let slot: FilamentSlot
    var selected = false
    var size: CGFloat = 22

    var body: some View {
        Text("\(slot.index + 1)")
            .font(.system(size: size * 0.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.ink(on: slot.color))
            .frame(width: size, height: size)
            .background(Color(hex: slot.color) ?? .gray, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                     lineWidth: selected ? 2.5 : 1))
            .help("Filament \(slot.index + 1) · \(slot.material.isEmpty ? slot.name : slot.material) (\(slot.color))")
            .accessibilityLabel("Filament \(slot.index + 1), \(slot.material) \(slot.color)")
    }
}

/// The editor of project.filament: a chip for each filament, and "+".
/// The support filaments (project.support_filament, and
/// project.support_interface_filament) have a first chip for value 0: the
/// filament of the part ("Part"), or the support filament ("Support").
struct FilamentChips: View {
    let model: SliceModel
    /// The value of the setting: 1 for filament 1.
    let value: String
    /// The label of the chip of value 0, or nil for none.
    var zero: String?
    let commit: (String) -> Void

    var body: some View {
        let v = Int(Double(value) ?? 0)
        let picked = zero != nil ? max(v, 0) : max(v, 1)
        HStack(spacing: 4) {
            if let zero {
                Button { commit("0") } label: {
                    Text(zero)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(picked == 0 ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                                 lineWidth: picked == 0 ? 2.5 : 1))
                }
                .buttonStyle(.plain)
                .help(zero == "Part" ? "The filament of the part" : "The support filament")
                .accessibilityAddTraits(picked == 0 ? .isSelected : [])
            }
            ForEach(model.filaments) { f in
                Button { commit(String(f.index + 1)) } label: { FilamentChip(slot: f, selected: f.index + 1 == picked) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(f.index + 1 == picked ? .isSelected : [])
            }
            if model.filaments.count < 16 {
                Button {
                    if let i = model.addFilament() { commit(String(i + 1)) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                }
                .buttonStyle(.plain)
                .help("Add a filament to the plate")
            }
        }
    }
}

/// The filaments of the plate on the print card.
struct FilamentList: View {
    let model: SliceModel

    var body: some View {
        let list = model.filaments
        let st = model.filamentStats
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(list.count > 1 ? "\(list.count) filaments" : "Filament").font(.callout.weight(.medium))
                if let st, st.changes > 0 {
                    Text(" · \(st.changes) \(st.changes == 1 ? "change" : "changes")" + (st.flushG > 0.05 ? String(format: " · flush %.1f g", st.flushG) : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(list) { f in
                HStack(spacing: 6) {
                    ColorPicker("", selection: Binding(get: { Color(hex: f.color) ?? .gray },
                                                       set: { model.setFilament(f.index, "filament.color", $0.hex) }),
                                supportsOpacity: false)
                        .labelsHidden()
                        .help("The color of filament \(f.index + 1)")
                    Text("\(f.index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                    Picker("", selection: Binding(get: { f.material.isEmpty ? "PLA" : f.material },
                                                  set: { model.setFilament(f.index, "filament.material", $0) })) {
                        let kinds = SliceModel.filamentKinds
                        ForEach((kinds.contains(f.material) || f.material.isEmpty ? [] : [f.material]) + kinds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 80)
                    .help("The material of filament \(f.index + 1)")
                    // A printer with two nozzles: the nozzle of the filament.
                    if model.nozzleCount >= 2 {
                        Picker("", selection: Binding(get: { f.nozzle }, set: { model.setFilament(f.index, "filament.nozzle", String($0)) })) {
                            Text("Main").tag(0)
                            Text("2nd").tag(1)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 64)
                        .help("The nozzle of filament \(f.index + 1): the main nozzle (fed by the AMS on the X2D), or the second nozzle (fed by the external spool)")
                    }
                    Spacer(minLength: 0)
                    if let g = st?.grams[safe: f.index], g > 0 {
                        Text(String(format: "%.1f g", g)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if f.index > 0 {
                        Button { model.removeFilament(f.index) } label: { Image(systemName: "xmark").font(.caption) }
                            .buttonStyle(.borderless)
                            .help("Remove filament \(f.index + 1). Its parts and layers print with filament 1.")
                    }
                }
            }
            if list.count < 16 {
                Button("Add a Filament") { model.addFilament() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Add a filament to the plate. A part or a range of layers can then print with it.")
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
