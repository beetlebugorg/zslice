//! The Paint tool (P, web/app/paint.js): it paints filaments on the
//! surface of a part, for a print with more than one filament.
//!
//! The tool shows the mesh of the part (zs_app_part_mesh) in place of the
//! beads, each triangle in the color of its filament (PaintMesh, a pass
//! of FrameRenderer). The core keeps a paint session of the mesh
//! (zs_paint_*): the regions, the hits, the fills, and the brush. Two
//! modes:
//!
//! - Smart select: the region under the pointer lights before the click,
//!   and a click paints it with the filament of the card. A region is a
//!   part of the mesh that stands out of its surface or sinks into it (a
//!   raised letter: its top and its sides), else a flat or smooth face.
//!   Shift and a click add a region to the selection; a chip of another
//!   filament then paints all of it.
//! - Brush: a left drag paints a sphere of the brush size along the
//!   pointer. The triangles on the edge of the sphere split, so the border
//!   is clean.
//!
//! A right drag turns the view, and Shift with a drag pans, as in the
//! other tools. Each hover and each step of the brush runs on the main
//! thread with the session, with no wait. The end of a click or a stroke
//! gives the paint to the part (zs_app_part_paint_set), and the plate
//! slices again. The beads come back when the tool closes.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice
import Observation
import simd
import SwiftUI

/// A region of the smart select: its id and its triangles.
struct PaintRegion {
    var id: UInt32
    var tris: [UInt32]
}

@MainActor
@Observable
final class PaintSession {
    enum Mode { case smart, brush }

    /// The part, and its own filament (from 1): state 0 paints with it.
    let index: Int
    let base: Int
    var mode = Mode.smart
    /// The radius of the brush, mm.
    var size = 2.0
    /// The filament to paint with (from 1).
    var filament = 2

    @ObservationIgnored let session: OpaquePointer
    @ObservationIgnored let triangles: Int
    @ObservationIgnored let mesh: PaintMesh
    @ObservationIgnored var hover: PaintRegion?
    @ObservationIgnored var selection: [PaintRegion] = []
    /// The triangles that the brush stroke changed, or nil with no stroke.
    @ObservationIgnored var stroke: Int?

    init(index: Int, base: Int, session: OpaquePointer, triangles: Int, mesh: PaintMesh) {
        self.index = index
        self.base = base
        self.session = session
        self.triangles = triangles
        self.mesh = mesh
    }

    /// The state of a filament: the filament of the part is 0.
    func state(of n: Int) -> UInt8 { n == base ? 0 : UInt8(min(max(n, 0), 127)) }
}

extension Workspace {
    /// The part that the tool paints: the selected part, or the only one.
    private var paintPart: Int? {
        if let i = selectedPart { return i }
        return zs_app_part_count(model.core) >= 1 ? 0 : nil
    }

    /// Opens the tool on the part. False when there is no part to paint.
    @discardableResult
    func openPaint() -> Bool {
        guard paint == nil, page == .threeD, let i = paintPart else {
            if paint == nil { showNote("Open a model to paint it.") }
            return false
        }
        var vp: UnsafePointer<Float>?
        var fp: UnsafePointer<UInt32>?
        var nv = 0, nf = 0
        guard zs_app_part_mesh(model.core, i, &vp, &nv, &fp, &nf) == 0, let vp, let fp, nf > 0 else {
            showNote("The part has no mesh.")
            return false
        }
        var s: OpaquePointer?
        guard zs_paint_new(vp, nv, fp, nf, &s) == 0, let s else {
            showNote("The paint tool cannot open this part.")
            return false
        }
        // The paint that the part has.
        if let text = coreString({ zs_app_part_paint_get(model.core, i, $0, $1, $2) }), !text.isEmpty {
            _ = text.withCString { zs_paint_set_text(s, $0, strlen($0)) }
        }
        // The mesh for the GPU: the points of each triangle and its normal.
        var posnorm = [Float](repeating: 0, count: 18 * nf)
        for t in 0 ..< nf {
            let a = Int(fp[3 * t]) * 3, b = Int(fp[3 * t + 1]) * 3, c = Int(fp[3 * t + 2]) * 3
            let pa = SIMD3(vp[a], vp[a + 1], vp[a + 2]), pb = SIMD3(vp[b], vp[b + 1], vp[b + 2]), pc = SIMD3(vp[c], vp[c + 1], vp[c + 2])
            var n = simd_cross(pb - pa, pc - pa)
            let len = simd_length(n)
            n = len > 0 ? n / len : SIMD3(0, 0, 1)
            for (k, p) in [pa, pb, pc].enumerated() {
                let o = 18 * t + 6 * k
                posnorm[o] = p.x; posnorm[o + 1] = p.y; posnorm[o + 2] = p.z
                posnorm[o + 3] = n.x; posnorm[o + 4] = n.y; posnorm[o + 5] = n.z
            }
        }
        guard let mesh = canvas.makePaintMesh(posnorm: posnorm) else {
            zs_paint_free(s)
            return false
        }
        let own = coreString { zs_app_part_setting_get(model.core, i, "project.filament", $0, $1, $2) }
        let base = max(Int(Double(own ?? model.entry("project.filament").value) ?? 1), 1)
        let p = PaintSession(index: i, base: base, session: s, triangles: nf, mesh: mesh)
        // Paint with another filament than the part's at first.
        p.filament = model.filaments.count > 1 ? (base == 1 ? 2 : 1) : 1
        paint = p
        clearSelection()
        paintColors()
        paintUpload()
        canvas.paintMesh = mesh
        return true
    }

