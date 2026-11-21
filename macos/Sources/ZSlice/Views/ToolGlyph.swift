//! The glyphs of the tool strip: the SVG paths of the tool buttons of the
//! web app (web/app/index.html), on the same 18 × 18 grid, so the three
//! apps show the same icons. HistoryGlyph.parse reads the path data.
//!
//! See REFERENCES.md: SVG 1.1 (path data and arcs).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ToolGlyph: View {
    let name: String
    var size: CGFloat = 18

    /// One element of a glyph.
    enum Part {
        case path(String, dash: [CGFloat] = [])
        case fill(String)
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, r: CGFloat = 0)
        case dot(CGFloat, CGFloat, CGFloat)
    }

    /// The parts of a glyph, its stroke width, its caps and joins, and its
    /// turn in degrees about the center.
    struct Glyph {
        var parts: [Part]
        var width: CGFloat = 1.5
        var round = true
        var turn: Double = 0
    }

    static let glyphs: [String: Glyph] = [
        "select": Glyph(parts: [.fill("M5 2v13l3.2-3 2.3 4.5 2.1-1-2.3-4.5h4.2z")]),
        "move": Glyph(parts: [.path("M2 9h14M9 2v14M13.7 6.8 16 9l-2.3 2.2M4.3 6.8 2 9l2.3 2.2M6.8 4.3 9 2l2.2 2.3M6.8 13.7 9 16l2.2-2.3")]),
        "turn": Glyph(parts: [.path("M14.5 9a5.5 5.5 0 1 1-1.6-3.9"), .path("M13.6 2.2v3.3h-3.3")]),
        // A shelf on three posts.
        "support": Glyph(parts: [.path("M2 4.5h14l-2 3H4z"), .path("M5 7.5v8M9 7.5v8M13 7.5v8M3.5 15.5h11")]),
        "grab": Glyph(parts: [.path("M6 9V4.2a1.2 1.2 0 0 1 2.4 0V8M8.4 7.5V3.2a1.2 1.2 0 0 1 2.4 0V8M10.8 7.6V4.2a1.2 1.2 0 0 1 2.4 0v6.3c0 3-2 5-4.8 5-2 0-3-.9-4.2-2.6L2.6 10a1.2 1.2 0 0 1 2-1.3L6 10.4")], width: 1.4),
        // A ruler at 45°.
        "measure": Glyph(parts: [.rect(1, 6, 16, 6, r: 0.5), .path("M4 6v2.5M6.5 6v1.5M9 6v2.5M11.5 6v1.5M14 6v2.5")], turn: -45),
        "paint": Glyph(parts: [.path("M15.5 2.5 8.6 9.4"), .path("M8.6 9.4c-1.3-.6-2.9-.1-3.5 1.3-.6 1.3-.2 2.4-1.6 3.8 2.6.7 4.9.2 5.7-1.4.6-1.3.4-2.7-.6-3.7z")], width: 1.4),
        "label": Glyph(parts: [.rect(2, 3.5, 14, 11, r: 1.5), .path("M5.5 7h5M8 7v4.5M12 11.5h1.2")], width: 1.4),
        "colors": Glyph(parts: [.path("M9 2.5a6.5 6.5 0 1 0 0 13c1 0 1.5-.6 1.5-1.3 0-1-.9-1.2-.9-2s.6-1.2 1.4-1.2h1.6a2.9 2.9 0 0 0 2.9-2.9C15.5 5 12.6 2.5 9 2.5z"),
                                .dot(5.6, 8.4, 1), .dot(7.6, 5.4, 1), .dot(11, 5.4, 1)], width: 1.4, round: false),
        // Two squares and a dashed corner.
        "gaps": Glyph(parts: [.rect(2.5, 2.5, 5.5, 5.5), .rect(10, 10, 5.5, 5.5), .path("M10 2.5h5.5V8", dash: [1.6, 1.6])], width: 1.4, round: false),
        "check": Glyph(parts: [.path("M3.5 9.5l3.5 3.5 7.5-8.5")], width: 1.6),
    ]

    var body: some View {
        Canvas { ctx, sz in
            guard let g = Self.glyphs[name] else { return }
            let k = sz.width / 18
            var t = CGAffineTransform(translationX: 9, y: 9).rotated(by: g.turn * .pi / 180).translatedBy(x: -9, y: -9)
            t = t.concatenating(CGAffineTransform(scaleX: k, y: k))
            let ink = GraphicsContext.Shading.foreground
            for part in g.parts {
                var dash: [CGFloat] = []
                switch part {
                case let .fill(d):
                    ctx.fill(HistoryGlyph.parse(d).applying(t), with: ink)
                    continue
                case let .dot(cx, cy, r):
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).applying(t), with: ink)
                    continue
                case let .path(d, dd):
                    dash = dd
                    ctx.stroke(HistoryGlyph.parse(d).applying(t), with: ink, style: style(g, k, dash))
                case let .rect(x, y, w, h, r):
                    ctx.stroke(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r).applying(t), with: ink, style: style(g, k, dash))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func style(_ g: Glyph, _ k: CGFloat, _ dash: [CGFloat]) -> StrokeStyle {
        StrokeStyle(lineWidth: g.width * k, lineCap: g.round ? .round : .butt,
                    lineJoin: g.round ? .round : .miter, dash: dash.map { $0 * k })
    }
}
