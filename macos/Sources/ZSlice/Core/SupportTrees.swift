//! The support trees in the Support tool (web/app/support.js, and
//! linux/src/ui/support-tool.c): with tree support, the nodes of the trees
//! of each part show as dots.
//!
//! - A click on a dot or a segment selects its branch.
//! - A drag of a dot moves the node. A drag of the ring of the selected
//!   node makes it wider or narrower. A drag of a segment moves the branch.
//! - Delete removes the branch. "Add a Branch" plans one from a click on
//!   the bed (the foot) to a click on the part. "Reset Support" plans the
//!   trees of the part again.
//!
//! The core keeps the trees of the user (zs_app_support_tree_*), and keeps
//! each edit within the rules of the planner. An edit that a rule limited
//! shows red, with the rule in the card. During a drag the nodes follow the
//! pointer at once. The core gets the edit at most each 60 ms, and the
//! plate slices at most each 150 ms, so the support follows the drag. The
//! step of the history stays open until the release: one drag is one step.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// The trees of a part: their nodes, and whether the user edited them.
struct SupportTree {
    var nodes: [zs_tree_node]
    var edited: Bool
}

/// A drag of a tree element: a dot, the ring of the selected node, or a
/// segment (the branch).
struct TreeDrag {
    enum Kind { case node, ring, segment }
    var kind: Kind
    var part: Int
    var node: UInt32
    /// The height of the plane of the drag, and its start point on it.
    var z: Double
    var start: SIMD2<Double>
    /// The nodes that move, and their places at the start.
    var branch: [UInt32]
    var orig: [SIMD2<Double>]
    /// The move that the core applied (a branch), and what the pointer wants.
    var applied = SIMD2<Double>(0, 0)
    var want = SIMD2<Double>(0, 0)
    var wantR = 0.0
    var moved = false
    var dirty = false
    var sent = 0.0
    var sliced = 0.0
}

extension Workspace {
    /// The clamp bits (enum zs_tree_clamp), in words.
    private static let clampText: [(UInt32, String)] = [
        (UInt32(ZS_TREE_CLAMP_PART.rawValue), "it stays out of the part"),
        (UInt32(ZS_TREE_CLAMP_LEAN.rawValue), "a segment leans at most the tree angle"),
        (UInt32(ZS_TREE_CLAMP_RADIUS_MIN.rawValue), "the rules need this width"),
        (UInt32(ZS_TREE_CLAMP_RADIUS_MAX.rawValue), "this is the largest width"),
        (UInt32(ZS_TREE_CLAMP_REACH.rawValue), "the foot moved nearer, so the branch can reach the tip"),
    ]

    /// The flags of zs_view_support_add: a closed outline, selected, as
    /// points, and with no fill.
    private static let closed: Int32 = 1, selected: Int32 = 2, points: Int32 = 4, bare: Int32 = 8
    /// The kind of the view for a tree that a rule limited: red.
    private static let red = Int32(ZS_MARK_BLOCK.rawValue)
    private static let treeKind = Int32(ZS_MARK_TREE.rawValue)
    /// The least distance on the screen between two dots that the view
    /// draws (points): more dots add no help.
    private static let dotCell: CGFloat = 7
    /// The distance from a dot that still hits it (points).
    private static let near: CGFloat = 10

    private var scale: CGFloat { canvas.window?.backingScaleFactor ?? 2 }

    func node(_ part: Int, _ i: UInt32) -> zs_tree_node? {
        guard let t = supportTrees[part], Int(i) < t.nodes.count else { return nil }
        return t.nodes[Int(i)]
    }

    /// The selected node, if it is still there.
    var treeSelection: (part: Int, node: zs_tree_node, index: UInt32)? {
        guard let s = treeSelected, let n = node(s.part, s.node) else { return nil }
        return (s.part, n, s.node)
    }

    // MARK: - read

    /// The trees of part `part` from the core. While a slice runs, the core
    /// has none to give: the last ones stay.
    private func readTree(_ part: Int) {
        let core = model.core
        let n = zs_app_support_tree_nodes(core, part, nil, 0)
        if n < 0 { return }
        if n == 0 {
            supportTrees[part] = nil
            return
        }
        var nodes = [zs_tree_node](repeating: zs_tree_node(), count: n)
        let got = zs_app_support_tree_nodes(core, part, &nodes, n)
        if got < 0 { return }
        nodes.removeLast(max(0, n - got))
        supportTrees[part] = SupportTree(nodes: nodes, edited: zs_app_support_tree_edited(core, part) == 1)
    }

