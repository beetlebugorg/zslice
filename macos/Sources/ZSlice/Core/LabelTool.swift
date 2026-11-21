//! The Label tool (L), as web/app/label.js: labels on the surface of a
//! part, each in a filament of its own (Label.swift, docs/user/labels.md).
//!
//! - A click on a face of a part adds a label there ("LABEL", 5 mm), in
//!   the filament after the filament of the part. A click on a label
//!   selects it, and its card opens (LabelCard.swift).
//! - A drag of a label moves it on the surface; Shift keeps its plane.
//!   The wheel over the selected label turns it 1° a step (Shift: 15°).
//!   The handle at its corner scales it. Delete removes it.
//! - The view keeps the beads. The labels of the part show as decals on
//!   its surface (FrameRenderer.drawLabels): the outline of each label
//!   comes from the core (zs_label_outline) with no slice, so a drag, a
//!   turn, or a key in the text field draws at once. A change goes to the
//!   core 400 ms after the last one, or at the end of a drag
//!   (zs_app_label_update), as one step of the history, and the plate
//!   slices.
//!
//! The pick uses the mesh of the part in a paint session of the core
//! (zs_paint_new, zs_label_place), one for each part, freed after a slice
//! or an undo (the part can be at another place then).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Observation

/// The facts of a label for its card (zs_app_label_info).
struct LabelInfo: Decodable, Equatable {
    var kind: String?
    var same_filament: Bool?
    var thinnest: Double?
    var gap: Double?
    var line_width: Double?
    var depth: Double?
    var clean_size: Double?
    var fair_size: Double?
    var weight: Double?
    var z_min: Double?
    var z_max: Double?
    var layers: Int?
    var estimate_changes: Int?
    var top_changes: Int?
    var sliced: Bool?
    var changes: Int?
    var minutes: Double?
    var grams: Double?
    var advice: String?
}

/// The state of the Label tool.
@MainActor
@Observable
final class LabelState {
    /// The part of the labels that show, and its filament (from 1).
    var index = -1
    var base = 1
    var labels: [PartLabel] = []
    /// The selected label.
    var sel: UInt32?
    /// The curve of the face under the selected label, degrees.
    var curve = 0.0
    var info: LabelInfo?
    /// The item that gets the points of clicks (a free line), or -1.
    var drawing = -1
    /// The corner handle and the box of the selected label on the screen.
    var handleAt: CGPoint?
    /// The round turn handle, 3 mm over the middle of the top of the label.
    var turnAt: CGPoint?
    var box: CGRect?

    @ObservationIgnored var outlines: [UInt32: (key: String, outline: LabelOutline)] = [:]
    @ObservationIgnored var sessions: [Int: OpaquePointer] = [:]
    @ObservationIgnored var drag: (id: UInt32, dx: Double, dy: Double, start: PartLabel, moved: Bool, at: CGPoint)?
    @ObservationIgnored var drawn: [[Double]] = []
    @ObservationIgnored var pending: UInt32?
    @ObservationIgnored var timer: Task<Void, Never>?
    @ObservationIgnored var scaling = false

    var label: PartLabel? { labels.first { $0.id == sel } }
}

extension Workspace {
    /// The lift of the decal out of the surface, mm.
    private static let labelLift = 0.05

    private var labelScale: Float { Float(canvas.window?.backingScaleFactor ?? 2) }

    // MARK: - open and close

    func openLabelTool() {
        showNote("Click a face of a part to put a label there. Drag a label to move it; the wheel turns it.")
        if let i = selectedPart { loadLabels(i) }
    }

    func closeLabelTool() {
        flushLabel()
        freeLabelSessions()
        labelState.labels = []
        labelState.index = -1
        selectLabel(nil)
        canvas.labelDecals = nil
    }

    private func freeLabelSessions() {
        for s in labelState.sessions.values { zs_paint_free(s) }
        labelState.sessions = [:]
    }

