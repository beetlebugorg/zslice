//! The model of a label (web/app/label.js, its top part): a 2D shape on
//! the surface of a part, in a filament of its own (docs/embedding/
//! labels.md, docs/user/labels.md). The core keeps the labels as JSON
//! (zs_app_part_labels_get, zs_app_label_add, _update, _remove); this file
//! reads and writes that JSON, and does the math of the frame of a label.
//!
//! A label has a frame on the surface: its origin, its normal (out of the
//! part), and its right (the +x axis of its shapes); up = normal × right.
//! Its turn is the angle of its right from its level right: on a side face
//! (|normal.z| ≤ 0.7) the level right is Z × normal, else the X axis of the
//! bed put into the plane. A move keeps the direction of its right, put
//! into the new plane.
//!
//! Its items are text, a line, a bar, a ring, the ticks of a dial, or a
//! free line (polyline), each at a place and a turn in the plane. The core
//! gives the outline of the shapes in the plane (zs_label_outline) for the
//! preview, and the frame at a ray of the view (zs_label_place).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
import Foundation
import simd

/// One shape of a label. Each field is optional: the JSON keeps only the
/// fields of its kind, and a field that this app does not show stays.
struct LabelItem: Codable, Equatable {
    var kind: String
    var at: [Double]?
    var angle: Double?
    // text
    var text: String?
    var size: Double?
    var weight: Double?
    var alignment: String?
    var spacing: Double?
    var font: String?
    // line, bar, ring, ticks, polyline
    var length: Double?
    var width: Double?
    var round: Bool?
    var height: Double?
    var radius: Double?
    var outer: Double?
    var inner: Double?
    var count: Double?
    var length_end: Double?
    var start: Double?
    var sweep: Double?
    var points: [[Double]]?
    var closed: Bool?
    var filled: Bool?
    // svg: the source of the picture; its height is "size"
    var svg: String?

    static let shapes = ["text", "line", "bar", "ring", "ticks", "polyline"]
    static let shapeNames = ["text": "Text", "line": "Line", "bar": "Bar", "ring": "Ring", "ticks": "Ticks", "polyline": "Free", "svg": "SVG"]
    /// The height of a new SVG picture, mm.
    static let svgSize = 15.0

    /// An SVG picture of `svg` (its source), `size` mm tall.
    static func svg(_ svg: String, size: Double = svgSize) -> LabelItem {
        var it = LabelItem(kind: "svg")
        it.svg = svg
        it.size = size
        return it
    }

    /// A new item of a shape. size: the size of the label (the cap height
    /// of its text), mm.
    static func new(_ kind: String, size: Double = 5) -> LabelItem {
        var it = LabelItem(kind: kind)
        switch kind {
        case "text": it.text = "LABEL"; it.size = size
        case "line": it.length = 4 * size; it.width = 1
        case "bar": it.width = 4 * size; it.height = max(1, 0.4 * size); it.radius = 0
        case "ring": it.outer = size; it.inner = max(0, size - 1)
        case "ticks":
            it.count = 11; it.radius = 1.6 * size; it.length = 0.3 * size; it.length_end = 0.6 * size
            it.width = 0.8; it.start = 225; it.sweep = -270
        default:
            it.points = [[-2 * size, -size / 2], [0, size / 2], [2 * size, -size / 2]]
            it.width = 1; it.closed = false; it.filled = false
        }
        return it
    }