    /// The trees of each part, after a slice or an undo. Only while the
    /// tool is on: the trees cost a little to read.
    func readSupportTrees() {
        guard treeDrag == nil else { return }
        guard tool == .support else {
            if !supportTrees.isEmpty { supportTrees = [:] }
            treeSelected = nil
            treeAdding = false
            return
        }
        let parts = zs_app_part_count(model.core)
        for p in supportTrees.keys where p >= parts { supportTrees[p] = nil }
        for p in 0 ..< parts { readTree(p) }
        var buf = [CChar](repeating: 0, count: 512)
        if zs_app_support_tree_note(model.core, &buf, buf.count) > 0 {
            treeNote = buf.withUnsafeBufferPointer { coreText($0.baseAddress) }
        }
        if treeSelection == nil { treeSelected = nil }
    }

    /// The nodes of the branch of node i.
    func branch(_ part: Int, _ i: UInt32) -> [UInt32] {
        guard let t = supportTrees[part], let nd = node(part, i) else { return [] }
        return t.nodes.indices.filter { t.nodes[$0].branch == nd.branch }.map { UInt32($0) }
    }

    // MARK: - show

    /// The points of the ring of a node: on its circle, at its z.
    private func ring(_ nd: zs_tree_node, _ count: Int) -> [Double] {
        (0 ..< count).flatMap { k -> [Double] in
            let a = 2 * Double.pi * Double(k) / Double(count)
            return [nd.x + nd.r * cos(a), nd.y + nd.r * sin(a), nd.z]
        }
    }

    /// The trees to the core view: a dot for each node (one dot for nodes
    /// closer than dotCell on the screen), the segments of the selected
    /// branch and into it, the ring of the selected node, and the foot of a
    /// new branch. showSupport calls it after the areas.
    func showSupportTrees(_ v: OpaquePointer) {
        guard tool == .support else { return }
        let kind = treeClamp != 0 ? Self.red : Self.treeKind
        func dots(_ pts: [Double], _ kind: Int32, _ flags: Int32) {
            // At most 256 to a call of the view.
            var i = 0
            while i < pts.count / 3 {
                let n = min(256, pts.count / 3 - i)
                var chunk = Array(pts[(3 * i) ..< (3 * (i + n))])
                zs_view_support_add(v, &chunk, n, kind, Self.bare | Self.points | flags)
                i += n
            }
        }
        var inBranch = Set<UInt32>()
        if let s = treeSelection, let t = supportTrees[s.part] {
            inBranch = Set(branch(s.part, s.index))
            for (k, nd) in t.nodes.enumerated() {
                guard nd.down >= 0, Int(nd.down) < t.nodes.count else { continue }
                let inb = inBranch.contains(UInt32(k))
                guard inb || inBranch.contains(UInt32(nd.down)) else { continue }
                let dn = t.nodes[Int(nd.down)]
                var seg = [nd.x, nd.y, nd.z, dn.x, dn.y, dn.z]
                zs_view_support_add(v, &seg, 2, kind, Self.bare | (inb ? Self.selected : 0))
            }
            dots(inBranch.filter { $0 != s.index }.flatMap { k -> [Double] in
                let q = t.nodes[Int(k)]
                return [q.x, q.y, q.z]
            }, kind, 0)
            var c = [s.node.x, s.node.y, s.node.z]
            zs_view_support_add(v, &c, 1, kind, Self.bare | Self.points | Self.selected)
            var r = ring(s.node, 24)
            zs_view_support_add(v, &r, 24, kind, Self.bare | Self.closed | Self.selected)
        }
        var seen = Set<Int64>()
        var pts: [Double] = []
        for (part, t) in supportTrees {
            for (k, nd) in t.nodes.enumerated() {
                if part == treeSelected?.part, inBranch.contains(UInt32(k)) { continue }
                guard let q = canvas.viewPoint(x: nd.x, y: nd.y, z: nd.z) else { continue }
                let key = Int64(floor(q.x / Self.dotCell)) * 65536 + Int64(floor(q.y / Self.dotCell))
                guard seen.insert(key).inserted else { continue }
                pts += [nd.x, nd.y, nd.z]
            }
        }
        dots(pts, Self.treeKind, 0)
        if treeAdding, let f = treeFoot {
            var p = [f.x, f.y, 0]
            zs_view_support_add(v, &p, 1, Self.treeKind, Self.bare | Self.points | Self.selected)
        }
    }

    // MARK: - picks

    private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    private func pixel(_ nd: zs_tree_node) -> CGPoint? { canvas.viewPoint(x: nd.x, y: nd.y, z: nd.z) }

