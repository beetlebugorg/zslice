//! The pictures of Quick Look (the thumbnails of Finder and the previews of
//! the space bar), from the core, on the CPU (no GPU in an extension):
//!
//! - an STL or 3MF model: the parts in their filament color, from the front
//!   right (zs_app_load_stl, zs_app_thumbnail_png);
//! - a G-code file of any slicer: its beads, one color for each feature
//!   (zs_gcode_open, zs_gcode_thumbnail_png), and its facts (the time, the
//!   layers, the filament, the size).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import CZslice
import Foundation
import ImageIO

enum Render {
    struct Result {
        var image: CGImage?
        /// The facts, in a few lines.
        var facts: [String]
    }

    static func isGcode(_ url: URL) -> Bool {
        ["gcode", "gco", "g", "bgcode"].contains(url.pathExtension.lowercased())
    }

    /// The picture of a file, at most `px` pixels on its longer side.
    static func render(_ url: URL, px: Int) -> Result {
        let side = UInt32(max(64, min(px, 1024)))
        return isGcode(url) ? gcode(url, side) : model(url, side)
    }

    private static func image(_ out: UnsafeMutablePointer<UInt8>?, _ len: Int) -> CGImage? {
        guard let out else { return nil }
        defer { zs_buffer_free(out, len) }
        let data = Data(bytes: out, count: len) as CFData
        guard let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func model(_ url: URL, _ side: UInt32) -> Result {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return Result(image: nil, facts: []) }
        var app: OpaquePointer?
        guard zs_app_new({ _, _, _, _ in }, nil, &app) == 0, let app else { return Result(image: nil, facts: []) }
        defer { zs_app_free(app) }
        let rc = data.withUnsafeBytes { zs_app_load_stl(app, url.lastPathComponent, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard rc == 0 else { return Result(image: nil, facts: ["zslice cannot read this model."]) }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let img = zs_app_thumbnail_png(app, side, side, &out, &len) == 0 ? image(out, len) : nil
        return Result(image: img, facts: facts(app: app))
    }

    /// The size of a model, and its triangles.
    static func facts(app: OpaquePointer) -> [String] {
        var info = zs_model_info()
        guard zs_app_model_info(app, &info) == 0 else { return [] }
        return [String(format: "%.1f × %.1f × %.1f mm", info.size_x, info.size_y, info.size_z),
                "\(info.triangles.formatted()) triangles"]
    }

    private static func gcode(_ url: URL, _ side: UInt32) -> Result {
        var g: OpaquePointer?
        guard zs_gcode_open(url.path, &g) == 0, let g else { return Result(image: nil, facts: ["zslice cannot read this G-code."]) }
        defer { zs_gcode_free(g) }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        let img = zs_gcode_thumbnail_png(g, side, side, 1, 0xF28C28, &out, &len) == 0 ? image(out, len) : nil
        return Result(image: img, facts: facts(gcode: g))
    }

    /// The time, the layers, the size, and the filament of a G-code file.
    static func facts(gcode g: OpaquePointer) -> [String] {
        var facts: [String] = []
        var info = zs_gcode_info()
        if zs_gcode_get_info(g, &info) == 0 {
            if info.time_s > 0 { facts.append("Print time \(duration(info.time_s))") }
            facts.append("\(info.layers) layers")
            // A C array is a tuple in Swift: min x, y, z, then max x, y, z.
            let b = info.box
            let w = b.3 - b.0, d = b.4 - b.1, h = b.5 - b.2
            if w > 0 { facts.append(String(format: "%.1f × %.1f × %.1f mm", w, d, h)) }
            if info.filament_mm > 0 { facts.append(String(format: "Filament %.2f mm", info.filament_mm)) }
        }
        return facts
    }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }
}