    /// The size for the card, mm: the cap height of a text, the length of
    /// a line, the width of a bar, the diameter of a ring, the outer
    /// diameter of the ticks, the width of a free line.
    var itemSize: Double {
        switch kind {
        case "text", "svg": return size ?? 0
        case "line": return length ?? 0
        case "bar": return width ?? 0
        case "ring": return 2 * (outer ?? 0)
        case "ticks": return 2 * ((radius ?? 0) + max(length ?? 0, length_end ?? 0))
        default:
            let xs = (points ?? []).compactMap(\.first)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
    }

    /// An item of another shape at the same place, with about the same size.
    func changed(to k: String) -> LabelItem {
        guard k != kind else { return self }
        var out = LabelItem.new(k, size: max(0.5, itemSize / (kind == "text" ? 1 : kind == "ring" ? 2 : 4)))
        out.at = at
        out.angle = angle
        return out
    }

    /// The item scaled by k: its lengths, its place, and its points.
    func scaled(_ k: Double) -> LabelItem {
        var o = self
        func s(_ v: Double?) -> Double? { v.map { $0 * k } }
        switch kind {
        case "text": o.size = s(size); o.spacing = s(spacing)
        case "svg": o.size = s(size)
        case "line": o.length = s(length); o.width = s(width)
        case "bar": o.width = s(width); o.height = s(height); o.radius = s(radius)
        case "ring": o.outer = s(outer); o.inner = s(inner)
        case "ticks": o.radius = s(radius); o.length = s(length); o.length_end = s(length_end); o.width = s(width)
        default: o.width = s(width)
        }
        o.at = at.map { $0.map { $0 * k } }
        o.points = points.map { $0.map { $0.map { $0 * k } } }
        return o
    }

    /// A number field by its JSON name (the fields of the card).
    subscript(field: String) -> Double? {
        get {
            switch field {
            case "size": size; case "weight": weight; case "spacing": spacing
            case "length": length; case "width": width; case "height": height; case "radius": radius
            case "outer": outer; case "inner": inner; case "count": count; case "length_end": length_end
            case "start": start; case "sweep": sweep
            default: nil
            }
        }
        set {
            switch field {
            case "size": size = newValue; case "weight": weight = newValue; case "spacing": spacing = newValue
            case "length": length = newValue; case "width": width = newValue; case "height": height = newValue
            case "radius": radius = newValue; case "outer": outer = newValue; case "inner": inner = newValue
            case "count": count = newValue; case "length_end": length_end = newValue
            case "start": start = newValue; case "sweep": sweep = newValue
            default: break
            }
        }
    }
}

/// A label of a part, as the core gives it.
struct PartLabel: Codable, Equatable, Identifiable {
    var id: UInt32 = 0
    var name: String?
    var origin: [Double]
    var normal: [Double]
    var right: [Double]
    var filament: Int
    var depth: Double?
    var stretch: [Double]?
    /// "ink" (flush, the default; the JSON of an ink label has no mode),
    /// "raised" (out of the surface by `relief` mm), or "cut" (into it).
    var mode: String?
    /// mm, 0 to 10 (0: 0.6 mm), for a raised or cut label.
    var relief: Double?
    var items: [LabelItem]

    static let modes = ["ink", "raised", "cut"]
    static let modeNames = ["ink": "Ink", "raised": "Raised", "cut": "Cut in"]
    /// The relief of a raised or cut label with a relief of 0 (the core).
    static let defaultRelief = 0.6

