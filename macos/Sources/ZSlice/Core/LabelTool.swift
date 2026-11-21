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
import simd

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
    /// The handles of the selected label on the screen (LabelHandles draws
    /// them): the frame around its box, a square at each corner, and the
    /// round turn handle over the frame, each as the points of its outline
    /// in the plane of the label. And the box of the label on the screen
    /// (for the card).
    var frame: [CGPoint] = []
    var corners: [[CGPoint]] = []
    var turnRing: [CGPoint] = []
    /// The center of the turn handle on the screen.
    var turnAt: CGPoint?
    var box: CGRect?
    /// The lines of the smart guides on the screen, during a drag.
    var guides: [(CGPoint, CGPoint)] = []

    @ObservationIgnored var outlines: [UInt32: (key: String, outline: LabelOutline)] = [:]
    @ObservationIgnored var sessions: [Int: OpaquePointer] = [:]
    @ObservationIgnored var drag: LabelDrag?
    /// The guides of the snap in the plane of the label ([s0, t0, s1, t1]).
    @ObservationIgnored var planeGuides: [[Double]] = []
    /// The features of the face under the label (zs_label_face), the plane
    /// they are of, and the time of the last read.
    @ObservationIgnored var face: (json: String?, index: Int, origin: SIMD3<Double>, normal: SIMD3<Double>, time: Date)?
    @ObservationIgnored var drawn: [[Double]] = []
    @ObservationIgnored var pending: UInt32?
    @ObservationIgnored var timer: Task<Void, Never>?
    @ObservationIgnored var scaling = false

    var label: PartLabel? { labels.first { $0.id == sel } }
}

/// A drag of the Label tool: a move of the label (its body), a resize (a
/// corner: the opposite corner stays), or a turn (the round handle).
struct LabelDrag {
    enum Mode { case move, resize, turn }
    var mode: Mode
    var id: UInt32
    /// The point of the press in the plane of the label (a move).
    var dx = 0.0, dy = 0.0
    var start: PartLabel
    var moved = false
    var at: CGPoint
    /// A resize: the box of the outline at the press, and the corner that
    /// moves (+1: the high side).
    var box0 = [0.0, 0.0, 0.0, 0.0]
    var corner = [1, 1]
    /// A turn: the center of the box on the screen and in the plane, the
    /// angle of the press, the sense of a turn on the screen, and the turn
    /// of the label at the press.
    var turnC = CGPoint.zero
    /// A resize: the pointer in the plane less the corner of the outline
    /// box under the handle, at the press, so the first move scales by 1.
    var grab = (0.0, 0.0)
    var center = (0.0, 0.0)
    var a0 = 0.0, sign = 1.0, base = 0.0
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
            st.frame = []
            st.corners = []
            st.turnRing = []
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

    /// Ink, raised, or cut in. An ink label has no mode and no relief in
    /// its JSON; a raised or cut one keeps its relief, else the default.
    func setLabelMode(_ mode: String) {
        changeLabel(commit: true) { var l = $0
            if mode == "ink" {
                l.mode = nil
                l.relief = nil
            } else {
                l.mode = mode
                l.relief = (l.relief ?? 0) > 0 ? l.relief : PartLabel.defaultRelief
            }
            return l
        }
    }

    func setLabelRelief(_ mm: Double) { changeLabel(commit: true) { var l = $0; l.relief = max(0, min(10, mm)); return l } }

    /// The name of a label of an SVG file: the file name with no .svg.
    private func svgName(_ name: String) -> String {
        String((name.lowercased().hasSuffix(".svg") ? String(name.dropLast(4)) : name).prefix(120))
    }

    /// The filled shapes of an SVG, or nil: a picture with no shape that
    /// the core reads.
    private func svgOutlined(_ it: LabelItem) -> Bool {
        var l = PartLabel(origin: [0, 0, 0], normal: [0, 0, 1], right: [1, 0, 0], filament: 1, items: [it])
        l.id = 0
        return LabelOutline(l) != nil
    }

    /// An SVG picture into the selected label: it takes the place of the new
    /// text "LABEL", else it goes under the shapes. False for a picture with
    /// no filled shape.
    @discardableResult
    func placeLabelSVG(_ svg: String, name: String = "") -> Bool {
        let it = LabelItem.svg(svg)
        guard svgOutlined(it) else {
            showNote("The SVG has no filled shape to place.")
            return false
        }
        let named = svgName(name)
        changeLabel(commit: true) { l in
            var m = l
            if l.items.count == 1, l.items[0].kind == "text", l.items[0].text == "LABEL" {
                if (m.name ?? "").isEmpty, !named.isEmpty { m.name = named }
                m.items = [it]
            } else {
                var at = it
                at.at = [0, (labelOutline(l)?.box.y0 ?? 0) - LabelItem.svgSize / 2 - 1]
                m.items.append(at)
            }
            return m
        }
        return true
    }