    /// The tree element under p: the ring of the selected node first, then
    /// the dots, then the segments (node to its down node).
    private func treeElement(at p: CGPoint) -> (TreeDrag.Kind, Int, UInt32)? {
        guard !supportTrees.isEmpty else { return nil }
        // The ring of a thin node is near its dot: the dot wins near its
        // center.
        if let s = treeSelection, !(pixel(s.node).map { hypot($0.x - p.x, $0.y - p.y) < Self.near * 0.5 } ?? false) {
            let r = ring(s.node, 16)
            for k in 0 ..< 16 {
                let j = (k + 1) % 16
                guard let a = canvas.viewPoint(x: r[3 * k], y: r[3 * k + 1], z: r[3 * k + 2]),
                      let b = canvas.viewPoint(x: r[3 * j], y: r[3 * j + 1], z: r[3 * j + 2]) else { continue }
                if segmentDistance(p, a, b) < Self.near * 0.7 { return (.ring, s.part, s.index) }
            }
        }
        var best: (TreeDrag.Kind, Int, UInt32)?
        var bestD = Self.near
        for (part, t) in supportTrees {
            for (k, nd) in t.nodes.enumerated() {
                guard let q = pixel(nd) else { continue }
                let d = hypot(q.x - p.x, q.y - p.y)
                if d < bestD {
                    bestD = d
                    best = (.node, part, UInt32(k))
                }
            }
        }
        if best != nil { return best }
        bestD = Self.near * 0.7
        for (part, t) in supportTrees {
            for (k, nd) in t.nodes.enumerated() {
                guard nd.down >= 0, Int(nd.down) < t.nodes.count,
                      let a = pixel(nd), let b = pixel(t.nodes[Int(nd.down)]) else { continue }
                let d = segmentDistance(p, a, b)
                if d < bestD {
                    bestD = d
                    best = (.segment, part, UInt32(k))
                }
            }
        }
        return best
    }

    /// The point of the level plane at height z under p.
    private func planePoint(_ p: CGPoint, z: Double) -> SIMD2<Double>? {
        guard let v = canvas.view else { return nil }
        var x = 0.0, y = 0.0
        guard zs_view_plane_point(v, Float(p.x * scale), Float(p.y * scale), z, &x, &y) != 0 else { return nil }
        return SIMD2(x, y)
    }

    // MARK: - the edits

    /// The result of an edit of the core: the trees of the part again, the
    /// clamp bits, a slice, and one step of the history (at the end of a
    /// drag). done: the core made the edit.
    private func treeDone(_ part: Int, done: Bool, rc: Int, clamp: UInt32) {
        treeClamp = clamp
        treeNote = nil
        if !done {
            showNote(rc == -Int(ZS_BUSY.rawValue) || rc == Int(ZS_BUSY.rawValue)
                ? "Slice first: the edits of the trees need a slice." : "The trees cannot change like that.")
        }
        readTree(part)
        if treeSelection == nil { treeSelected = nil }
        guard done else { return }
        model.history.commit()
        model.history.attach()
        model.settingsGeneration += 1
        model.requestSlice()
        // A part can lose what held it.
        checkPendingFall()
    }

    @discardableResult
    func deleteTreeBranch() -> Bool {
        guard let s = treeSelection else { return false }
        treeSelected = nil
        let n = zs_app_support_tree_delete_branch(model.core, s.part, s.index)
        treeDone(s.part, done: n >= 0, rc: n, clamp: 0)
        showSupport()
        return true
    }

    /// The part for Reset Support: the part of the selection, else the one
    /// part with edits.
    var treeResetPart: Int? {
        if let s = treeSelection { return supportTrees[s.part]?.edited == true ? s.part : nil }
        let edited = supportTrees.filter { $0.value.edited }.map(\.key)
        return edited.count == 1 ? edited[0] : nil
    }

    func resetTrees() {
        guard let part = treeResetPart else { return }
        treeSelected = nil
        _ = zs_app_support_tree_reset(model.core, part)
        treeDone(part, done: true, rc: 0, clamp: 0)
        showSupport()
    }

    func setTreeAdding(_ on: Bool) {
        treeAdding = on
        treeFoot = nil
        treeSelected = nil
        supportHover = nil
        showSupport()
    }