    /// The words of a label for a list: its name, its text, or the names
    /// of its shapes.
    var title: String {
        if let name, !name.isEmpty { return name }
        if let t = items.first(where: { $0.kind == "text" && !($0.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty })?.text {
            return "“\(t.trimmingCharacters(in: .whitespaces))”"
        }
        var seen: [String] = []
        for it in items { let n = LabelItem.shapeNames[it.kind] ?? it.kind; if !seen.contains(n) { seen.append(n) } }
        return seen.isEmpty ? "Empty label" : seen.joined(separator: " and ")
    }

    // ---- the frame ----

    var o: SIMD3<Double> { SIMD3(origin) }
    var n: SIMD3<Double> { SIMD3(normal) }
    var r: SIMD3<Double> { SIMD3(right) }
    var up: SIMD3<Double> { cross(n, r) }

    /// The right of a label with a turn of 0 at normal n: level on a side
    /// face, else the X axis of the bed in the plane.
    static func levelRight(_ n: SIMD3<Double>) -> SIMD3<Double> {
        if abs(n.z) <= 0.7 {
            let v = SIMD3(-n.y, n.x, 0)
            return length(v) > 1e-9 ? normalize(v) : SIMD3(1, 0, 0)
        }
        let a = SIMD3<Double>(1, 0, 0) - n.x * n
        if length(a) > 1e-9 { return normalize(a) }
        return normalize(SIMD3<Double>(0, 1, 0) - n.y * n)
    }

    /// The turn from the level right, degrees.
    var angle: Double {
        let ref = Self.levelRight(n), refUp = cross(n, ref)
        return atan2(dot(r, refUp), dot(r, ref)) * 180 / .pi
    }

    /// The label with the turn `deg` from its level right.
    func withAngle(_ deg: Double) -> PartLabel {
        let a = deg * .pi / 180, ref = Self.levelRight(n), refUp = cross(n, ref)
        var l = self
        l.right = Array(normalize(ref * cos(a) + refUp * sin(a)))
        return l
    }

    /// The label turned by `deg` around its normal (counterclockwise from
    /// the front).
    func turned(_ deg: Double) -> PartLabel {
        let a = deg * .pi / 180
        var l = self
        l.right = Array(normalize(r * cos(a) + up * sin(a)))
        return l
    }

    /// The label turned by `deg` around its normal about the point c (s, t)
    /// of its plane, which stays (zg_label_turn_about of the GTK app).
    func turned(_ deg: Double, about c: (Double, Double)) -> PartLabel {
        var l = turned(deg)
        l.origin = Array(o + c.0 * (r - l.r) + c.1 * (up - l.up))
        return l
    }

    /// The label at a new point and normal: its right keeps its direction,
    /// put into the new plane (else the level right).
    func moved(origin p: SIMD3<Double>, normal nn: SIMD3<Double>) -> PartLabel {
        let nu = length(nn) > 1e-9 ? normalize(nn) : n
        let rr = r - dot(r, nu) * nu
        var l = self
        l.origin = Array(p)
        l.normal = Array(nu)
        l.right = Array(length(rr) > 1e-9 ? normalize(rr) : Self.levelRight(nu))
        return l
    }

    /// The point of the plane on a ray (o, d): the point, and x, y along
    /// right and up; nil when the ray misses the plane.
    func planeHit(_ ro: SIMD3<Double>, _ d: SIMD3<Double>) -> (p: SIMD3<Double>, x: Double, y: Double)? {
        let den = dot(d, n)
        guard abs(den) > 1e-9 else { return nil }
        let t = dot(o - ro, n) / den
        guard t > 0 else { return nil }
        let p = ro + t * d, v = p - o
        return (p, dot(v, r), dot(v, up))
    }

    /// A point (x, y) of the plane in the frame of the bed, `lift` mm out
    /// of the surface.
    func toBed(_ x: Double, _ y: Double, lift: Double = 0) -> SIMD3<Double> { o + x * r + y * up + lift * n }

    func scaled(_ k: Double) -> PartLabel {
        var l = self
        l.items = items.map { $0.scaled(k) }
        return l
    }

    // ---- JSON ----

    var json: String {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The JSON of the shapes for zs_label_outline: the items and the
    /// stretch, with no frame. It is also the key of the outline.
    var shapeJson: String {
        struct Shapes: Encodable { var items: [LabelItem]; var stretch: [Double]? }
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return (try? e.encode(Shapes(items: items, stretch: stretch))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func list(_ text: String) -> [PartLabel] {
        (try? JSONDecoder().decode([PartLabel].self, from: Data(text.utf8))) ?? []
    }

    /// The filament of a new label on a part in filament `base` (from 1)
    /// with `count` filaments: the filament after it, else the first other
    /// one. With one filament: 1 (the card offers to add one).
    static func nextFilament(_ base: Int, _ count: Int) -> Int {
        if count <= 1 { return 1 }
        if base + 1 <= count { return base + 1 }
        return base == 1 ? 2 : 1
    }
}

/// The outline of the shapes of a label in its plane (zs_label_outline):
/// x, y pairs, the end of each path, and its box.
struct LabelOutline {
    var pts: [Float]
    var ends: [UInt32]
    var box: (x0: Double, y0: Double, x1: Double, y1: Double)

    init?(_ label: PartLabel) {
        let json = label.shapeJson
        var p: UnsafePointer<Float>?, e: UnsafePointer<UInt32>?
        var n = 0
        let rc = json.withCString { zs_label_outline($0, strlen($0), &p, &e, &n) }
        guard rc == 0 else { return nil }
        ends = n > 0 && e != nil ? Array(UnsafeBufferPointer(start: e, count: n)) : []
        let count = Int(ends.last ?? 0)
        pts = count > 0 && p != nil ? Array(UnsafeBufferPointer(start: p, count: 2 * count)) : []
        var b = (x0: Double.infinity, y0: Double.infinity, x1: -Double.infinity, y1: -Double.infinity)
        for i in 0 ..< count {
            b.x0 = min(b.x0, Double(pts[2 * i])); b.x1 = max(b.x1, Double(pts[2 * i]))
            b.y0 = min(b.y0, Double(pts[2 * i + 1])); b.y1 = max(b.y1, Double(pts[2 * i + 1]))
        }
        box = count > 0 ? b : (0, 0, 0, 0)
    }
}

/// The frame of a label at a ray of the view (zs_label_place), on a paint
/// session of the mesh of the part.
struct LabelPlace {
    var origin: SIMD3<Double>
    var normal: SIMD3<Double>
    var right: SIMD3<Double>
    /// The largest angle between the plane and the face nearby, degrees.
    var curve: Double

    /// The face curves more than this under a label: it stretches.
    static let curveLimit = 60.0
    static let curveText = "The face curves too much here; the label stretches."

    init?(_ session: OpaquePointer, ray: [Float], radius: Double = 5) {
        var out = [Double](repeating: 0, count: 10)
        guard ray.count == 6, zs_label_place(session, ray, radius, &out) != 0 else { return nil }
        origin = SIMD3(out[0], out[1], out[2])
        normal = SIMD3(out[3], out[4], out[5])
        right = SIMD3(out[6], out[7], out[8])
        curve = out[9]
    }
}

extension SIMD3 where Scalar == Double {
    init(_ a: [Double]) { self.init(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0, a.count > 2 ? a[2] : 0) }
}

extension Array where Element == Double {
    init(_ v: SIMD3<Double>) { self = [v.x, v.y, v.z] }
}
