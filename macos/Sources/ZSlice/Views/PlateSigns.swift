//! The signs of the plates (web/app/signs.js, linux/src/ui/preview.c): a
//! small card on the bed just in front of each plate, with its number and
//! name, and its printer and its status (or its print time and filament
//! after a slice).
//!
//! The app draws the text of all signs into one RGBA image, each sign in
//! its own row with a clear row between them, so the filtered pixels of
//! one do not reach the next. The core view (zs_view_set_signs) draws each
//! sign as a flat quad on the bed with that image, in the world: the signs
//! turn and tilt with the plates, and the parts hide them
//! (FrameRenderer.drawSigns). The image is made again only when a plate,
//! its name, its printer, its status, its totals, the active plate, or the
//! theme changes. A click on a sign makes its plate the active plate
//! (zs_view_sign_at).
//!
//! The active plate, when it is empty, has a small Open button at the
//! middle of its bed, so it moves with the plate. It hides when it is out
//! of the view, or when another plate is in front of it.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI

/// The text of the sign of a plate.
struct PlateSign: Equatable {
    var title: String
    var sub: String
    var active: Bool
}

extension Workspace {
    /// The pixels of the image for one point of the sign: the text stays
    /// sharp up close and on a Retina display.
    private static let signScale: CGFloat = 2
    /// The height of a sign on the screen (points), within the limits of
    /// the core.
    private static let signScreenHeight: CGFloat = 46

    /// The lines of the sign of plate i (web/app/signs.js, signLines).
    func signLines(_ i: Int, _ p: PlateInfo) -> PlateSign {
        let title = "\(i + 1)  \(p.name.isEmpty ? "Empty plate" : p.name)"
        var facts: [String] = []
        if let printer = assigned(plate: i) { facts.append(printer.name) }
        var t = zs_totals()
        if Int(p.status) == Int(ZS_PLATE_STATUS_DONE.rawValue), zs_set_plate_totals(model.set, i, &t) == 0, t.time_s > 0 {
            facts.append("\(PrintCard.duration(t.time_s)) · " + String(format: "%.1f g", t.filament_g))
        } else {
            switch Int(p.status) {
            case Int(ZS_PLATE_STATUS_EMPTY.rawValue): facts.append("Empty")
            case Int(ZS_PLATE_STATUS_STALE.rawValue): facts.append("To slice")
            case Int(ZS_PLATE_STATUS_SLICING.rawValue): facts.append("Slicing")
            case Int(ZS_PLATE_STATUS_FAILED.rawValue): facts.append("The slice failed")
            case Int(ZS_PLATE_STATUS_DONE.rawValue): break
            default: facts.append("Resin: not yet")
            }
        }
        return PlateSign(title: title, sub: facts.joined(separator: " · "), active: i == model.active && model.plates.count > 1)
    }

    /// After each frame: the signs again if their text or look changed,
    /// and the place of the Open button.
    func updatePlateSigns() {
        guard let v = canvas.view, ProcessInfo.processInfo.environment["ZSLICE_NO_SIGNS"] == nil else { return }
        let signs = model.plates.enumerated().map { signLines($0.offset, $0.element) }
        let dark = canvas.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let backing = canvas.window?.backingScaleFactor ?? 2
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let key = signs.map { "\($0.title)\t\($0.sub)\t\($0.active)" }.joined(separator: "\n")
            + "|\(dark)|\(backing)|\(accent.redComponent),\(accent.greenComponent),\(accent.blueComponent)"
        if key != signKey {
            signKey = key
            let d = Self.drawSigns(signs, dark: dark, accent: accent)
            let scale = Float(d.rowHeight / (Self.signScreenHeight * backing))
            _ = d.rects.withUnsafeBufferPointer { r in
                d.rgba.withUnsafeBufferPointer { px in
                    zs_view_set_signs(v, signs.count, r.baseAddress, UInt32(d.width), UInt32(d.height), px.baseAddress, scale)
                }
            }
            canvas.requestFrame()
            if ProcessInfo.processInfo.environment["ZSLICE_SIGN_LOG"] != nil {
                NSLog("zslice signs: %@", signs.map { "\($0.title) / \($0.sub)\($0.active ? " (active)" : "")" }.joined(separator: " | "))
            }
        }
        placeOpenButton()
    }

