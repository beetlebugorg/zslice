//! The support that the Select tool picked (web/app/support.js selectAt,
//! linux/src/ui/support-tool.c zg_support_select_at). A click on a support
//! line with the Select tool selects that support, with the code of the
//! Support tool and the tool off:
//!
//! - Tree support: the nodes of that tree show (the tree is all nodes with
//!   the same root, the node at the bottom of the chain of `down` links),
//!   and the node nearest to the click is selected. A drag of a dot, a
//!   ring, or a segment pulls it, as in the Support tool. A right click on
//!   a dot offers Delete Branch, and Delete removes the branch.
//! - Grid support: the overhang over the line shows (zs_app_support_pick,
//!   up from the line in steps of 0.5 mm), and Delete puts a Block area
//!   on it, with the support marks near the line.
//! - Make it: Grid, Tree, or Pad puts an area of that kind over the
//!   overhang, as the Support tool makes. The core keeps the support of
//!   the settings out of that area, so the area replaces it.
//!
//! Esc, a click on no support, or another tool ends the pick.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CZslice

/// A support that the Select tool picked.
struct SupportPick {
    /// The point of the click on the support line, mm.
    var point: SIMD3<Double>
    /// A tree: its nodes show; else the overhang of a grid support.
    var tree: Bool
    /// The overhang over the line: its points (x, y, z each) and z range.
    var overhang: (points: [Double], n: Int, lo: Double, hi: Double)?
    /// The nodes of the picked tree, by part.
    var only: (part: Int, nodes: Set<UInt32>)?
}

extension Workspace {
    /// The trees show: the Support tool is on, or the Select tool picked a
    /// tree.
    var treesLive: Bool { tool == .support || supportPick?.tree == true }

    /// A node counts for the dots and the picks: all nodes with the tool
    /// on, else only the nodes of the picked tree.
    func treeNodeShown(_ part: Int, _ k: Int) -> Bool {
        guard tool != .support, let o = supportPick?.only else { return true }
        return part == o.part && o.nodes.contains(UInt32(k))
    }

    /// The nodes of the tree of node i of part `part`: the same root.
    func treeOf(_ part: Int, _ i: UInt32) -> Set<UInt32> {
        guard let t = supportTrees[part] else { return [] }
        let n = t.nodes.count
        var root = [Int](repeating: -1, count: n)
        func rootOf(_ k: Int) -> Int {
            var chain: [Int] = []
            var c = k
            while root[c] < 0 {
                chain.append(c)
                let d = Int(t.nodes[c].down)
                if d < 0 || d >= n || chain.count > n { break }
                c = d
            }
            let r = root[c] >= 0 ? root[c] : c
            for x in chain { root[x] = r }
            return r
        }
        guard Int(i) < n else { return [] }
        let want = rootOf(Int(i))
        return Set((0 ..< n).filter { rootOf($0) == want }.map { UInt32($0) })
    }

    /// Selects the support at a point of a support line (mm). False with
    /// the Support tool on.
    @discardableResult
    func supportSelectAt(_ q: SIMD3<Double>) -> Bool {
        guard tool != .support else { return false }
        var pick = SupportPick(point: q, tree: model.setting("project.support_style") == "tree")
        // The overhang over the line: up from it, half a millimeter a step,
        // to the first surface that faces down.
        var tp = zs_toolpaths()
        let top = zs_app_toolpaths(model.core, &tp) == 0 && tp.layer_count > 0 ? Double(tp.layer_z[tp.layer_count - 1]) : q.z
        let cap = 2048
        var pts = [Double](repeating: 0, count: 3 * cap)
        var n = 0, lo = 0.0, hi = 0.0
        var z = q.z
        while z <= top + 0.5 {
            if zs_app_support_pick(model.core, q.x, q.y, z, 2, &pts, cap, &n, &lo, &hi) >= 0, n >= 3 {
                pick.overhang = (Array(pts.prefix(3 * n)), n, lo, hi)
                break
            }
            n = 0
            z += 0.5
        }
        supportPick = pick
        treeSelected = nil
        treeClamp = 0
        treeDots = nil
        if pick.tree {
            // No check of the pick in this read: no node is selected yet.
            supportPicking = true
            readSupportTrees()
            supportPicking = false
            // The node nearest to the point: a node over it counts more
            // than a node beside it.
            var best = Double.infinity
            for (part, t) in supportTrees {
                for (k, nd) in t.nodes.enumerated() {
                    let d = hypot(nd.x - q.x, nd.y - q.y) + 0.25 * abs(nd.z - q.z)
                    if d < best {
                        best = d
                        treeSelected = (part, UInt32(k))
                    }
                }
            }
            if let s = treeSelected {
                supportPick?.only = (s.part, treeOf(s.part, s.node))
            } else {
                // No tree there: the overhang, as for a grid.
                supportPick?.tree = false
                supportTrees = [:]
            }
        }
        showSupport()
        return true
    }