    func closePaint() {
        guard let p = paint else { return }
        canvas.paintMesh = nil
        zs_paint_free(p.session)
        paint = nil
    }

    /// The palette of the shader: 0 the filament of the part, k filament k.
    func paintColors() {
        guard let p = paint else { return }
        let list = model.filaments
        func rgb(_ hex: String) -> SIMD4<Float> {
            guard let c = NSColor(Color(hex: hex) ?? .gray).usingColorSpace(.sRGB) else { return SIMD4(0.82, 0.82, 0.8, 1) }
            return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
        }
        let first = list.first?.color ?? "#d0d0cc"
        var cols = [rgb(list[safe: p.base - 1]?.color ?? first)]
        for k in 1 ... 17 { cols.append(rgb(list[safe: k - 1]?.color ?? first)) }
        p.mesh.colors = cols
        canvas.requestFrame()
    }

    /// The states of the triangles to the GPU, with the light of the region
    /// under the pointer and of the selection, and the pieces of the split
    /// triangles.
    func paintUpload() {
        guard let p = paint else { return }
        var sp: UnsafePointer<UInt8>?
        let n = zs_paint_states(p.session, &sp)
        var vs = [Float](repeating: 0, count: 3 * n)
        if let sp {
            for t in 0 ..< n {
                let s = Float(sp[t])
                vs[3 * t] = s; vs[3 * t + 1] = s; vs[3 * t + 2] = s
            }
        }
        func lit(_ tris: [UInt32]) {
            for t in tris.map(Int.init) where 3 * t + 2 < vs.count && vs[3 * t] != 255 && vs[3 * t] < 128 {
                let s = vs[3 * t] + 128
                vs[3 * t] = s; vs[3 * t + 1] = s; vs[3 * t + 2] = s
            }
        }
        // The region under the pointer lights only in the smart select.
        if p.mode == .smart, let h = p.hover { lit(h.tris) }
        for r in p.selection { lit(r.tris) }
        p.mesh.setStates(vs)
        var lp: UnsafePointer<Float>?
        let nl = zs_paint_leaves(p.session, &lp)
        var pos = [Float](repeating: 0, count: 18 * nl)
        var st = [Float](repeating: 0, count: 3 * nl)
        if let lp {
            for i in 0 ..< nl {
                let q = lp + 10 * i
                let a = SIMD3(q[0], q[1], q[2]), b = SIMD3(q[3], q[4], q[5]), c = SIMD3(q[6], q[7], q[8])
                var nrm = simd_cross(b - a, c - a)
                let len = simd_length(nrm)
                nrm = len > 0 ? nrm / len : SIMD3(0, 0, 1)
                for (k, v) in [a, b, c].enumerated() {
                    let o = 18 * i + 6 * k
                    pos[o] = v.x; pos[o + 1] = v.y; pos[o + 2] = v.z
                    pos[o + 3] = nrm.x; pos[o + 4] = nrm.y; pos[o + 5] = nrm.z
                    st[3 * i + k] = q[9]
                }
            }
        }
        p.mesh.setLeaves(posnorm: pos, states: st)
        canvas.requestFrame()
    }