    /// Draws the signs into one RGBA image (straight alpha): rects (x, y,
    /// w, h for each sign, in pixels of the image), its size, its pixels,
    /// and the height of a sign.
    static func drawSigns(_ signs: [PlateSign], dark: Bool, accent: NSColor)
        -> (rects: [Float], width: Int, height: Int, rgba: [UInt8], rowHeight: CGFloat) {
        let S = signScale
        let pad = 10 * S, bar = 4 * S
        let h1: CGFloat = 15, h2: CGFloat = 12.5
        let rowHeight = (pad * 2 + (h1 * 1.25 + h2 * 1.35) * S).rounded()
        let titleFont = NSFont.systemFont(ofSize: h1 * S, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: h2 * S, weight: .regular)
        // The width of each sign: its longest line, with no shortening.
        let widths = signs.map { s -> CGFloat in
            let a = (s.title as NSString).size(withAttributes: [.font: titleFont]).width
            let b = s.sub.isEmpty ? 0 : (s.sub as NSString).size(withAttributes: [.font: subFont]).width
            return (max(a, b, 90 * S) + pad * 2 + bar).rounded(.up)
        }
        let gap: CGFloat = 4
        let W = max(1, Int(widths.max() ?? 1)), H = max(1, Int(CGFloat(signs.count) * (rowHeight + gap)))
        var px = [UInt8](repeating: 0, count: W * H * 4)
        var rects: [Float] = []
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // y down, as the rows of the image.
            ctx.translateBy(x: 0, y: CGFloat(H))
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            for (i, s) in signs.enumerated() {
                let y = CGFloat(i) * (rowHeight + gap)
                let w = widths[i]
                let card = NSBezierPath(roundedRect: NSRect(x: 1, y: y + 1, width: w - 2, height: rowHeight - 2), xRadius: 9 * S, yRadius: 9 * S)
                (dark ? NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 44 / 255, alpha: 0.9) : NSColor(white: 1, alpha: 0.92)).setFill()
                card.fill()
                card.lineWidth = S
                (s.active ? accent : dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.14)).setStroke()
                card.stroke()
                // The active plate: a bar in the accent color at the left.
                if s.active {
                    NSGraphicsContext.saveGraphicsState()
                    card.addClip()
                    accent.setFill()
                    NSRect(x: 0, y: y, width: bar + 1, height: rowHeight).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                // NSString.draw(at:) takes the top of the line: the baseline
                // of signs.js less the ascender.
                let titleColor = dark ? NSColor(srgbRed: 0xf6 / 255, green: 0xf5 / 255, blue: 0xf4 / 255, alpha: 1)
                                      : NSColor(srgbRed: 0x24 / 255, green: 0x1f / 255, blue: 0x31 / 255, alpha: 1)
                (s.title as NSString).draw(at: NSPoint(x: bar + pad, y: y + pad + h1 * S - titleFont.ascender),
                                           withAttributes: [.font: titleFont, .foregroundColor: titleColor])
                if !s.sub.isEmpty {
                    let subColor = dark ? NSColor(srgbRed: 0xc0 / 255, green: 0xbf / 255, blue: 0xbc / 255, alpha: 1)
                                        : NSColor(srgbRed: 0x5e / 255, green: 0x5c / 255, blue: 0x64 / 255, alpha: 1)
                    (s.sub as NSString).draw(at: NSPoint(x: bar + pad, y: y + pad + (h1 * 1.25 + h2 * 1.1) * S - subFont.ascender),
                                             withAttributes: [.font: subFont, .foregroundColor: subColor])
                }
                rects += [0, Float(y), Float(w), Float(rowHeight)]
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        // The core takes straight alpha: undo the premultiplied color.
        for k in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[k + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0 ..< 3 { px[k + c] = UInt8(min(255, (Int(px[k + c]) * 255 + a / 2) / a)) }
        }
        return (rects, W, H, px, rowHeight)
    }

    /// The Open button of an empty active plate: at the middle of its bed
    /// in the view, or nil when it is out of the view, another plate is in
    /// front of it, or the welcome card shows.
    private func placeOpenButton() {
        var at: CGPoint?
        let plates = model.plates
        if page == .threeD, plates.indices.contains(model.active), Int(plates[model.active].status) == Int(ZS_PLATE_STATUS_EMPTY.rawValue),
           plates.count > 1 || model.project != nil, let v = canvas.view {
            let p = plates[model.active]
            let bx = p.bedX > 0 ? p.bedX : 220, by = p.bedY > 0 ? p.bedY : 220
            if let q = canvas.viewPoint(x: bx / 2, y: by / 2, z: 0) {
                let w: CGFloat = 130, h: CGFloat = 28, b = canvas.bounds
                var ok = q.x - w / 2 > 4 && q.x + w / 2 < b.width - 4 && q.y - h / 2 > 4 && q.y + h / 2 < b.height - 4
                // Another plate (or its parts) at the button: it hides.
                let s = canvas.window?.backingScaleFactor ?? 2
                for (dx, dy) in [(0.0, 0.0), (-w / 2, 0), (w / 2, 0), (0, -h / 2), (0, h / 2)] where ok && plates.count > 1 {
                    let i = zs_view_plate_at(v, Float((q.x + dx) * s), Float((q.y + dy) * s))
                    if i >= 0, Int(i) != model.active { ok = false }
                }
                if ok { at = q }
            }
        }
        if at.map({ a in openButtonAt.map { hypot($0.x - a.x, $0.y - a.y) > 0.5 } ?? true }) ?? (openButtonAt != nil) { openButtonAt = at }
    }
}

/// The Open button of an empty plate, at its place in the view.
struct OpenPlateButton: View {
    let workspace: Workspace

    var body: some View {
        if let at = workspace.openButtonAt {
            Button { workspace.addModels() } label: {
                Label("Open a model", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator))
            }
            .buttonStyle(.plain)
            .help("Add models to this plate (⇧⌘I)")
            .position(at)
        }
    }
}