    /// "Add a Branch": a click on the bed (the foot), then a click on the
    /// part. True if the click was for it.
    func treeAddClick(_ p: CGPoint) -> Bool {
        guard treeAdding, let v = canvas.view else { return false }
        guard let f = treeFoot else {
            var x = 0.0, y = 0.0
            if zs_view_bed_point(v, Float(p.x * scale), Float(p.y * scale), &x, &y) != 0 {
                treeFoot = SIMD2(x, y)
                showSupport()
            }
            return true
        }
        var t = [Double](repeating: 0, count: 3)
        let noRoom = "No room for a branch there: click under an overhang, higher than the bed."
        guard zs_view_surface_point(v, Float(p.x * scale), Float(p.y * scale), 0, &t) != 0 else {
            showNote("Click the place on the part that needs support.")
            return true
        }
        treeAdding = false
        treeFoot = nil
        let part = zs_app_part_at(model.core, t[0], t[1])
        guard part >= 0 else {
            showNote(noRoom)
            showSupport()
            return true
        }
        var clamp: UInt32 = 0
        let tip = zs_app_support_tree_add_branch(model.core, part, f.x, f.y, t[0], t[1], t[2], &clamp)
        treeDone(part, done: tip >= 0, rc: tip, clamp: clamp)
        if tip >= 0 {
            treeSelected = (part, UInt32(tip))
        } else {
            showNote(noRoom)
        }
        showSupport()
        return true
    }

    // MARK: - drag a node, a ring, or a branch

    /// A press on a tree element selects its branch and starts a drag.
    func treePress(_ p: CGPoint) -> Bool {
        guard !treeAdding, let (kind, part, i) = treeElement(at: p), let nd = node(part, i) else { return false }
        // A segment: the branch moves with the point of the plane at the
        // height of the middle of the segment.
        var z = nd.z
        if kind == .segment, nd.down >= 0, let dn = node(part, UInt32(nd.down)) { z = (nd.z + dn.z) / 2 }
        guard let start = planePoint(p, z: z) else { return false }
        let moving = kind == .segment ? branch(part, i) : [i]
        let orig = moving.compactMap { node(part, $0).map { SIMD2($0.x, $0.y) } }
        treeDrag = TreeDrag(kind: kind, part: part, node: i, z: z, start: start, branch: moving, orig: orig)
        treeSelected = (part, i)
        supportSelected = nil
        supportHover = nil
        showSupport()
        return true
    }

