//! The Inspector: a column of the window beside the view (web/app/dock.js,
//! docs/internals/one-view.md). The view has the rest of the window, so no
//! panel of a selection draws over the 3D or the 2D view.
//!
//! The column has two tabs, Inspector and Settings. The Inspector tab shows
//! one page: the most specific of a label, paint, support, a gap, a range of
//! layers, a part, or a line. With none, it shows the summary of the plate
//! and its parts. A selection only changes this content. It never opens,
//! closes, or resizes the column, and the camera stays. With the column
//! closed, a dot on its toolbar button says that a selection has a page.
//!
//! In a narrow window the column is a row under the view, and only the user
//! opens it. The width, the open state, and the collapsed groups stay in the
//! preferences of the app.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import SwiftUI

enum DockTab: String { case inspector, settings }

/// The page of the Inspector tab, the most specific first.
enum DockKind: String { case label, paint, support, pickedSupport, gap, range, part, line, plate }

extension Workspace {
    /// A window narrower than this has a row under the view.
    static let narrowWidth: CGFloat = 1040
    /// The least width of the view beside the column: the bottom bar fits.
    static let leastViewWidth: CGFloat = 720
    /// The most parts in the list of the plate.
    static let maxListedParts = 60

    var narrowWindow: Bool { windowWidth > 0 && windowWidth <= Self.narrowWidth }

    /// The widest column that leaves the view its least width.
    var widestColumn: CGFloat { max(300, min(560, windowWidth - Self.leastViewWidth)) }

    /// The column or the row shows now.
    var dockShown: Bool { !farmOpen && (narrowWindow ? dockRowOpen : showSettings) }

    var dockKind: DockKind {
        let in3D = page == .threeD
        if tool == .label, in3D, labelState.label != nil { return .label }
        if paint != nil, in3D { return .paint }
        if tool == .support, supportPaneOpen, in3D { return .support }
        if tool != .support, supportPick != nil, in3D { return .pickedSupport }
        if gapCard != nil { return .gap }
        if rangeCard != nil, in3D { return .range }
        if selectedPart != nil { return .part }
        if selection != nil, lineInfo != nil { return .line }
        return .plate
    }

    /// The dot of the toolbar button: a selection has a page that is hidden.
    var dockHasNews: Bool { dockKind != .plate && !(dockShown && dockTab == .inspector) }

    func openDock(_ tab: DockTab) {
        dockTab = tab
        if narrowWindow { dockRowOpen = true } else { showSettings = true }
    }

    func closeDock() {
        if narrowWindow { dockRowOpen = false } else { showSettings = false }
    }

    func toggleDock() {
        if dockShown { closeDock() } else { openDock(dockTab) }
    }

    func groupBinding(_ title: String) -> Binding<Bool> {
        Binding(get: { !self.closedGroups.contains(title) }, set: { open in
            if open { self.closedGroups.remove(title) } else { self.closedGroups.insert(title) }
            prefs.set(Array(self.closedGroups).sorted(), forKey: "inspectorClosedGroups")
        })
    }

    /// The settings of the regions of part i, by region. A body region
    /// stores "no walls of its own" (App.regionSet): the user did not set
    /// that value, so it does not show.
    func partRegions(_ i: Int) -> [(name: String, rows: [(info: SettingInfo, value: String)])] {
        _ = model.settingsGeneration
        guard let text = coreString({ zs_app_part_settings(model.core, i, $0, $1, $2) }) else { return [] }
        var out: [(name: String, rows: [(info: SettingInfo, value: String)])] = []
        var inVolume = false, isRegion = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("Volume \""), line.hasSuffix("\":") {
                let name = String(line.dropFirst(8).dropLast(2))
                inVolume = true
                isRegion = name.wholeMatch(of: /(Region|Pick) \d+/) != nil
                out.append((name, []))
                continue
            }
            guard inVolume, !line.contains(": not used"),
                  let m = line.wholeMatch(of: /\s+([a-z]+\.[a-z0-9_]+) = (.*)/) else { continue }
            let key = String(m.1), value = String(m.2)
            if isRegion, key == "project.wall_count", value == "0" { continue }
            guard let info = SettingInfo.byName[key] else { continue }
            out[out.count - 1].rows.append((info, value))
        }
        return out.filter { !$0.rows.isEmpty }
    }

    /// One value of the pose of part i: one call, one step of the history.
    /// key: x, y, z, ax, ay, or az.
    func setPose(_ i: Int, _ key: String, _ v: Double) {
        guard let p = part(i) else { return }
        switch key {
        case "x": zs_app_part_move(model.core, i, v, p.y)
        case "y": zs_app_part_move(model.core, i, p.x, v)
        case "z": zs_app_part_lift(model.core, i, v)
        case "ax": zs_app_part_set_angles(model.core, i, v, p.angle_y, p.angle_z)
        case "ay": zs_app_part_set_angles(model.core, i, p.angle_x, v, p.angle_z)
        default: zs_app_part_set_angles(model.core, i, p.angle_x, p.angle_y, v)
        }
        selectPart(i)
        // A part in the air with no support falls, and a part on an edge
        // tips over.
        if key == "x" || key == "y" { model.settingsChanged() } else {
            settle(part: i) { [weak self] in self?.model.settingsChanged() }
        }
    }
}