    /// The labels of part `index` from the core; `id`: the label to select
    /// (nil: keep the selection if the label is still there).
    func loadLabels(_ index: Int, select id: UInt32? = nil) {
        let st = labelState
        if index != st.index { selectLabel(nil) }
        let text = coreString { zs_app_part_labels_get(model.core, index, $0, $1, $2) } ?? "[]"
        // A change that waits for its pause keeps its values.
        let keep = index == st.index ? st.pending.flatMap { p in st.labels.first { $0.id == p } } : nil
        st.index = index
        st.labels = PartLabel.list(text).map { l in keep.map { $0.id == l.id ? $0 : l } ?? l }
        let own = coreString { zs_app_part_setting_get(model.core, index, "project.filament", $0, $1, $2) }
        st.base = max(Int(Double(own ?? model.entry("project.filament").value) ?? 1), 1)
        if let id { selectLabel(id) } else if st.label == nil { selectLabel(nil) }
        redrawLabels()
    }

    /// After an undo, a slice, or another plate: the labels again, and a
    /// new mesh for the pick.
    func reloadLabels() {
        guard tool == .label, labelState.drag == nil else { return }
        freeLabelSessions()
        if labelState.index >= 0, part(labelState.index) != nil {
            loadLabels(labelState.index)
        } else {
            labelState.labels = []
            labelState.index = -1
            selectLabel(nil)
            redrawLabels()
        }
        loadLabelInfo()
    }

    /// The paint session of the mesh of part `index`, for the pick.
    private func labelSession(_ index: Int) -> OpaquePointer? {
        if let s = labelState.sessions[index] { return s }
        var vp: UnsafePointer<Float>?
        var fp: UnsafePointer<UInt32>?
        var nv = 0, nf = 0
        guard zs_app_part_mesh(model.core, index, &vp, &nv, &fp, &nf) == 0, let vp, let fp, nf > 0 else { return nil }
        var s: OpaquePointer?
        guard zs_paint_new(vp, nv, fp, nf, &s) == 0, let s else { return nil }
        labelState.sessions[index] = s
        return s
    }

    /// The ray of the view at a point: origin and direction (6 floats).
    private func labelRay(_ p: CGPoint) -> [Float]? {
        guard let v = canvas.view else { return nil }
        var ray = [Float](repeating: 0, count: 6)
        guard zs_view_ray(v, Float(p.x) * labelScale, Float(p.y) * labelScale, &ray) != 0 else { return nil }
        return ray
    }

    private func rayVectors(_ r: [Float]) -> (SIMD3<Double>, SIMD3<Double>) {
        (SIMD3(Double(r[0]), Double(r[1]), Double(r[2])), SIMD3(Double(r[3]), Double(r[4]), Double(r[5])))
    }

    /// The paint session and the ray of the view, for a paste
    /// (Clipboard.swift).
    func labelSessionFor(_ index: Int) -> OpaquePointer? { labelSession(index) }
    func labelRayAt(_ p: CGPoint) -> [Float]? { labelRay(p) }

    /// The outline of a label, made again only when its shapes change.
    func labelOutline(_ l: PartLabel) -> LabelOutline? {
        let key = l.shapeJson
        if let have = labelState.outlines[l.id], have.key == key { return have.outline }
        if let o = LabelOutline(l) {
            labelState.outlines[l.id] = (key, o)
            return o
        }
        return labelState.outlines[l.id]?.outline
    }

    /// The label under a point (the selected label first), with the point
    /// in its plane.
    private func labelAt(_ p: CGPoint) -> (label: PartLabel, x: Double, y: Double)? {
        guard let r = labelRay(p) else { return nil }
        let (o, d) = rayVectors(r)
        let order = labelState.labels.sorted { a, _ in a.id == labelState.sel }
        for l in order {
            guard let ol = labelOutline(l), let h = l.planeHit(o, d) else { continue }
            let m = 1.0
            if h.x >= ol.box.x0 - m, h.x <= ol.box.x1 + m, h.y >= ol.box.y0 - m, h.y <= ol.box.y1 + m { return (l, h.x, h.y) }
        }
        return nil
    }