    /// The triangle under a point of the view, and the point of the
    /// surface there (mm), or nil.
    func paintHit(_ pt: CGPoint) -> (tri: UInt32, point: SIMD3<Float>)? {
        guard let p = paint, let v = canvas.view else { return nil }
        let s = Float(canvas.window?.backingScaleFactor ?? 2)
        var ray = [Float](repeating: 0, count: 6)
        guard zs_view_ray(v, Float(pt.x) * s, Float(pt.y) * s, &ray) != 0 else { return nil }
        var tri: UInt32 = 0
        var t: Float = 0
        guard zs_paint_hit(p.session, ray, &tri, &t) == 1 else { return nil }
        return (tri, SIMD3(ray[0] + ray[3] * t, ray[1] + ray[4] * t, ray[2] + ray[5] * t))
    }

    /// The region of the smart select of a triangle. A region with the id
    /// of `same` gives that one back with no copy.
    func paintRegion(_ tri: UInt32, same: PaintRegion? = nil) -> PaintRegion? {
        guard let p = paint else { return nil }
        var list: UnsafePointer<UInt32>?
        var n = 0
        var id: UInt32 = 0
        guard zs_paint_region(p.session, tri, &list, &n, &id) == 0 else { return nil }
        if let same, same.id == id { return same }
        return PaintRegion(id: id, tris: list.map { Array(UnsafeBufferPointer(start: $0, count: n)) } ?? [])
    }

    @discardableResult
    func paintFill(_ tris: [UInt32], _ state: UInt8) -> Int {
        guard let p = paint, !tris.isEmpty else { return 0 }
        return Int(zs_paint_fill(p.session, tris, tris.count, state))
    }

    /// The paint to the part: the plate slices again.
    func paintCommit() {
        guard let p = paint else { return }
        var text: UnsafePointer<CChar>?
        var len = 0
        guard zs_paint_text(p.session, &text, &len) == 0, let text else { return }
        guard zs_app_part_paint_set(model.core, p.index, text, len) == 0 else {
            showNote("The paint did not go to the part.")
            return
        }
        model.settingsChanged()
    }

    /// A new filament to paint with: the selection takes it.
    func paintWith(_ n: Int) {
        guard let p = paint else { return }
        p.filament = n
        var changed = 0
        for r in p.selection { changed += paintFill(r.tris, p.state(of: n)) }
        if changed > 0 { paintCommit() }
        paintUpload()
    }

    /// Remove All Paint: the whole part prints with its own filament.
    func paintClear() {
        guard let p = paint else { return }
        if paintFill((0 ..< UInt32(p.triangles)).map { $0 }, 0) > 0 { paintCommit() }
        p.selection = []
        paintUpload()
    }

    // MARK: - the pointer

    /// A press of the left button with the tool on: true if it used it.
    func paintPress(_ pt: CGPoint, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard let p = paint else { return false }
        let h = paintHit(pt)
        if p.mode == .smart {
            guard let h, let r = paintRegion(h.tri) else {
                if !flags.contains(.shift) { p.selection = [] }
                paintUpload()
                return true
            }
            if flags.contains(.shift) {
                if !p.selection.contains(where: { $0.id == r.id }) { p.selection.append(r) }
            } else {
                p.selection = [r]
            }
            if paintFill(r.tris, p.state(of: p.filament)) > 0 { paintCommit() }
            paintUpload()
            return true
        }
        p.stroke = 0
        if let h { paintDab(h.point) }
        return true
    }

    func paintDrag(_ pt: CGPoint) {
        guard let p = paint, p.stroke != nil, let h = paintHit(pt) else { return }
        paintDab(h.point)
    }

    func paintRelease() {
        guard let p = paint, let n = p.stroke else { return }
        p.stroke = nil
        if n > 0 { paintCommit() }
    }

    /// The region under the pointer lights (the smart select).
    func paintHover(_ pt: CGPoint?) {
        guard let p = paint, p.mode == .smart else { return }
        let r = pt.flatMap { paintHit($0) }.flatMap { paintRegion($0.tri, same: p.hover) }
        if r?.id == p.hover?.id, (r == nil) == (p.hover == nil) { return }
        p.hover = r
        paintUpload()
    }

    /// One step of the brush at a point of the surface.
    private func paintDab(_ q: SIMD3<Float>) {
        guard let p = paint else { return }
        let n = zs_paint_brush(p.session, q.x, q.y, q.z, Float(p.size), p.state(of: p.filament), max(0.1, Float(p.size) / 6))
        if n > 0 {
            p.stroke = (p.stroke ?? 0) + Int(n)
            paintUpload()
        }
    }
}