// MARK: - the test of the column

extension Workspace {
    /// ZSLICE_DOCK_TEST=1: each kind of selection at four window widths (the
    /// narrowest with its row closed and open) and three cameras. A selection must keep the frame of the view, the
    /// camera, the open state, and what a click over the view hits.
    func runDockTest() async {
        guard let w = canvas.window, let v = canvas.view else { return }
        var ok = 0, bad = 0, skipped = 0
        func camera() -> [Float] {
            var c = [Float](repeating: 0, count: 8)
            zs_view_get_camera(v, &c)
            return c
        }
        func hits() -> [String] {
            guard let root = w.contentView else { return [] }
            let b = canvas.convert(canvas.bounds, to: nil)
            var out: [String] = []
            for i in 1 ..< 8 { for j in 1 ..< 6 {
                let p = CGPoint(x: b.minX + b.width * CGFloat(i) / 8, y: b.minY + b.height * CGFloat(j) / 6)
                out.append(root.hitTest(root.superview?.convert(p, from: nil) ?? p).map { String(describing: type(of: $0)) } ?? "none")
            } }
            return out
        }
        func clear() {
            closeRangeCard()
            gapCard = nil
            clearSupportPick()
            selectLabel(nil)
            setTool(.select)
            selectOnlyPart(nil)
            clearSelection()
        }
        func enter(_ kind: DockKind, many: Bool = false) -> Bool {
            let mid = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            switch kind {
            case .part:
                selectOnlyPart(0)
                if many {
                    togglePart(1)
                    guard selectedParts.count == 2 else { return false }
                }
            case .pickedSupport:
                var tp = zs_toolpaths()
                guard zs_app_toolpaths(model.core, &tp) == 0, let features = tp.path_features,
                      let path = (0 ..< tp.path_count).first(where: { features[$0] == UInt8(ZS_FEATURE_SUPPORT.rawValue) }),
                      let q = pathPoint(path, seg: 0) else { return false }
                supportSelectAt(SIMD3(q.x, q.y, q.z))
            case .line:
                select(path: 0, seg: 0)
            case .range: openRangeCard(max(0, hi - 4), hi)
            case .gap:
                var gaps: UnsafePointer<zs_gap>?, runs: UnsafePointer<zs_gap_run>?
                var n = 0, nr = 0
                guard zs_app_layer_gaps(model.core, hi, &gaps, &n, &runs, &nr) == 0, let gaps, n > 0,
                      let at = canvas.viewPoint(x: gaps[0].x, y: gaps[0].y, z: layerTopBottom(hi)?.top ?? 0) else { return false }
                _ = pickGap(at: at)
            case .paint: setTool(.paint)
            case .support:
                supportPaneOpen = true
                setTool(.support)
            case .label:
                setTool(.label)
                // The first point of the part that takes a label.
                var spots = [mid]
                if let p = part(0) {
                    for a in stride(from: -0.45, through: 0.45, by: 0.15) { for b in stride(from: -0.45, through: 0.45, by: 0.15) {
                        if let q = canvas.viewPoint(x: p.x + a * p.size_x, y: p.y + b * p.size_y, z: p.size_z * 0.9) { spots.append(q) }
                    } }
                }
                for q in spots where labelState.label == nil {
                    _ = labelPress(q, [])
                    _ = labelRelease()
                }
            default: break
            }
            return dockKind == kind
        }
        // ZSLICE_DOCK_TEST=slicepick: a line picked while a slice starts
        // stays selected when the slice lands.
        if ProcessInfo.processInfo.environment["ZSLICE_DOCK_TEST"] == "slicepick" {
            await runSlicePickTest()
            return
        }
        // ZSLICE_DOCK_TEST=part (or another kind): that page stays, for a
        // screenshot, with the facts of the part.
        let mode = ProcessInfo.processInfo.environment["ZSLICE_DOCK_TEST"] ?? ""
        if let kind = DockKind(rawValue: mode) {
            if kind != .plate { _ = enter(kind) }
            dockTab = .inspector
            guard let p = part(0) else { return }
            let text = coreString { zs_app_part_settings(model.core, 0, $0, $1, $2) } ?? ""
            let walls = partRegions(0).flatMap(\.rows).filter { $0.info.name == "project.wall_count" }.count
            NSLog("zslice dock: page %@, regions %ld, stored wall rows %ld, shown wall rows %ld", dockKind.rawValue, partRegions(0).count,
                  text.components(separatedBy: "project.wall_count = 0").count - 1, walls)
            mirrorParts(axis: 0)
            scaleParts([0], by: 1.5)
            if let q = part(0) {
                NSLog("zslice dock: scale %.2f %.2f %.2f to %.2f %.2f %.2f", p.scale_x, p.scale_y, p.scale_z, q.scale_x, q.scale_y, q.scale_z)
            }
            return
        }
        // ZSLICE_DOCK_PARTS=2: two parts, for the page of several parts. A
        // copy can change the slice, so a run for gaps keeps one part.
        if ProcessInfo.processInfo.environment["ZSLICE_DOCK_PARTS"] == "2", zs_app_part_count(model.core) < 2 {
            selectOnlyPart(0)
            duplicatePart()
            try? await Task.sleep(for: .seconds(1))
            for _ in 0 ..< 400 where model.state != .done { try? await Task.sleep(for: .milliseconds(25)) }
        }
        for (width, row) in [(1500.0, false), (1100, false), (1000, false), (720, false), (720, true)] {
            var f = w.frame
            f.size.width = max(width, w.minSize.width)
            w.setFrame(f, display: true)
            try? await Task.sleep(for: .milliseconds(500))
            // A second step: the smallest width depends on the layout.
            f.size.width = max(width, w.minSize.width)
            w.setFrame(f, display: true)
            try? await Task.sleep(for: .milliseconds(500))
            NSLog("zslice dock: window %.0f (least %.0f, content %.0f), view %.0f, column %d, narrow %d", w.frame.width, w.minSize.width, w.contentMinSize.width, canvas.bounds.width, showSettings ? 1 : 0, narrowWindow ? 1 : 0)
            if showSettings, !narrowWindow, canvas.bounds.width >= w.frame.width - 200 || canvas.bounds.width < Self.leastViewWidth - 1 {
                bad += 1
                NSLog("zslice dock: FAIL %.0f the view is %.0f wide beside the column", width, canvas.bounds.width)
            }
            dockRowOpen = row
            try? await Task.sleep(for: .milliseconds(400))
            for (name, move) in [("home", (0, 0, 0, 0)), ("orbit", (60, 25, 0, 0)), ("pan", (0, 0, 40, 20))] as [(String, (Float, Float, Float, Float))] {
                zs_view_orbit(v, move.0, move.1)
                zs_view_pan(v, move.2, move.3)
                try? await Task.sleep(for: .milliseconds(700))
                for (kind, many) in [(DockKind.part, false), (.part, true), (.pickedSupport, false), (.line, false), (.range, false),
                                     (.gap, false), (.paint, false), (.support, false), (.label, false)] {
                    let page = many ? "parts" : kind.rawValue
                    clear()
                    try? await Task.sleep(for: .milliseconds(250))
                    let frame = canvas.convert(canvas.bounds, to: nil), cam = camera(), open = (showSettings, dockRowOpen), grid = hits()
                    guard enter(kind, many: many) else {
                        skipped += 1
                        NSLog("zslice dock: skip %.0f %@ %@", width, name, page)
                        continue
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                    let same = canvas.convert(canvas.bounds, to: nil) == frame && camera() == cam
                        && showSettings == open.0 && dockRowOpen == open.1 && hits() == grid
                    if same { ok += 1 } else {
                        bad += 1
                        NSLog("zslice dock: FAIL %.0f %@ %@ frame %d camera %d open %d hits %d", width, name, page,
                              canvas.convert(canvas.bounds, to: nil) == frame ? 1 : 0, camera() == cam ? 1 : 0,
                              showSettings == open.0 && dockRowOpen == open.1 ? 1 : 0, hits() == grid ? 1 : 0)
                    }
                }
            }
        }
        clear()
        NSLog("zslice dock: passed %d, failed %d, skipped %d", ok, bad, skipped)
    }
}

extension Workspace {
    private func runSlicePickTest() async {
        guard let v = canvas.view else { return }
        var tp = zs_toolpaths()
        guard zs_app_toolpaths(model.core, &tp) == 0, tp.path_count > 10 else { return }
        var kept = 0, same = 0
        let rounds = 8
        for round in 0 ..< rounds {
            let path = tp.path_count / 3 + round * 7
            let layer = zs_view_path_layer(v, path), feature = zs_view_path_feature(v, path)
            clearSelection()
            _ = model.set("project.infill_density", round % 2 == 0 ? "0.21" : "0.22")
            for _ in 0 ..< 200 where model.state == .done { try? await Task.sleep(for: .milliseconds(1)) }
            let during = model.state != .done
            select(path: path, seg: 0)
            let key = selection?.key ?? 0
            for _ in 0 ..< 400 where model.state != .done { try? await Task.sleep(for: .milliseconds(25)) }
            try? await Task.sleep(for: .milliseconds(900))
            for _ in 0 ..< 400 where model.state != .done { try? await Task.sleep(for: .milliseconds(25)) }
            try? await Task.sleep(for: .milliseconds(300))
            let now = selection.map { (zs_view_path_layer(v, $0.path), zs_view_path_feature(v, $0.path)) }
            if now != nil, lineInfo != nil { kept += 1 }
            if let now, now.0 == layer, now.1 == feature { same += 1 }
            NSLog("zslice slice pick: round %d, during %d, key %llu, kept %d, page %d, same place %d", round, during ? 1 : 0, key,
                  now == nil ? 0 : 1, lineInfo == nil ? 0 : 1, now?.0 == layer && now?.1 == feature ? 1 : 0)
        }
        NSLog("zslice slice pick: kept %d of %d, same layer and feature %d", kept, rounds, same)
    }
}

/// A group of the Inspector that the user can collapse.
struct InspectorGroup<Content: View>: View {
    let workspace: Workspace
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: workspace.groupBinding(title)) {
            VStack(alignment: .leading, spacing: 8, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Text(title).font(.callout.weight(.semibold))
        }
    }
}