    /// The decals of the labels of the part to the GPU.
    func redrawLabels() {
        let fils = model.filaments
        func rgb(_ hex: String) -> SIMD3<Float> {
            guard hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return SIMD3(0.82, 0.82, 0.8) }
            return SIMD3(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255
        }
        var list: [LabelDecals.Input] = []
        for l in labelState.labels {
            guard let ol = labelOutline(l) else { continue }
            let n = ol.pts.count / 2
            var pts = [Float](repeating: 0, count: 3 * n)
            for i in 0 ..< n {
                let q = l.toBed(Double(ol.pts[2 * i]), Double(ol.pts[2 * i + 1]), lift: Self.labelLift)
                pts[3 * i] = Float(q.x); pts[3 * i + 1] = Float(q.y); pts[3 * i + 2] = Float(q.z)
            }
            let color = rgb(fils.indices.contains(l.filament - 1) ? fils[l.filament - 1].color : fils.first?.color ?? "")
            // The outline of the selected label in a color that stands out
            // of its fill.
            let light = 0.3 * color.x + 0.59 * color.y + 0.11 * color.z
            let edge: SIMD3<Float>? = l.id == labelState.sel ? (light > 0.5 ? SIMD3(0.1, 0.1, 0.12) : SIMD3(1, 0.85, 0.2)) : nil
            list.append(LabelDecals.Input(pts: pts, ends: ol.ends, color: color, edge: edge))
        }
        canvas.labelDecals = list.isEmpty ? nil : list
        placeLabelHandle()
    }

    /// The labels of part i, for its card.
    func partLabels(_ i: Int) -> [PartLabel] {
        _ = model.settingsGeneration
        return PartLabel.list(coreString { zs_app_part_labels_get(model.core, i, $0, $1, $2) } ?? "[]")
    }

    /// The Label tool on a label of part i (the list of the part card).
    func openLabel(part i: Int, id: UInt32) {
        if tool != .label { setTool(.label) }
        loadLabels(i, select: id)
    }

    // MARK: - the selection

    func selectLabel(_ id: UInt32?) {
        let st = labelState
        if id != st.sel {
            flushLabel()
            st.drawing = -1
        }
        st.sel = id
        guard st.label != nil else {
            st.sel = nil
            st.info = nil
            st.curve = 0
            st.handleAt = nil
            st.turnAt = nil
            st.box = nil
            if tool == .label { redrawLabels() }
            return
        }
        redrawLabels()
        loadLabelInfo()
    }

    func loadLabelInfo() {
        let st = labelState
        guard let l = st.label, st.index >= 0 else { return }
        let text = coreString { zs_app_label_info(model.core, st.index, l.id, $0, $1, $2) } ?? ""
        st.info = try? JSONDecoder().decode(LabelInfo.self, from: Data(text.utf8))
    }

    // MARK: - the changes

