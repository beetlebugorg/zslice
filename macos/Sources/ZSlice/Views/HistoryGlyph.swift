//! The glyph of each kind of history step (web/app/history.js, GLYPHS):
//! the same paths on an 18 × 18 grid, drawn in white with a stroke of 1.6,
//! round caps and joins, and no fill (the start has a small filled dot).
//! Move, Turn, and Support are the icons of the tool strip of the web app.
//!
//! The paths are SVG path data (move, line, horizontal, vertical, arc, and
//! close, each absolute or relative), read once into a SwiftUI Path. An arc
//! goes from its end points to its center as in the SVG specification
//! (appendix F.6.5); each arc of the glyphs is round.
//!
//! See REFERENCES.md: SVG 1.1 (path data and arcs).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct HistoryGlyph: View {
    let kind: String
    var size: CGFloat = 15

    /// One element of a glyph.
    enum Part {
        case path(String, dash: [CGFloat] = [])
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, r: CGFloat)
        case circle(CGFloat, CGFloat, CGFloat, fill: Bool = false)
    }

    static let glyphs: [String: [Part]] = [
        "walls": [.rect(2.5, 2.5, 13, 13, r: 3), .rect(6, 6, 6, 6, r: 1)],
        "infill": [.rect(2.5, 2.5, 13, 13, r: 1), .path("M2.5 9 9 2.5M2.5 15.5 15.5 2.5M9 15.5 15.5 9M2.5 9 9 15.5M2.5 2.5l13 13M9 2.5 15.5 9")],
        "surface": [.path("M2.5 3.5h13M2.5 14.5h13"), .path("M2.5 6h13M2.5 12h13", dash: [1.6, 1.9])],
        "speed": [.path("M3 13.5a6.5 6.5 0 1 1 12 0"), .path("M9 11 12.5 6.5"), .circle(9, 11, 1)],
        "heat": [.path("M7 10.6V4a2 2 0 0 1 4 0v6.6a3.6 3.6 0 1 1-4 0z"), .path("M9 12.5V7")],
        "support": [.path("M2 4.5h14l-2 3H4z"), .path("M5 7.5v8M9 7.5v8M13 7.5v8M3.5 15.5h11")],
        "layers": [.path("M9 2.5 16 6l-7 3.5L2 6z"), .path("M2 9.5 9 13l7-3.5M2 12.5 9 16l7-3.5")],
        "move": [.path("M2 9h14M9 2v14M13.7 6.8 16 9l-2.3 2.2M4.3 6.8 2 9l2.3 2.2M6.8 4.3 9 2l2.2 2.3M6.8 13.7 9 16l2.2-2.3")],
        "rotate": [.path("M14.5 9a5.5 5.5 0 1 1-1.6-3.9"), .path("M13.6 2.2v3.3h-3.3")],
        "scale": [.path("M3 15 15 3M10 3h5v5M3 10v5h5")],
        "add": [.path("M3.5 9h11M9 3.5v11")],
        "remove": [.path("M3.5 9h11")],
        "quality": [.path("M9 2.2l2 4.3 4.7.6-3.4 3.2.9 4.6L9 12.6l-4.2 2.3.9-4.6-3.4-3.2 4.7-.6z")],
        "printer": [.path("M5 6.5V2.5h8v4M5 13H2.5V6.5h13V13H13M5 10.5h8v5H5z")],
        // A spool from the side.
        "filament": [.rect(2.5, 2.5, 2.5, 13, r: 1), .rect(13, 2.5, 2.5, 13, r: 1), .path("M5 6.5h8M5 9h8M5 11.5h8")],
        "start": [.circle(9, 9, 5.5), .circle(9, 9, 1.5, fill: true)],
        "other": [.circle(4, 9, 0.6), .circle(9, 9, 0.6), .circle(14, 9, 0.6)],
    ]

    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 18
            let parts = Self.glyphs[kind] ?? Self.glyphs["other"]!
            for part in parts {
                var p = Path()
                var dash: [CGFloat] = []
                var fill = false
                switch part {
                case let .path(d, dd):
                    p = Self.parse(d)
                    dash = dd
                case let .rect(x, y, w, h, r):
                    p = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
                case let .circle(cx, cy, r, f):
                    p = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                    fill = f
                }
                let scaled = p.applying(CGAffineTransform(scaleX: k, y: k))
                if fill { ctx.fill(scaled, with: .color(.white)) }
                ctx.stroke(scaled, with: .color(.white),
                           style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round, lineJoin: .round, dash: dash.map { $0 * k }))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - path data

    /// The commands and numbers of path data.
    private static func tokens(_ d: String) -> [String] {
        var out: [String] = []
        var num = ""
        func flush() {
            if !num.isEmpty { out.append(num) }
            num = ""
        }
        for c in d {
            if c.isLetter, c != "e" {
                flush()
                out.append(String(c))
            } else if c == " " || c == "," {
                flush()
            } else if c == "-", !num.isEmpty, num.last != "e" {
                flush()
                num = "-"
            } else if c == ".", num.contains(".") {
                // ".6.5": a new number starts at the second point.
                flush()
                num = "."
            } else {
                num.append(c)
            }
        }
        flush()
        return out
    }

    static func parse(_ d: String) -> Path {
        var path = Path()
        let t = tokens(d)
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        func num() -> CGFloat {
            defer { i += 1 }
            return i < t.count ? CGFloat(Double(t[i]) ?? 0) : 0
        }
        while i < t.count {
            if let c = t[i].first, c.isLetter {
                cmd = c
                i += 1
                if c == "z" || c == "Z" {
                    path.closeSubpath()
                    cur = start
                    continue
                }
            }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            switch cmd.uppercased() {
            case "M":
                cur = CGPoint(x: base.x + num(), y: base.y + num())
                path.move(to: cur)
                start = cur
                // More pairs after a move are lines.
                cmd = rel ? "l" : "L"
            case "L":
                cur = CGPoint(x: base.x + num(), y: base.y + num())
                path.addLine(to: cur)
            case "H":
                cur = CGPoint(x: (rel ? cur.x : 0) + num(), y: cur.y)
                path.addLine(to: cur)
            case "V":
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + num())
                path.addLine(to: cur)
            case "A":
                let r = num()
                _ = num() // ry: the arcs of the glyphs are round
                _ = num() // x-axis rotation
                let large = num() != 0, sweep = num() != 0
                let end = CGPoint(x: base.x + num(), y: base.y + num())
                arc(&path, from: cur, to: end, r: r, large: large, sweep: sweep)
                cur = end
            default:
                i += 1
            }
        }
        return path
    }

    /// A round arc from its end points (SVG F.6.5, with rx = ry and no
    /// rotation). sweep: the angle grows (clockwise on the screen).
    private static func arc(_ path: inout Path, from p1: CGPoint, to p2: CGPoint, r rIn: CGFloat, large: Bool, sweep: Bool) {
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let d2 = dx * dx + dy * dy
        guard d2 > 0 else { return }
        var r = abs(rIn)
        if d2 > r * r { r = sqrt(d2) }
        let k = sqrt(max(0, (r * r - d2) / d2)) * (large == sweep ? -1 : 1)
        let cx = k * dy + (p1.x + p2.x) / 2
        let cy = -k * dx + (p1.y + p2.y) / 2
        let a1 = atan2(p1.y - cy, p1.x - cx)
        let a2 = atan2(p2.y - cy, p2.x - cx)
        // The path goes in the y-down space of the view: a growing angle
        // turns clockwise on the screen.
        path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .radians(a1), endAngle: .radians(a2), clockwise: !sweep)
    }
}