    func treeDragged(_ p: CGPoint) {
        guard var d = treeDrag, let q = planePoint(p, z: d.z) else { return }
        d.moved = true
        if d.kind == .ring {
            guard let nd = node(d.part, d.node) else { return }
            d.wantR = max(0.05, hypot(q.x - nd.x, q.y - nd.y))
        } else {
            d.want = q - d.start
        }
        d.dirty = true
        treeDrag = d
        // The core gets the edit at most each 60 ms.
        if CACurrentMediaTime() - d.sent >= 0.06 {
            treeSend()
        } else if treeTimer == nil {
            treeTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, !Task.isCancelled else { return }
                treeTimer = nil
                if treeDrag?.dirty == true {
                    treeSend()
                    showSupport()
                }
            }
        }
        treePreview()
        showSupport()
    }

    /// The local preview of the drag: the nodes follow the pointer at once;
    /// the core clamps them when it gets the edit.
    private func treePreview() {
        guard let d = treeDrag, var t = supportTrees[d.part] else { return }
        if d.kind == .ring {
            if Int(d.node) < t.nodes.count { t.nodes[Int(d.node)].r = d.wantR }
        } else {
            for (k, i) in d.branch.enumerated() where Int(i) < t.nodes.count {
                t.nodes[Int(i)].x = d.orig[k].x + d.want.x
                t.nodes[Int(i)].y = d.orig[k].y + d.want.y
            }
        }
        supportTrees[d.part] = t
    }

    /// The edit of the drag now, to the core. While the plate slices, the
    /// core has no trees to edit (ZS_BUSY): the edit stays dirty and goes
    /// with the next move or the release.
    @discardableResult
    private func treeSend() -> Bool {
        guard var d = treeDrag else { return false }
        let core = model.core
        var clamp: UInt32 = 0
        let rc: Int32
        switch d.kind {
        case .ring:
            rc = zs_app_support_tree_set_radius(core, d.part, d.node, d.wantR, &clamp)
        case .node:
            rc = zs_app_support_tree_move_node(core, d.part, d.node, d.orig[0].x + d.want.x, d.orig[0].y + d.want.y, &clamp)
        case .segment:
            // A branch: the core moves it from where it is now.
            rc = zs_app_support_tree_move_branch(core, d.part, d.node, d.want.x - d.applied.x, d.want.y - d.applied.y, &clamp)
        }
        let now = CACurrentMediaTime()
        d.sent = now
        if rc == 0 {
            d.dirty = false
            treeClamp = clamp
            readTree(d.part)
            if d.kind == .segment, let first = d.branch.first, let q = node(d.part, first) {
                d.applied = SIMD2(q.x, q.y) - d.orig[0]
            }
            model.changedHeld()
            // The support follows the drag: a slice at most each 150 ms,
            // with the step of the history still open.
            if now - d.sliced >= 0.15 {
                d.sliced = now
                model.sliceHeldNow()
            }
        }
        treeDrag = d
        if ProcessInfo.processInfo.environment["ZSLICE_TREE_TEST"] != nil {
            NSLog("zslice tree: send rc %d, clamp %u, at %.0f ms", rc, clamp, (now - launchTime) * 1000)
        }
        return rc == 0
    }

    /// The end of the drag: the last edit, then the slice that waited
    /// starts, the step of the history ends, and the fall check runs.
    func treeReleased() {
        guard let d = treeDrag else { return }
        treeTimer?.cancel()
        treeTimer = nil
        if d.moved, d.dirty { treeSend() }
        treeDrag = nil
        if d.moved {
            model.changedHeld()
            model.release()
            model.history.commit()
            model.history.attach()
            checkPendingFall()
        }
        readSupportTrees()
        showSupport()
    }

    // MARK: - the card

    /// The text of the card about the trees.
    var treeInfo: String {
        var text = treeNote.map { $0 + " " } ?? ""
        if treeAdding {
            text += treeFoot == nil ? "Click a spot on the bed for the foot of the branch. Esc stops."
                : "Now click the place on the part that needs support. Esc stops."
        } else if let s = treeSelection {
            text += String(format: "%.1f mm wide (at least %.1f), z %.1f mm. ", 2 * s.node.r, 2 * s.node.r_min, s.node.z)
            text += "Drag the dot, the ring, or the branch; Delete removes it."
        } else {
            text += "Click a tree to edit it."
        }
        return text
    }

    /// The rules that limited the last edit, in words, or nil.
    var treeLimit: String? {
        guard treeClamp != 0 else { return nil }
        return "Limited: " + Self.clampText.filter { treeClamp & $0.0 != 0 }.map(\.1).joined(separator: "; ") + "."
    }

    // MARK: - the test hook

    /// ZSLICE_TREE_TEST=1: tree support, the Support tool, then a drag of
    /// the segment of the middle node of the first tree by 60 points to
    /// the right in 1 s. The log gives the sends, the slices during the
    /// drag, the history before and after, and the node.
    func runTreeTest() {
        zs_app_setting_set(model.core, "project.support", "everywhere")
        zs_app_setting_set(model.core, "project.support_style", "tree")
        model.settingsChanged()
        Task { @MainActor in
            while model.state != .done { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            setTool(.support)
            readSupportTrees()
            guard let (part, t) = supportTrees.min(by: { $0.key < $1.key }), !t.nodes.isEmpty else {
                NSLog("zslice tree: no trees")
                return
            }
            // A node with a down node, in the middle of the list.
            let k = t.nodes.indices.filter { t.nodes[$0].down >= 0 }.dropFirst(t.nodes.count / 4).first ?? 0
            let nd = t.nodes[k], dn = t.nodes[Int(max(0, nd.down))]
            let mid = SIMD3((nd.x + dn.x) / 2, (nd.y + dn.y) / 2, (nd.z + dn.z) / 2)
            guard let p = canvas.viewPoint(x: mid.x, y: mid.y, z: mid.z) else { return }
            let steps0 = model.history.count
            var slices = 0
            let before = model.onSliced
            model.onSliced = {
                slices += 1
                before?()
            }
            let pressed = press(p, [])
            NSLog("zslice tree: %d trees, %d nodes in part %d, press %d (%@), history %d", supportTrees.count, t.nodes.count, part,
                  pressed ? 1 : 0, treeDrag.map { "\($0.kind)" } ?? "none", steps0)
            for s in 1 ... 20 {
                drag(CGPoint(x: p.x + Double(s) * 3, y: p.y), [])
                try? await Task.sleep(for: .milliseconds(50))
            }
            let during = slices
            release(CGPoint(x: p.x + 60, y: p.y))
            while model.state != .done { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(600))
            let q = node(part, UInt32(k))
            NSLog("zslice tree: slices during the drag %d, history %d -> %d, node x %.2f -> %.2f, edited %d, clamp %u",
                  during, steps0, model.history.count, nd.x, q?.x ?? -1, supportTrees[part]?.edited == true ? 1 : 0, treeClamp)
            model.onSliced = before
        }
    }
}