    /// A change of the selected label: the preview at once, and the core
    /// after a pause (commit: at once). False if the label stays (a shape
    /// out of range).
    @discardableResult
    func changeLabel(commit: Bool = false, _ fn: (PartLabel) -> PartLabel?) -> Bool {
        let st = labelState
        guard let l = st.label, let i = st.labels.firstIndex(where: { $0.id == l.id }), let next = fn(l) else { return false }
        if next.shapeJson != l.shapeJson, LabelOutline(next) == nil { return false }
        st.labels[i] = next
        redrawLabels()
        st.timer?.cancel()
        st.pending = l.id
        if commit {
            flushLabel()
        } else if st.drag == nil, !st.scaling {
            st.timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { self?.flushLabel() }
            }
        }
        return true
    }

    /// Sends the pending change of the selected label to the core: one step
    /// of the history, and a slice.
    func flushLabel() {
        let st = labelState
        st.timer?.cancel()
        guard let id = st.pending else { return }
        st.pending = nil
        guard let l = st.labels.first(where: { $0.id == id }), st.index >= 0 else { return }
        let json = l.json
        let rc = json.withCString { zs_app_label_update(model.core, st.index, id, $0, strlen($0)) }
        if rc != 0 { showNote("The label did not change: a value is out of range.") }
        model.settingsChanged()
        loadLabelInfo()
    }

    func editLabelItem(_ i: Int, commit: Bool = false, _ patch: (inout LabelItem) -> Void) -> Bool {
        changeLabel(commit: commit) { l in
            guard l.items.indices.contains(i) else { return nil }
            var n = l
            patch(&n.items[i])
            return n
        }
    }

    func setLabelShape(_ i: Int, _ kind: String) {
        _ = editLabelItem(i, commit: true) { $0 = $0.changed(to: kind) }
    }

    /// A new item in the label, under the items that are there (ticks and
    /// a ring go around the center, under the text).
    func addLabelItem(_ kind: String) {
        changeLabel(commit: true) { l in
            let ol = labelOutline(l)
            let size = l.items.first { $0.kind == "text" }?.size ?? 5
            var it = LabelItem.new(kind, size: size)
            if kind == "ticks" || kind == "ring" {
                let r = kind == "ticks" ? (it.radius ?? 0) + (it.length_end ?? 0) : (it.outer ?? 0)
                it.at = [0, (ol?.box.y0 ?? 0) - r - 1]
            } else if let ol, !l.items.isEmpty {
                it.at = [0, ol.box.y0 - size]
            }
            var n = l
            n.items.append(it)
            return n
        }
    }

    func removeLabelItem(_ i: Int) {
        changeLabel(commit: true) { l in
            guard l.items.count > 1 else { return nil }
            var n = l
            n.items.remove(at: i)
            return n
        }
    }

    func setLabelFilament(_ n: Int) { changeLabel(commit: true) { var l = $0; l.filament = n; return l } }
    func setLabelDepth(_ mm: Double) { changeLabel(commit: true) { var l = $0; l.depth = max(0, min(10, mm)); return l } }
    func setLabelAngle(_ deg: Double) { changeLabel { $0.withAngle(deg) } }
    func turnLabel(_ deg: Double) { changeLabel { $0.turned(deg) } }

    func addLabelFilament() {
        if let i = model.addFilament() { setLabelFilament(i + 1) }
    }

    func removeLabel() {
        let st = labelState
        guard let l = st.label, st.index >= 0 else { return }
        st.timer?.cancel()
        st.pending = nil
        zs_app_label_remove(model.core, st.index, l.id)
        model.settingsChanged()
        st.outlines[l.id] = nil
        st.labels.removeAll { $0.id == l.id }
        selectLabel(nil)
    }

    /// A new label at a point of the view: on the face of the part there.
    private func addLabel(at p: CGPoint) {
        let log = ProcessInfo.processInfo.environment["ZSLICE_LABEL_LOG"] != nil
        guard let i = partAt(p) else {
            if log { NSLog("zslice label: no part at %.0f, %.0f", p.x, p.y) }
            selectLabel(nil)
            return
        }
        if i != labelState.index { loadLabels(i) }
        guard let s = labelSession(i), let r = labelRay(p), let at = LabelPlace(s, ray: r) else {
            if log { NSLog("zslice label: no face at %.0f, %.0f (session %d, ray %d)", p.x, p.y, labelSession(i) == nil ? 0 : 1, labelRay(p) == nil ? 0 : 1) }
            showNote("Click a face of the part to put a label there.")
            return
        }
        let label = PartLabel(origin: Array(at.origin), normal: Array(at.normal), right: Array(at.right),
                              filament: PartLabel.nextFilament(labelState.base, model.filaments.count), depth: 0, items: [LabelItem.new("text")])
        var id: UInt32 = 0
        let json = label.json
        let rc = json.withCString { zs_app_label_add(model.core, i, $0, strlen($0), &id) }
        guard rc == 0 else {
            if log { NSLog("zslice label: the core refused the label (%d): %@", rc, json) }
            showNote("The label does not fit here.")
            return
        }
        model.settingsChanged()
        loadLabels(i, select: id)
        labelState.curve = at.curve
        labelFocusText += 1
        if ProcessInfo.processInfo.environment["ZSLICE_LABEL_LOG"] != nil {
            NSLog("zslice label: added %u on part %ld, %@, curve %.1f, filament %ld", id, i, labelState.info?.kind ?? "?", at.curve, label.filament)
        }
    }

    // MARK: - free lines

    func startLabelDrawing(_ i: Int) {
        labelState.drawing = i
        labelState.drawn = []
    }

    func stopLabelDrawing() {
        labelState.drawing = -1
        flushLabel()
    }

    private func labelDrawPoint(_ p: CGPoint) {
        let st = labelState
        guard let l = st.label, st.items(st.drawing)?.kind == "polyline", let r = labelRay(p) else { return }
        let (o, d) = rayVectors(r)
        guard let h = l.planeHit(o, d) else { return }
        let it = l.items[st.drawing]
        let a = -(it.angle ?? 0) * .pi / 180
        let x = h.x - (it.at?.first ?? 0), y = h.y - (it.at?.last ?? 0)
        st.drawn.append([x * cos(a) - y * sin(a), x * sin(a) + y * cos(a)])
        if st.drawn.count >= 2 { _ = editLabelItem(st.drawing) { $0.points = st.drawn } }
    }

    // MARK: - the mouse

    /// A press of the Label tool. True: the tool took it.
    func labelPress(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard page == .threeD, !flags.contains(.control) else { return false }
        let st = labelState
        if st.drawing >= 0 {
            labelDrawPoint(p)
            return true
        }
        guard let hit = labelAt(p) else {
            addLabel(at: p)
            return true
        }
        if hit.label.id != st.sel { selectLabel(hit.label.id) }
        guard let l = st.label else { return true }
        st.drag = (l.id, hit.x, hit.y, l, false, p)
        _ = labelSession(st.index)
        return true
    }

    func labelDrag(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) {
        guard var d = labelState.drag else { return }
        if !d.moved, hypot(p.x - d.at.x, p.y - d.at.y) < 3 { return }
        d.moved = true
        labelState.drag = d
        guard let r = labelRay(p) else { return }
        let (o, dir) = rayVectors(r)
        if flags.contains(.shift) {
            // In its plane.
            guard let h = d.start.planeHit(o, dir) else { return }
            let origin = h.p - d.dx * d.start.r - d.dy * d.start.up
            changeLabel { var l = $0; l.origin = Array(origin); l.normal = d.start.normal; l.right = d.start.right; return l }
            return
        }
        guard let s = labelState.sessions[labelState.index], let at = LabelPlace(s, ray: r) else { return }
        changeLabel { l in
            var m = l.moved(origin: at.origin, normal: at.normal)
            m.origin = Array(m.o - d.dx * m.r - d.dy * m.up)
            return m
        }
        if abs(at.curve - labelState.curve) > 1e-6 { labelState.curve = at.curve }
    }

    func labelRelease() -> Bool {
        guard let d = labelState.drag else { return false }
        labelState.drag = nil
        if d.moved { flushLabel() }
        return true
    }

    /// The wheel over the selected label turns it (Shift: 15° a step).
    func labelWheel(_ p: CGPoint, _ dy: CGFloat, shift: Bool) -> Bool {
        guard tool == .label, page == .threeD, labelState.sel != nil, dy != 0, let hit = labelAt(p), hit.label.id == labelState.sel else { return false }
        turnLabel((dy > 0 ? 1 : -1) * (shift ? 15 : 1))
        return true
    }

    // MARK: - the handle and the box on the screen

    private func labelScreen(_ l: PartLabel, _ x: Double, _ y: Double) -> CGPoint? {
        let q = l.toBed(x, y, lift: Self.labelLift)
        return canvas.viewPoint(x: q.x, y: q.y, z: q.z)
    }

    /// After each frame: the scale handle at the upper right corner of the
    /// selected label, the turn handle over its top, and its box on the
    /// screen (for the card).
    func placeLabelHandle() {
        let st = labelState
        guard tool == .label, page == .threeD, let l = st.label, let ol = labelOutline(l) else {
            if st.handleAt != nil { st.handleAt = nil }
            if st.turnAt != nil { st.turnAt = nil }
            if st.box != nil { st.box = nil }
            return
        }
        func moved(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
            switch (a, b) {
            case let (a?, b?): hypot(a.x - b.x, a.y - b.y) > 0.5
            case (nil, nil): false
            default: true
            }
        }
        let h = labelScreen(l, ol.box.x1 + 0.5, ol.box.y1 + 0.5)
        if moved(h, st.handleAt) { st.handleAt = h }
        let t = labelScreen(l, (ol.box.x0 + ol.box.x1) / 2, ol.box.y1 + 3)
        if moved(t, st.turnAt) { st.turnAt = t }
        var pts: [CGPoint] = []
        for x in [ol.box.x0 - 1, ol.box.x1 + 1] { for y in [ol.box.y0 - 1, ol.box.y1 + 1] { if let q = labelScreen(l, x, y) { pts.append(q) } } }
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return }
        let g: CGFloat = 12
        let b = CGRect(x: x0 - g, y: y0 - g, width: x1 - x0 + 2 * g, height: y1 - y0 + 2 * g)
        if st.box.map({ abs($0.minX - b.minX) + abs($0.minY - b.minY) + abs($0.width - b.width) > 1 }) ?? true { st.box = b }
    }

    /// The center of the selected label on the screen, for the scale.
    func labelScreenCenter() -> CGPoint? {
        guard let l = labelState.label, let ol = labelOutline(l) else { return nil }
        return labelScreen(l, (ol.box.x0 + ol.box.x1) / 2, (ol.box.y0 + ol.box.y1) / 2)
    }

    /// A drag of the handle: the label scaled by the distance from its
    /// center over the distance at the start.
    func scaleLabel(from start: PartLabel, by k: Double) {
        changeLabel { _ in start.scaled(max(0.05, k)) }
    }

    /// The sense of a turn on the screen: 1 when the label shows from its
    /// front (its right and up axes turn clockwise on the y-down screen),
    /// else -1. So a drag of the turn handle follows the pointer from the
    /// front or the back.
    func labelTurnSign(_ l: PartLabel) -> Double {
        guard let ol = labelOutline(l) else { return -1 }
        let cx = (ol.box.x0 + ol.box.x1) / 2, cy = (ol.box.y0 + ol.box.y1) / 2
        guard let p0 = labelScreen(l, cx, cy), let pr = labelScreen(l, cx + 1, cy), let pu = labelScreen(l, cx, cy + 1) else { return -1 }
        let cross = (pr.x - p0.x) * (pu.y - p0.y) - (pr.y - p0.y) * (pu.x - p0.x)
        return cross < 0 ? -1 : 1
    }

    /// A drag of the turn handle: the label turned by the angle of the
    /// pointer around the center of the label on the screen, from `a0`
    /// (radians). Shift: the total turn in steps of 15°.
    func turnLabelHandle(from start: PartLabel, center c: CGPoint, a0: Double, sign: Double, to p: CGPoint, snap: Bool) {
        var d = sign * (atan2(p.y - c.y, p.x - c.x) - a0) * 180 / .pi
        if snap {
            let base = start.angle
            d = ((base + d) / 15).rounded() * 15 - base
        }
        changeLabel { _ in start.turned(d) }
    }
}

private extension LabelState {
    func items(_ i: Int) -> LabelItem? {
        guard let l = label, l.items.indices.contains(i) else { return nil }
        return l.items[i]
    }
}