/// The column (or the row of a narrow window): the two tabs and a page.
struct InspectorColumn: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Page", selection: Binding(get: { workspace.dockTab }, set: { workspace.dockTab = $0 })) {
                    Text("Inspector").tag(DockTab.inspector)
                    Text("Settings").tag(DockTab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button { workspace.closeDock() } label: { CloseMark() }
                    .buttonStyle(.borderless)
                    .help("Close the column (N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if workspace.dockTab == .settings {
                SettingsInspector(workspace: workspace)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    InspectorPage(workspace: workspace)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

/// The page of the selection, or the summary of the plate.
struct InspectorPage: View {
    let workspace: Workspace

    var body: some View {
        switch workspace.dockKind {
        case .label: LabelCard(workspace: workspace)
        case .paint:
            if let p = workspace.paint { PaintCard(workspace: workspace, paint: p) }
        case .support: SupportCard(workspace: workspace)
        case .pickedSupport: PickedSupportCard(workspace: workspace)
        case .gap:
            if let g = workspace.gapCard { GapCard(workspace: workspace, gap: g) }
        case .range:
            if let r = workspace.rangeCard { RangeCard(workspace: workspace, lo: r.lo, hi: r.hi) }
        case .part:
            if let i = workspace.selectedPart { PartCard(workspace: workspace, index: i).id(i) }
        case .line:
            if let info = workspace.lineInfo { LineCard(workspace: workspace, info: info) }
        case .plate: PlateSummary(workspace: workspace)
        }
    }
}

/// With no selection: the plate, its numbers, and a list of its parts.
private struct PlateSummary: View {
    let workspace: Workspace

    var body: some View {
        let model = workspace.model
        let _ = model.settingsGeneration
        let count = zs_app_part_count(model.core)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                let plate = model.plates.indices.contains(model.active) ? model.plates[model.active].name : ""
                Text(plate.isEmpty ? "Plate \(model.active + 1)" : plate).font(.headline)
                if let s = model.stats {
                    Text(String(format: "%@ · %.1f g · %d layers", PrintCard.duration(s.print_time_s), s.filament_g, s.layer_count))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if count > 0 {
                InspectorGroup(workspace: workspace, title: "Parts") {
                    ForEach(0 ..< min(count, Workspace.maxListedParts), id: \.self) { i in
                        if let p = workspace.part(i) {
                            Button { workspace.selectOnlyPart(i) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    let name = coreText(p.name)
                                    Text(name.isEmpty ? "Part \(i + 1)" : name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(String(format: "%.0f × %.0f × %.0f", p.size_x, p.size_y, p.size_z))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Select this part")
                        }
                    }
                    if count > Workspace.maxListedParts {
                        Text("And \(count - Workspace.maxListedParts) more.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(count > 0 ? "Select a part or a line in the view to see it here." : "Add a model to the plate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
