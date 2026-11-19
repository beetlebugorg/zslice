//! Gaps and Check: two views of what can go wrong with the print
//! (docs/user/getting-started.md, "Gaps" and "Check the print").
//!
//! Gaps (G): the view shows the gaps of the top layer of the layer slider
//! in red (zs_view_show_gaps): the areas that should be solid that no line
//! covers. A click on a gap (zs_view_gap_at) opens its card: its size, its
//! width, and the settings that can close it, the best first
//! (zs_app_gap_advice). Apply changes the setting for the print; This
//! layer changes it only for the layer of the gap (zs_app_override_set).
//!
//! Check: the list of the core (zs_app_checks) of what can make the print
//! fail, the worst first. A click on an issue goes to its layer and selects
//! its line.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// A gap of the top layer, for its card.
struct GapInfo {
    var layer: Int
    var index: Int
    var area: Double
    var width: Double
    var steps: [(name: String, value: String, why: String)]
}

/// One issue of the check.
struct Issue: Identifiable {
    var id: Int
    var kind: UInt8
    var severity: UInt8
    var layer: Int
    var path: Int?
    /// Its place, mm.
    var x = 0.0, y = 0.0
    /// Its size: an area in mm² for an overhang or an island.
    var value: Double
    var text: String

    var symbol: String {
        switch Int32(kind) {
        case Int32(ZS_ISSUE_FLOW.rawValue): "gauge.with.dots.needle.100percent"
        case Int32(ZS_ISSUE_COOLING.rawValue): "snowflake"
        case Int32(ZS_ISSUE_OVERHANG.rawValue): "arrow.down.to.line"
        case Int32(ZS_ISSUE_ISLAND.rawValue): "circle.dotted"
        case Int32(ZS_ISSUE_RETRACTIONS.rawValue): "arrow.uturn.backward"
        // A part that its brim holds up, or that can tip over.
        case Int32(ZS_ISSUE_STAND.rawValue): "figure.fall"
        default: "rectangle.split.3x1"
        }
    }
}

extension Workspace {
    // MARK: - gaps

    func toggleGaps() {
        gapsOn.toggle()
        gapCard = nil
        showGaps()
    }

    /// The gaps of the top layer in the view, and their count and area.
    func showGaps() {
        guard let v = canvas.view else { return }
        let on = gapsOn && model.state == .done && layerCount > 0
        zs_view_show_gaps(v, model.core, on ? Int64(hi) : -1)
        gapSummary = nil
        if on {
            var gaps: UnsafePointer<zs_gap>?
            var n = 0
            var runs: UnsafePointer<zs_gap_run>?
            var nr = 0
            if zs_app_layer_gaps(model.core, hi, &gaps, &n, &runs, &nr) == 0, let gaps {
                let area = (0 ..< n).reduce(0.0) { $0 + gaps[$1].area }
                gapSummary = (n, area)
            }
        }
        canvas.requestFrame()
    }

    /// A click with Gaps on: the gap there opens its card. Returns false if
    /// no gap is there.
    func pickGap(at p: CGPoint) -> Bool {
        guard gapsOn, page == .threeD, let v = canvas.view else { return false }
        let s = canvas.window?.backingScaleFactor ?? 2
        let i = zs_view_gap_at(v, model.core, Float(p.x * s), Float(p.y * s))
        guard i >= 0 else {
            gapCard = nil
            return false
        }
        var gaps: UnsafePointer<zs_gap>?
        var n = 0
        var runs: UnsafePointer<zs_gap_run>?
        var nr = 0
        guard zs_app_layer_gaps(model.core, hi, &gaps, &n, &runs, &nr) == 0, let gaps, Int(i) < n else { return false }
        let g = gaps[Int(i)]
        var out = [zs_gap_step](repeating: zs_gap_step(), count: 6)
        var count = 0
        _ = zs_app_gap_advice(model.core, hi, Int(i), &out, out.count, &count)
        func text(_ p: UnsafePointer<CChar>?, _ len: Int) -> String {
            guard let p else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
        }
        gapCard = GapInfo(layer: hi, index: Int(i), area: g.area, width: g.width,
                          steps: out.prefix(count).map { (text($0.name, $0.name_len), text($0.value, $0.value_len), text($0.why, $0.why_len)) })
        cardAt = p
        return true
    }

    /// A setting from the card of a gap: for the print, or only for the
    /// layer of the gap.
    func applyGapStep(_ name: String, _ value: String, layerOnly: Bool) {
        if layerOnly, let g = gapCard {
            let z = Double(z(of: g.layer))
            if zs_app_override_set(model.core, z, z, name, value) == 0 { model.settingsChanged() }
        } else {
            model.set(name, value)
        }
    }

    // MARK: - the check

    /// The issues of the last slice, the worst first.
    func readIssues() {
        var list: UnsafePointer<zs_issue>?
        var n = 0
        var text: UnsafePointer<CChar>?
        guard model.state == .done, zs_app_checks(model.core, &list, &n, &text) == 0, let list, let text else {
            issues = []
            return
        }
        issues = (0 ..< n).map { i in
            let it = list[i]
            let t = String(decoding: UnsafeRawBufferPointer(start: text + Int(it.text_start), count: Int(it.text_len)), as: UTF8.self)
            return Issue(id: i, kind: it.kind, severity: it.severity, layer: Int(it.layer),
                         path: it.path == ZS_NO_PATH ? nil : Int(it.path), x: it.x, y: it.y, value: it.value, text: t)
        }
        // The card of a line opened before the check ran: its warnings now.
        if let l = lineInfo { lineInfo?.issues = lineIssues(ofPath: l.path, layer: l.layer) }
    }

    /// With support off: the area of the part that hangs in the air (the
    /// overhangs and islands of severity 1 or more, not the bridges), in
    /// mm², when it is 20 mm² or more; else nil.
    // MARK: - the notes of the print (the badge of the bottom bar)

    /// The notes of the details pane: a part off the bed, parts that look
    /// too small, an area with no support, a failed slice.
    var noteCount: Int {
        var n = 0
        if model.state == .done, !plateFits { n += 1 }
        if model.state == .done, !tinyParts.isEmpty { n += 1 }
        if model.state == .done, unsupportedArea != nil || simResult?.checkText != nil { n += 1 }
        if case .failed = model.state { n += 1 }
        return n
    }

    /// A note that stops the print (red, not orange).
    var noteIsError: Bool {
        if case .failed = model.state { return true }
        return model.state == .done && !plateFits
    }

    var unsupportedArea: Double? {
        guard model.setting("project.support") == "off" else { return nil }
        let sum = issues.filter { ($0.kind == UInt8(ZS_ISSUE_OVERHANG.rawValue) || $0.kind == UInt8(ZS_ISSUE_ISLAND.rawValue)) && $0.severity >= 1 }
            .reduce(0) { $0 + $1.value }
        return sum >= 20 ? sum : nil
    }

    /// Goes to the layer of an issue, and selects its line.
    func show(_ issue: Issue) {
        setRange(lo: lo, hi: max(issue.layer, lo))
        if let p = issue.path {
            select(path: p, seg: 0, openCard: false)
        }
    }
}