    /// A click of the Select tool: on a support line (zs_view_path_feature
    /// 6 or 7), it selects that support and not the line. False elsewhere.
    func selectSupport(at p: CGPoint) -> Bool {
        guard tool == .select, page == .threeD, let v = canvas.view else { return false }
        let s = canvas.window?.backingScaleFactor ?? 2
        var seg = 0
        let path = zs_view_pick_segment(v, Float(p.x * s), Float(p.y * s), &seg)
        guard path != noPath else { return false }
        let f = zs_view_path_feature(v, path)
        guard f == Int32(ZS_FEATURE_SUPPORT.rawValue) || f == Int32(ZS_FEATURE_SUPPORT_INTERFACE.rawValue),
              let q = pathPoint(path, seg: seg) else { return false }
        clearSelection()
        return supportSelectAt(SIMD3(q.x, q.y, q.z))
    }

    /// The pick ends: no tree, no overhang.
    func clearSupportPick() {
        guard tool != .support, supportPick != nil else { return }
        supportPick = nil
        treeSelected = nil
        treeClamp = 0
        supportTrees = [:]
        treeDots = nil
        showSupport()
    }

    /// Delete: the branch of a tree, or a Block area over the overhang of a
    /// grid support, and the marks near the line.
    @discardableResult
    func removePickedSupport() -> Bool {
        guard tool != .support, let pick = supportPick else { return false }
        if pick.tree {
            let done = deleteTreeBranch()
            if treeSelected == nil { clearSupportPick() }
            return done
        }
        var changed = zs_app_mark_remove_near(model.core, pick.point.x, pick.point.y, pick.point.z, 3) > 0
        if var o = pick.overhang, zs_app_support_area_add(model.core, Int32(ZS_MARK_BLOCK.rawValue), &o.points, o.n, o.lo, o.hi) >= 0 {
            changed = true
        }
        supportPick = nil
        if changed { supportEdited() } else { showNote("zslice found no overhang over this support.") }
        showSupport()
        return true
    }

    /// Make it: the picked support becomes another kind (ZS_MARK_GRID,
    /// ZS_MARK_TREE, or ZS_MARK_BRIDGE), an area of that kind over its
    /// overhang. The marks near the line go. The pick ends, as the next
    /// slice has new lines.
    func kindPickedSupport(_ kind: zs_mark_kind) {
        guard tool != .support, let pick = supportPick else { return }
        clearSupportPick()
        guard var o = pick.overhang else {
            showNote("zslice found no overhang over this support.")
            return
        }
        zs_app_mark_remove_near(model.core, pick.point.x, pick.point.y, pick.point.z, 3)
        guard zs_app_support_area_add(model.core, Int32(kind.rawValue), &o.points, o.n, o.lo, o.hi) >= 0 else {
            showNote("The support did not change.")
            return
        }
        supportEdited()
    }

    /// Delete and Esc for a picked support. True if it used the key.
    func supportPickKey(_ event: NSEvent) -> Bool {
        guard tool != .support, supportPick != nil else { return false }
        switch event.specialKey {
        case .delete?, .deleteForward?: return removePickedSupport()
        default:
            guard event.charactersIgnoringModifiers == "\u{1b}" else { return false }
            clearSupportPick()
            return true
        }
    }

    /// After a new read of the trees: the picked tree again, or the pick
    /// ends (an undo took the tree away).
    func refreshSupportPick() {
        guard tool != .support, supportPick?.tree == true, !supportPicking else { return }
        if let s = treeSelection {
            supportPick?.only = (s.part, treeOf(s.part, s.index))
        } else {
            supportPick = nil
        }
    }

    /// The text of the card of a picked support.
    var supportPickInfo: String {
        guard let pick = supportPick else { return "" }
        if pick.tree, let s = treeSelection {
            return String(format: "A branch, %.1f mm wide, z %.1f mm. Drag a dot, a ring, or a segment to pull it. Right click a dot for Delete Branch.", 2 * s.node.r, s.node.z)
        }
        if let o = pick.overhang {
            return String(format: "It holds up the overhang in blue, z %.1f to %.1f mm.", o.lo, o.hi)
        }
        return "zslice found no overhang over this support."
    }
}