    /// An SVG file dropped at a point of the view: a new label of it on the
    /// face of the part there.
    func dropLabelSVG(_ svg: String, at p: CGPoint, name: String = "") {
        let it = LabelItem.svg(svg)
        guard svgOutlined(it) else {
            showNote("The SVG has no filled shape to place.")
            return
        }
        guard page == .threeD, let i = partAt(p) else {
            showNote("Drop the SVG on a part.")
            return
        }
        if tool != .label { setTool(.label) }
        if i != labelState.index { loadLabels(i) }
        guard let s = labelSession(i), let r = labelRay(p), let at = LabelPlace(s, ray: r) else {
            showNote("Drop the SVG on a face of the part.")
            return
        }
        var label = PartLabel(origin: Array(at.origin), normal: Array(at.normal), right: Array(at.right),
                              filament: PartLabel.nextFilament(labelState.base, model.filaments.count), depth: 0, items: [it])
        let named = svgName(name)
        if !named.isEmpty { label.name = named }
        var id: UInt32 = 0
        let json = label.json
        guard json.withCString({ zs_app_label_add(model.core, i, $0, strlen($0), &id) }) == 0 else {
            showNote("The SVG does not fit here.")
            return
        }
        model.settingsChanged()
        loadLabels(i, select: id)
        labelState.curve = at.curve
    }
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
        // A handle of the selected label first.
        if let l = st.label, let ol = labelOutline(l), let h = labelHandleHit(p, l, ol) {
            flushLabel()
            var d = LabelDrag(mode: h.turn ? .turn : .resize, id: l.id, start: l, at: p)
            d.box0 = [ol.box.x0, ol.box.y0, ol.box.x1, ol.box.y1]
            d.corner = h.corner
            if !h.turn, let r = labelRay(p) {
                let (o, dir) = rayVectors(r)
                if let hit = l.planeHit(o, dir) {
                    let cx = h.corner[0] > 0 ? ol.box.x1 : ol.box.x0, cy = h.corner[1] > 0 ? ol.box.y1 : ol.box.y0
                    d.grab = (hit.x - cx, hit.y - cy)
                }
            }
            if h.turn {
                let cx = (ol.box.x0 + ol.box.x1) / 2, cy = (ol.box.y0 + ol.box.y1) / 2
                guard let c = labelScreen(l, cx, cy) else { return true }
                d.turnC = c
                d.center = (cx, cy)
                d.a0 = atan2(p.y - c.y, p.x - c.x)
                d.sign = labelTurnSign(l)
                d.base = l.angle
            }
            st.drag = d
            _ = labelSession(st.index)
            return true
        }
        guard let hit = labelAt(p) else {
            addLabel(at: p)
            return true
        }
        if hit.label.id != st.sel { selectLabel(hit.label.id) }
        guard let l = st.label else { return true }
        var d = LabelDrag(mode: .move, id: l.id, start: l, at: p)
        d.dx = hit.x
        d.dy = hit.y
        st.drag = d
        _ = labelSession(st.index)
        return true
    }

    func labelDrag(_ p: CGPoint, _ flags: NSEvent.ModifierFlags) {
        guard var d = labelState.drag else { return }
        if !d.moved, hypot(p.x - d.at.x, p.y - d.at.y) < 3 { return }
        d.moved = true
        labelState.drag = d
        let shift = flags.contains(.shift), free = flags.contains(.option)
        switch d.mode {
        case .move: labelMove(p, d, keepPlane: shift, free: free)
        case .resize: labelResize(p, d, freeAspect: shift, free: free)
        case .turn:
            var deg = d.sign * (atan2(p.y - d.turnC.y, p.x - d.turnC.x) - d.a0) * 180 / .pi
            if shift { deg = ((d.base + deg) / 15).rounded() * 15 - d.base }
            changeLabel { _ in d.start.turned(deg, about: d.center) }
        }
        showGuides()
    }

    /// The body: on the surface under the pointer, or in its plane with
    /// Shift. It snaps to the smart guides (Option: free).
    private func labelMove(_ p: CGPoint, _ d: LabelDrag, keepPlane: Bool, free: Bool) {
        guard let r = labelRay(p) else { return }
        let (o, dir) = rayVectors(r)
        var next: PartLabel
        if keepPlane {
            guard let h = d.start.planeHit(o, dir) else { return }
            next = d.start
            next.origin = Array(h.p - d.dx * d.start.r - d.dy * d.start.up)
        } else {
            guard let s = labelState.sessions[labelState.index], let at = LabelPlace(s, ray: r), let l = labelState.label else { return }
            next = l.moved(origin: at.origin, normal: at.normal)
            next.origin = Array(next.o - d.dx * next.r - d.dy * next.up)
            if abs(at.curve - labelState.curve) > 1e-6 { labelState.curve = at.curve }
        }
        labelState.planeGuides = []
        if !free, let ol = labelOutline(next),
           let snap = labelSnap(next, box: [ol.box.x0, ol.box.y0, ol.box.x1, ol.box.y1], op: "move", corner: nil, aspect: true) {
            next.origin = Array(next.o + snap.d[0] * next.r + snap.d[1] * next.up)
        }
        changeLabel { _ in next }
    }

    /// A corner: the opposite corner stays, and the aspect stays (Shift:
    /// each axis on its own, with the stretch). It snaps to the guides
    /// (Option: free). As zg_label_resize_box and zg_label_resize of the
    /// GTK app.
    private func labelResize(_ p: CGPoint, _ d: LabelDrag, freeAspect: Bool, free: Bool) {
        let s = d.start
        guard let r = labelRay(p) else { return }
        let (o, dir) = rayVectors(r)
        guard let h = s.planeHit(o, dir) else { return }
        let b0 = d.box0, c = d.corner
        let anchor = [c[0] > 0 ? b0[0] : b0[2], c[1] > 0 ? b0[1] : b0[3]]
        let c0 = [c[0] > 0 ? b0[2] : b0[0], c[1] > 0 ? b0[3] : b0[1]]
        let v = [c0[0] - anchor[0], c0[1] - anchor[1]]
        let hp = [h.x - d.grab.0, h.y - d.grab.1]
        var k = [1.0, 1.0]
        if freeAspect {
            for a in 0 ..< 2 { k[a] = abs(v[a]) > 1e-9 ? (hp[a] - anchor[a]) / v[a] : 1 }
        } else {
            let t = ((hp[0] - anchor[0]) * v[0] + (hp[1] - anchor[1]) * v[1]) / max(1e-12, v[0] * v[0] + v[1] * v[1])
            k = [t, t]
        }
        var box = [0.0, 0.0, 0.0, 0.0]
        for a in 0 ..< 2 {
            k[a] = max(0.05, k[a])
            let cc = anchor[a] + k[a] * v[a]
            box[a] = min(anchor[a], cc)
            box[a + 2] = max(anchor[a], cc)
        }
        labelState.planeGuides = []
        if !free, let snap = labelSnap(s, box: box, op: "resize", corner: c, aspect: !freeAspect) {
            k[0] = (snap.box[2] - snap.box[0]) / max(1e-12, b0[2] - b0[0])
            k[1] = freeAspect ? (snap.box[3] - snap.box[1]) / max(1e-12, b0[3] - b0[1]) : k[0]
        }
        var next = s
        if freeAspect {
            let st = s.stretch ?? [1, 1]
            next.stretch = [st[0] * k[0], (st.count > 1 ? st[1] : 1) * k[1]]
        } else {
            next = s.scaled(k[0])
        }
        next.origin = Array(s.o + (1 - k[0]) * anchor[0] * s.r + (1 - k[1]) * anchor[1] * s.up)
        changeLabel { _ in next }
    }

    func labelRelease() -> Bool {
        guard let d = labelState.drag else { return false }
        labelState.drag = nil
        labelState.planeGuides = []
        if !labelState.guides.isEmpty { labelState.guides = [] }
        if d.moved { flushLabel() }
        return true
    }

    /// The screen point of the upper right corner handle of label l, with
    /// its box k times as large about the lower left corner (a test).
    func labelCornerScreen(_ l: PartLabel, _ ol: LabelOutline, _ k: Double) -> CGPoint? {
        let g = labelHandles(l, ol)
        return labelScreen(l, g.box[0] + k * (g.box[2] - g.box[0]), g.box[1] + k * (g.box[3] - g.box[1]))
    }

    // MARK: - the smart guides

    /// The mm of the plane of label l in one point of the screen, at the
    /// center of its box.
    private func labelMMPerPoint(_ l: PartLabel, _ ol: LabelOutline) -> Double {
        let cx = (ol.box.x0 + ol.box.x1) / 2, cy = (ol.box.y0 + ol.box.y1) / 2
        guard let p0 = labelScreen(l, cx, cy), let pr = labelScreen(l, cx + 1, cy), let pu = labelScreen(l, cx, cy + 1) else { return 0.1 }
        let d = max(hypot(pr.x - p0.x, pr.y - p0.y), hypot(pu.x - p0.x, pu.y - p0.y))
        return d > 1e-6 ? 1 / d : 0.1
    }

    /// The handles of label l in its plane, sized in points of the screen
    /// (zg_label_handles): the frame (a gap of 4 points around the box),
    /// the half side of a corner square, and the center and the radius of
    /// the turn handle.
    private func labelHandles(_ l: PartLabel, _ ol: LabelOutline) -> (box: [Double], hs: Double, turn: (Double, Double), r: Double) {
        let mpp = labelMMPerPoint(l, ol)
        let gap = 4 * mpp
        let box = [ol.box.x0 - gap, ol.box.y0 - gap, ol.box.x1 + gap, ol.box.y1 + gap]
        return (box, 4.5 * mpp, ((box[0] + box[2]) / 2, box[3] + 22 * mpp), 5 * mpp)
    }

    /// The handle of the selected label at a point of the view, in its
    /// plane: the turn handle, or a corner (+1: the high side).
    private func labelHandleHit(_ p: CGPoint, _ l: PartLabel, _ ol: LabelOutline) -> (turn: Bool, corner: [Int])? {
        guard let r = labelRay(p) else { return nil }
        let (o, dir) = rayVectors(r)
        guard let h = l.planeHit(o, dir) else { return nil }
        let g = labelHandles(l, ol)
        // A hit area a little larger than the drawing.
        let m = 1.6
        if hypot(h.x - g.turn.0, h.y - g.turn.1) <= g.r * m { return (true, [1, 1]) }
        for sx in [-1, 1] {
            for sy in [-1, 1] {
                let cx = sx > 0 ? g.box[2] : g.box[0], cy = sy > 0 ? g.box[3] : g.box[1]
                if abs(h.x - cx) <= g.hs * m, abs(h.y - cy) <= g.hs * m { return (false, [sx, sy]) }
            }
        }
        return nil
    }

    private func frameJSON(_ l: PartLabel) -> [String: Any] {
        ["origin": l.origin, "normal": l.normal, "right": l.right]
    }

    /// The features of the face under label l (zs_label_face), kept while
    /// the label stays in its plane; on a curved face, read again at most
    /// each 150 ms.
    private func labelFace(_ l: PartLabel) -> String? {
        let st = labelState
        guard let s = labelSession(st.index) else { return nil }
        if let f = st.face, f.index == st.index {
            if dot(f.normal, l.n) >= cos(2.5 * .pi / 180), abs(dot(l.o - f.origin, l.n)) < 0.2 { return f.json }
            if Date().timeIntervalSince(f.time) < 0.15 { return nil }
        }
        var frame = l.origin + l.normal + l.right
        let json = coreString { buf, cap, len in zs_label_face(s, &frame, buf, cap, len) }
        let face = json == "null" ? nil : json
        if ProcessInfo.processInfo.environment["ZSLICE_LABEL_LOG"] != nil {
            NSLog("zslice label face: %@ for %@", String((json ?? "nil").prefix(200)), frame.map { String(format: "%.2f", $0) }.joined(separator: " "))
        }
        st.face = (face, st.index, l.o, l.n, Date())
        return face
    }

    /// The snap of a box of label l (zs_label_snap): the box after it, the
    /// move (along right and up), and the guides to draw.
    private func labelSnap(_ l: PartLabel, box: [Double], op: String, corner: [Int]?, aspect: Bool) -> (box: [Double], d: [Double])? {
        guard let ol = labelOutline(l) else { return nil }
        var j: [String: Any] = ["op": op, "frame": frameJSON(l), "box": box, "tol": 6 * labelMMPerPoint(l, ol)]
        j["others"] = labelState.labels.filter { $0.id != l.id }.compactMap { x -> [String: Any]? in
            guard let o = labelOutline(x) else { return nil }
            var f = frameJSON(x)
            f["box"] = [o.box.x0, o.box.y0, o.box.x1, o.box.y1]
            return f
        }
        if let face = labelFace(l), let fo = try? JSONSerialization.jsonObject(with: Data(face.utf8)) { j["face"] = fo } else { j["face"] = NSNull() }
        if let corner {
            j["corner"] = corner
            j["aspect"] = aspect
        }
        guard let data = try? JSONSerialization.data(withJSONObject: j), let text = String(data: data, encoding: .utf8),
              let out = coreString({ buf, cap, len in zs_label_snap(text, strlen(text), buf, cap, len) }),
              let o = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
              let b = o["box"] as? [Double], b.count == 4 else { return nil }
        let d = o["d"] as? [Double] ?? [0, 0]
        if ProcessInfo.processInfo.environment["ZSLICE_LABEL_LOG"] != nil {
            NSLog("zslice label snap: face %@, in %@, out %@", j["face"] is NSNull ? "none" : "yes", String(text.prefix(300)), out)
        }
        labelState.planeGuides = (o["guides"] as? [[Double]] ?? []).filter { $0.count == 4 }
        return (b, d.count == 2 ? d : [0, 0])
    }

    /// The guides of the snap on the screen, in the plane of the selected
    /// label.
    private func showGuides() {
        let st = labelState
        guard let l = st.label, !st.planeGuides.isEmpty else {
            if !st.guides.isEmpty { st.guides = [] }
            return
        }
        st.guides = st.planeGuides.compactMap { g in
            guard let a = labelScreen(l, g[0], g[1]), let b = labelScreen(l, g[2], g[3]) else { return nil }
            return (a, b)
        }
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

    /// After each frame: the handles of the selected label on the screen
    /// (the frame, the corner squares, and the turn handle, in its plane),
    /// and its box on the screen (for the card).
    func placeLabelHandle() {
        let st = labelState
        guard tool == .label, page == .threeD, let l = st.label, let ol = labelOutline(l) else {
            if !st.frame.isEmpty { st.frame = [] }
            if !st.corners.isEmpty { st.corners = [] }
            if !st.turnRing.isEmpty { st.turnRing = [] }
            if st.turnAt != nil { st.turnAt = nil }
            if st.box != nil { st.box = nil }
            return
        }
        let g = labelHandles(l, ol)
        func quad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [CGPoint] {
            [(x0, y0), (x1, y0), (x1, y1), (x0, y1)].compactMap { labelScreen(l, $0.0, $0.1) }
        }
        let frame = quad(g.box[0], g.box[1], g.box[2], g.box[3])
        var corners: [[CGPoint]] = []
        for (cx, cy) in [(g.box[0], g.box[1]), (g.box[2], g.box[1]), (g.box[2], g.box[3]), (g.box[0], g.box[3])] {
            corners.append(quad(cx - g.hs, cy - g.hs, cx + g.hs, cy + g.hs))
        }
        let ring = (0 ..< 24).compactMap { k -> CGPoint? in
            let a = Double(k) / 24 * 2 * .pi
            return labelScreen(l, g.turn.0 + g.r * cos(a), g.turn.1 + g.r * sin(a))
        }
        func far(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
            a.count != b.count || zip(a, b).contains { hypot($0.x - $1.x, $0.y - $1.y) > 0.5 }
        }
        if far(frame, st.frame) { st.frame = frame }
        if far(corners.flatMap { $0 }, st.corners.flatMap { $0 }) { st.corners = corners }
        if far(ring, st.turnRing) { st.turnRing = ring }
        let t = labelScreen(l, g.turn.0, g.turn.1)
        if far(t.map { [$0] } ?? [], st.turnAt.map { [$0] } ?? []) { st.turnAt = t }
        if st.drag != nil { showGuides() }
        var pts: [CGPoint] = []
        for x in [ol.box.x0 - 1, ol.box.x1 + 1] { for y in [ol.box.y0 - 1, ol.box.y1 + 1] { if let q = labelScreen(l, x, y) { pts.append(q) } } }
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return }
        let gap: CGFloat = 12
        let b = CGRect(x: x0 - gap, y: y0 - gap, width: x1 - x0 + 2 * gap, height: y1 - y0 + 2 * gap)
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
}

private extension LabelState {
    func items(_ i: Int) -> LabelItem? {
        guard let l = label, l.items.indices.contains(i) else { return nil }
        return l.items[i]
    }
}
