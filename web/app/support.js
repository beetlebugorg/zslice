// support.js: the Support tool (S), the support editor of the 3D view.
//
// - Hover: the overhang under the pointer lights up (zs_app_support_pick,
//   in the worker): the faces that face down and connect to the face under
//   the pointer. A click puts support under it: a new area of its outline.
//   Alt and a click draw a point there.
// - Draw: click points on the part. A point snaps to the end of the
//   nearest line, as the measure tape does (Shift: no snap). Click the
//   first point again, or press Enter, to close the area. Backspace removes
//   the last point; Esc stops the area.
// - The area: support grows under all of the part in it that faces down
//   (Support grid or Support tree), also where the support angle gives
//   none; or no support there (Block). The card of the area changes its
//   kind, or deletes it.
// - Edit: click an outline to select its area, and drag a point of it. The
//   outline follows the pointer at once; the slice waits for the end of
//   the drag (the hold of the plate set, as in the Turn tool).
//
// - Trees (tree support): the nodes of the trees show as dots. Click a
//   dot or a segment to select its branch. Drag a dot to move the node,
//   drag the ring of the selected node to make the branch wider or
//   narrower there, and drag a segment to move the whole branch. Delete
//   removes the branch (and the branches over it). "Add a branch": tap a
//   spot on the bed, then the place on the part that needs support, and
//   the core plans a branch from that foot to that tip. "Reset support"
//   plans the trees of the part again. The core keeps each edit within
//   the rules (out of the part, at most the tree angle, at least the
//   radius that the rules need); an edit that a rule limited shows red.
//   The dots and the ring follow the pointer at once; the core gets the
//   edit at most each 60 ms, and the slice waits for the end of the drag.
//
// The core keeps the areas (zs_app_support_area_*, in the worker), slices
// with them, and keeps them in the 3MF and the history. The core view
// draws them (zs_view_support_add). While the tool is on, a pick skips the
// support lines (zs_view_pick_skip_support), so a click finds the part
// under them, and the support lines are faint (a focus on the other
// features), so the outlines show through them. The card turns that off.
// The trees are the same (zs_app_support_tree_*); the view draws their
// nodes as bare paths.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { TREE_STRIDE } from "./core.js";
import { placeBeside, freeArea } from "./place.js";

// The kinds of an area (enum zs_mark_kind).
export const KINDS = [
  { kind: 0, name: "Support grid" },
  { kind: 1, name: "Support tree" },
  { kind: 3, name: "Block" },
];
const BLOCK = 3;
// The distance from a point or an outline that still hits it, CSS pixels.
const NEAR = 10;
// The kinds of the view for the trees: blue, and red for a limited edit.
const TREE_KIND = 1;
const RED = 3;
// The flags of zs_view_support_add.
const CLOSED = 1;
const SELECTED = 2;
const POINTS = 4;
const BARE = 8;
// The node flags (enum zs_tree_node_flag).
const TREE_TIP = 1;
// The smallest distance on the screen between two dots that the view
// draws (CSS pixels): more dots add no help, and the view has a budget.
const DOT_CELL = 7;
// The clamp bits (enum zs_tree_clamp), in words.
const CLAMP_TEXT = [
  [1, "it stays out of the part"],
  [2, "a segment leans at most the tree angle"],
  [4, "the rules need this width"],
  [8, "this is the largest width"],
  [16, "the foot moved nearer, so the branch can reach the tip"],
];

function loadPaneOpen() {
  try {
    return localStorage.getItem("zslice-support-pane") !== "0";
  } catch {
    return true;
  }
}

export class SupportTool {
  // ctx: { client, view (view.js: x, v, w), canvas, host (the element of
  //        the view), active() (the tool is on), page() ("2d" or "3d"),
  //        frame() (request a frame), toast(text), focus() (the focus
  //        of the view changed: see seeThrough) }
  constructor(ctx) {
    this.ctx = ctx;
    this.areas = []; // { kind, zLo, zHi, pts: [[x, y, z], ...] }
    this.draft = []; // the points of the area that the user draws now
    this.sel = -1;
    this.kind = 0; // the kind of the next area
    this.see = true; // the support lines are faint while the tool is on
    this.drag = null;
    this.on = false;
    // The overhang under the pointer: { part, pts, zLo, zHi }, or null. One
    // pick goes to the worker at a time; the last pointer place waits.
    this.hot = null;
    this.picking = false;
    this.pickNext = null;
    // The support trees: part -> { edited, nodes (Float64Array, see
    // core.supportTrees) }; the selected node { part, node }; the clamp
    // bits of the last edit; "Add a branch" ({ foot: [x, y] or null });
    // and the drag of a node, a ring, or a branch.
    this.trees = new Map();
    this.tsel = null;
    this.tclamp = 0;
    this.adding = null;
    this.tdrag = null;
    // The pane of the tool: open at the start; the user closes it when
    // they know the tool, and S or a click on the tool opens it again.
    this.paneOpen = loadPaneOpen();
    this.card = el("div", "support-card");
    this.card.hidden = true;
    ctx.host.append(this.card);
    // Capture: a press on a point is a drag of it, and not an orbit.
    ctx.host.addEventListener("pointerdown", (e) => this.press(e), true);
    ctx.host.addEventListener("pointermove", (e) => this.hover(e));
  }

  dpr() {
    return window.devicePixelRatio || 1;
  }

  at(e) {
    const r = this.ctx.host.getBoundingClientRect();
    return [(e.clientX - r.left) * this.dpr(), (e.clientY - r.top) * this.dpr()];
  }

  // The tool goes on or off.
  setActive(on) {
    if (this.on === on) return;
    this.on = on;
    const { view } = this.ctx;
    view.x.zs_view_pick_skip_support(view.v, on ? 1 : 0);
    if (!on) {
      this.draft = [];
      this.sel = -1;
      this.hot = null;
      this.adding = null;
      this.tsel = null;
    } else this.reloadTrees();
    this.show();
    this.ctx.focus?.();
  }

  // True: the view shows the support lines faint (app.js, updateFocus).
  seeThrough() {
    return this.on && this.see;
  }

  // The areas of the core (after a slice, an undo, or a change).
  setAreas(list) {
    if (this.drag) return;
    this.areas = list ?? [];
    if (this.sel >= this.areas.length) this.sel = -1;
    this.show();
  }

  async reload() {
    const r = await this.ctx.client.call("supportAreas");
    this.setAreas(r.areas);
  }

  // ---- the support trees ----

  // The trees of the core, after a slice or an undo (only while the tool
  // is on: the trees cost a little to read).
  async reloadTrees() {
    if (!this.on) return;
    const r = await this.ctx.client.call("supportTrees");
    if (r.note) this.ctx.toast?.(r.note);
    if (this.tdrag) return;
    this.trees = new Map(r.parts.map((t) => [t.part, t]));
    if (this.tsel && !this.nodeOk(this.tsel)) this.tsel = null;
    this.show();
  }

  nodeOk(s) {
    const t = this.trees.get(s.part);
    return !!t && s.node >= 0 && s.node * TREE_STRIDE < t.nodes.length;
  }

  // Node i of part `part`: { x, y, z, r, rMin, down, layer, branch, flags }.
  node(part, i) {
    const a = this.trees.get(part).nodes;
    const o = i * TREE_STRIDE;
    return { x: a[o], y: a[o + 1], z: a[o + 2], r: a[o + 3], rMin: a[o + 4], down: a[o + 5], layer: a[o + 6], branch: a[o + 7], flags: a[o + 8] };
  }

  count(part) {
    return (this.trees.get(part)?.nodes.length ?? 0) / TREE_STRIDE;
  }

  // The nodes of the branch of node i, and the nodes next to it (the
  // segments into the branch and out of it): { branch: [...], ends: [...] }.
  branchOf(part, i) {
    const n = this.count(part);
    const b = this.node(part, i).branch;
    const a = this.trees.get(part).nodes;
    const branch = [];
    for (let k = 0; k < n; k++) if (a[k * TREE_STRIDE + 7] === b) branch.push(k);
    return branch;
  }

  // The tree element under a pixel: { kind: "ring" | "node" | "seg", part,
  // node }, or null. The ring of the selected node first, then the dots,
  // then the segments (a segment is node -> its down node).
  treeAt(px, py) {
    if (this.trees.size === 0) return null;
    const tol = NEAR * this.dpr();
    const s = this.tsel;
    if (s && this.nodeOk(s)) {
      const nd = this.node(s.part, s.node);
      const ring = this.ringPixels(nd);
      for (let k = 0; k < ring.length; k++) {
        const a = ring[k];
        const b = ring[(k + 1) % ring.length];
        if (a && b && segDist(px, py, a, b) < tol * 0.7) return { kind: "ring", part: s.part, node: s.node };
      }
    }
    let best = null;
    let bestD = tol;
    const pix = [];
    for (const [part, t] of this.trees) {
      const n = t.nodes.length / TREE_STRIDE;
      const q = new Array(n);
      for (let i = 0; i < n; i++) {
        const o = i * TREE_STRIDE;
        q[i] = this.pixelOf([t.nodes[o], t.nodes[o + 1], t.nodes[o + 2]]);
        if (q[i]) {
          const d = Math.hypot(q[i][0] - px, q[i][1] - py);
          if (d < bestD) {
            bestD = d;
            best = { kind: "node", part, node: i };
          }
        }
      }
      pix.push([part, t, q]);
    }
    if (best) return best;
    bestD = tol * 0.7;
    for (const [part, t, q] of pix) {
      const n = t.nodes.length / TREE_STRIDE;
      for (let i = 0; i < n; i++) {
        const d = t.nodes[i * TREE_STRIDE + 5];
        if (d < 0 || !q[i] || !q[d]) continue;
        const dd = segDist(px, py, q[i], q[d]);
        if (dd < bestD) {
          bestD = dd;
          best = { kind: "seg", part, node: i };
        }
      }
    }
    return best;
  }

  // The ring of a node: points on its circle at its z.
  ringPoints(nd, count = 24) {
    const pts = [];
    for (let k = 0; k < count; k++) {
      const t = (2 * Math.PI * k) / count;
      pts.push([nd.x + nd.r * Math.cos(t), nd.y + nd.r * Math.sin(t), nd.z]);
    }
    return pts;
  }

  ringPixels(nd) {
    return this.ringPoints(nd, 16).map((p) => this.pixelOf(p));
  }

  // The point of the plane at height z under a pixel, or null.
  planePoint(px, py, z) {
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_plane_point(view.v, px, py, z, c, c + 8)) return null;
    return [view.w.f64(c), view.w.f64(c + 8)];
  }

  bedPoint(px, py) {
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_bed_point(view.v, px, py, c, c + 8)) return null;
    return [view.w.f64(c), view.w.f64(c + 8)];
  }

  // The trees to the core view: a dot for each node (one dot for nodes
  // closer than DOT_CELL on the screen), the segments of the selected
  // branch, the ring of the selected node, and the foot of a new branch.
  showTrees(add) {
    if (!this.on || this.trees.size === 0) return;
    const s = this.tsel && this.nodeOk(this.tsel) ? this.tsel : null;
    const kind = this.tclamp ? RED : TREE_KIND;
    const cell = DOT_CELL * this.dpr();
    const seen = new Set();
    let branch = [];
    if (s) {
      branch = this.branchOf(s.part, s.node);
      // The segments of the branch, and the segments into it and out of it.
      const inb = new Set(branch);
      const a = this.trees.get(s.part).nodes;
      const n = this.count(s.part);
      for (let k = 0; k < n; k++) {
        const d = a[k * TREE_STRIDE + 5];
        if (d < 0 || !(inb.has(k) || inb.has(d))) continue;
        const p = this.node(s.part, k);
        const q = this.node(s.part, d);
        add([[p.x, p.y, p.z], [q.x, q.y, q.z]], kind, BARE | (inb.has(k) ? SELECTED : 0));
      }
      for (const k of branch) {
        const p = this.node(s.part, k);
        add([[p.x, p.y, p.z]], kind, BARE | POINTS | (k === s.node ? SELECTED : 0));
      }
      const nd = this.node(s.part, s.node);
      add(this.ringPoints(nd), kind, BARE | CLOSED | SELECTED);
    }
    for (const [part, t] of this.trees) {
      const n = t.nodes.length / TREE_STRIDE;
      for (let i = 0; i < n; i++) {
        if (s && part === s.part && branch.includes(i)) continue;
        const o = i * TREE_STRIDE;
        const p = [t.nodes[o], t.nodes[o + 1], t.nodes[o + 2]];
        const q = this.pixelOf(p);
        if (!q) continue;
        const key = `${Math.floor(q[0] / cell)},${Math.floor(q[1] / cell)}`;
        if (seen.has(key)) continue;
        seen.add(key);
        add([p], TREE_KIND, BARE | POINTS);
      }
    }
    if (this.adding?.foot) add([[...this.adding.foot, 0]], TREE_KIND, BARE | POINTS | SELECTED);
  }

  // The result of an edit of the core: the trees of the part, and the
  // clamp bits.
  takeTree(r) {
    if (!r) return;
    if (r.tree) this.trees.set(r.tree.part, r.tree);
    this.tclamp = r.clamp ?? 0;
    if (r.rc < 0) this.ctx.toast?.(r.rc === -11 ? "Slice first: the edits of the trees need a slice." : "The trees cannot change like that.");
  }

  async deleteBranch() {
    const s = this.tsel;
    if (!s) return false;
    this.tsel = null;
    const r = await this.ctx.client.call("treeDelete", { part: s.part, node: s.node });
    this.takeTree(r);
    this.tclamp = 0;
    this.show();
    return true;
  }

  async resetTrees(part) {
    this.tsel = null;
    const r = await this.ctx.client.call("treeReset", { part });
    this.takeTree(r);
    this.show();
  }

  // "Add a branch": a tap on the bed (the foot), then a tap on the part.
  startAdd() {
    this.adding = this.adding ? null : { foot: null };
    this.tsel = null;
    this.show();
  }

  async addClick(px, py) {
    if (!this.adding.foot) {
      const p = this.bedPoint(px, py);
      if (!p) return;
      this.adding.foot = p;
      this.show();
      return;
    }
    const t = this.surfacePoint(px, py, false);
    if (!t) {
      this.ctx.toast?.("Tap the place on the part that needs support.");
      return;
    }
    const f = this.adding.foot;
    this.adding = null;
    const r = await this.ctx.client.call("treeAdd", { part: -1, fx: f[0], fy: f[1], tx: t[0], ty: t[1], tz: t[2] });
    this.takeTree(r);
    if (r.rc >= 0 && r.tree) this.tsel = { part: r.tree.part, node: r.rc };
    else if (r.rc < 0) this.ctx.toast?.("No room for a branch there: tap under an overhang, higher than the bed.");
    this.show();
  }

  // The areas and the draft to the core view, and the card.
  show() {
    const { view } = this.ctx;
    const x = view.x;
    x.zs_view_support_clear(view.v);
    const add = (pts, kind, flags) => {
      if (pts.length === 0) return;
      const a = new Float64Array(pts.length * 3);
      pts.forEach((p, i) => a.set(p, i * 3));
      view.w.withBytes(new Uint8Array(a.buffer), (p) => x.zs_view_support_add(view.v, p, pts.length, kind, flags));
    };
    this.areas.forEach((a, i) => add(a.pts, a.kind, 1 | (i === this.sel ? 2 : 0) | (this.on ? 4 : 0)));
    if (this.on) add(this.draft, this.kind, 4);
    if (this.on && this.hot && this.draft.length === 0) add(this.hot.pts, this.kind, 1 | 2 | 4);
    this.showTrees(add);
    this.showCard();
    this.ctx.frame();
  }

  // ---- the card ----

  // Before each frame: the card shows only in the 3D view.
  place() {
    const want = this.on && this.paneOpen && this.ctx.page() === "3d";
    if (want === this.card.hidden) this.showCard();
    else if (want) this.placeCard();
  }

  // The card stays clear of the selected branch: beside its box on the
  // screen. With no branch, at its place by the tool strip.
  placeCard() {
    const card = this.card;
    const s = this.tsel && this.nodeOk(this.tsel) ? this.tsel : null;
    if (!s || this.card.hidden) {
      card.style.left = "";
      card.style.top = "";
      return;
    }
    const d = this.dpr();
    const box = [Infinity, Infinity, -Infinity, -Infinity];
    for (const k of this.branchOf(s.part, s.node)) {
      const nd = this.node(s.part, k);
      for (const p of [[nd.x - nd.r, nd.y, nd.z], [nd.x + nd.r, nd.y, nd.z], [nd.x, nd.y - nd.r, nd.z], [nd.x, nd.y + nd.r, nd.z]]) {
        const q = this.pixelOf(p);
        if (!q) continue;
        box[0] = Math.min(box[0], q[0] / d);
        box[1] = Math.min(box[1], q[1] / d);
        box[2] = Math.max(box[2], q[0] / d);
        box[3] = Math.max(box[3], q[1] / d);
      }
    }
    if (!(box[2] >= box[0])) return;
    const [x, y] = placeBeside(box, freeArea(this.ctx.host), card.offsetWidth, card.offsetHeight);
    card.style.left = `${x}px`;
    card.style.top = `${y}px`;
  }

  // Opens or closes the pane (S again, or a click on the tool).
  togglePane() {
    this.paneOpen = !this.paneOpen;
    try {
      localStorage.setItem("zslice-support-pane", this.paneOpen ? "1" : "0");
    } catch {
      // No storage: the pane opens at the next start.
    }
    this.showCard();
  }

  showCard() {
    const card = this.card;
    if (!this.on || this.ctx.page() !== "3d" || !this.paneOpen) {
      card.hidden = true;
      return;
    }
    card.hidden = false;
    card.replaceChildren();
    const a = this.sel >= 0 ? this.areas[this.sel] : null;
    const head = el("div", "sc-head");
    const title = el("div", "sc-title", a ? `Support area ${this.sel + 1}` : "Draw support");
    const close = el("button", "tool icon sc-close", "×");
    close.title = "Close this pane (S opens it again)";
    close.setAttribute("aria-label", "Close this pane");
    close.onclick = () => this.togglePane();
    head.append(title, close);
    card.append(head);
    const kindOf = a ? a.kind : this.kind;
    const row = el("div", "sc-kinds");
    for (const k of KINDS) {
      const b = el("button", "tool sc-kind" + (k.kind === kindOf ? " checked" : ""), k.name);
      b.title = k.kind === BLOCK ? "No support under this area" : `${k.name}: support under all of the part in this area that faces down`;
      b.onclick = () => this.setKind(k.kind);
      row.append(b);
    }
    card.append(row);
    const see = el("label", "sc-see");
    const box = el("input");
    box.type = "checkbox";
    box.checked = this.see;
    box.onchange = () => {
      this.see = box.checked;
      this.ctx.focus?.();
    };
    see.append(box, document.createTextNode(" See through the support"));
    card.append(see);
    this.treeCard(card);
    if (a) {
      const info = el("div", "sc-info", `${a.pts.length} points, z ${a.zLo.toFixed(2)} to ${a.zHi.toFixed(2)} mm. Drag a point to move it.`);
      const del = el("button", "tool sc-delete", "Delete");
      del.title = "Delete this area (Delete)";
      del.onclick = () => this.removeSelected();
      card.append(info, del);
    } else {
      const n = this.draft.length;
      const hint = n === 0
        ? "Point at an overhang: it lights up, and a click puts support under it. Alt and a click draw an area point by point (Shift: no snap). Click an outline to select its area."
        : n < 3
          ? `${n} point${n === 1 ? "" : "s"}. Click more points (at least 3). Backspace removes the last one; Esc stops.`
          : `${n} points. Click the first point, or press Enter, to close the area.`;
      card.append(el("div", "sc-info", hint));
    }
    this.placeCard();
  }

  // The part of the card for the trees: the selected branch, "Add a
  // branch", and "Reset support".
  treeCard(card) {
    if (this.trees.size === 0 && !this.adding) return;
    const row = el("div", "sc-kinds");
    const add = el("button", "tool sc-kind" + (this.adding ? " checked" : ""), "Add a branch");
    add.title = "Tap a spot on the bed, then the place on the part that needs support";
    add.onclick = () => this.startAdd();
    row.append(add);
    // Reset: the part of the selection, else the one part with edits.
    const s = this.tsel && this.nodeOk(this.tsel) ? this.tsel : null;
    const edited = [...this.trees.values()].filter((t) => t.edited).map((t) => t.part);
    const part = s ? s.part : edited.length === 1 ? edited[0] : -1;
    if (part >= 0 && this.trees.get(part)?.edited) {
      const reset = el("button", "tool sc-kind", "Reset support");
      reset.title = "Plan the support trees of this part again";
      reset.onclick = () => this.resetTrees(part);
      row.append(reset);
    }
    card.append(row);
    let text;
    if (this.adding) {
      text = this.adding.foot ? "Now tap the place on the part that needs support. Esc stops." : "Tap a spot on the bed for the foot of the branch. Esc stops.";
    } else if (s) {
      const nd = this.node(s.part, s.node);
      const n = this.branchOf(s.part, s.node).length;
      text = `Branch: ${n} node${n === 1 ? "" : "s"}. This node: ${(2 * nd.r).toFixed(1)} mm wide (at least ${(2 * nd.rMin).toFixed(1)} mm), z ${nd.z.toFixed(2)} mm. Drag a dot to move it, the ring to make it wider or narrower, a segment to move the branch. Delete removes the branch.`;
    } else text = "Click a dot or a segment of a tree to select its branch.";
    if (this.tclamp) {
      const why = CLAMP_TEXT.filter(([b]) => this.tclamp & b).map(([, t]) => t);
      text += ` Limited: ${why.join("; ")}.`;
    }
    card.append(el("div", "sc-info" + (this.tclamp ? " sc-limit" : ""), text));
    if (s) {
      const del = el("button", "tool sc-delete", "Delete branch");
      del.title = "Delete this branch and the branches over it (Delete)";
      del.onclick = () => this.deleteBranch();
      card.append(del);
    }
  }

  async setKind(kind) {
    if (this.sel >= 0) {
      const r = await this.ctx.client.call("supportAreaKind", { index: this.sel, kind });
      this.setAreas(r.areas);
    } else {
      this.kind = kind;
      this.show();
    }
  }

  async removeSelected() {
    if (this.sel < 0) return false;
    const i = this.sel;
    this.sel = -1;
    const r = await this.ctx.client.call("supportAreaRemove", { index: i });
    this.setAreas(r.areas);
    return true;
  }

  // ---- picks ----

  // The pixel of a point, or null.
  pixelOf(p) {
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_pixel_of(view.v, p[0], p[1], p[2], c, c + 4)) return null;
    const f = new Float32Array(view.x.memory.buffer, c, 2);
    return [f[0], f[1]];
  }

  // The point of the part under a pixel, or null. snap: to the end of a line.
  surfacePoint(px, py, snap) {
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_surface_point(view.v, px, py, snap ? 1 : 0, c)) return null;
    return [view.w.f64(c), view.w.f64(c + 8), view.w.f64(c + 16)];
  }

  // The point of an area near a pixel: { area, point }, or null. The
  // selected area first.
  pointAt(px, py) {
    const tol = NEAR * this.dpr();
    const order = this.areas.map((_, i) => i).sort((a, b) => (b === this.sel) - (a === this.sel));
    for (const i of order) {
      const pts = this.areas[i].pts;
      for (let j = 0; j < pts.length; j++) {
        const q = this.pixelOf(pts[j]);
        if (q && Math.hypot(q[0] - px, q[1] - py) < tol) return { area: i, point: j };
      }
    }
    return null;
  }

  // The area whose outline is near a pixel, or -1.
  outlineAt(px, py) {
    const tol = NEAR * this.dpr();
    let best = -1;
    let bestD = tol;
    this.areas.forEach((a, i) => {
      const q = a.pts.map((p) => this.pixelOf(p));
      for (let j = 0; j < q.length; j++) {
        const s = q[j];
        const e = q[(j + 1) % q.length];
        if (!s || !e) continue;
        const d = segDist(px, py, s, e);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    });
    return best;
  }

  hover(e) {
    if (!this.on || this.drag || this.ctx.page() !== "3d") return;
    const [px, py] = this.at(e);
    const onPoint = this.pointAt(px, py);
    const onTree = onPoint || this.adding ? null : this.treeAt(px, py);
    this.ctx.host.style.cursor = onPoint || onTree ? (onTree?.kind === "ring" ? "ew-resize" : "grab") : "crosshair";
    if (onTree || this.adding) {
      this.setHot(null);
      return;
    }
    // The overhang under the pointer, while no area is drawn and the
    // pointer is not on a point or an outline.
    if (this.draft.length > 0 || onPoint || e.buttons !== 0 || this.outlineAt(px, py) >= 0) {
      this.setHot(null);
      return;
    }
    this.pickAt(px, py);
  }

  setHot(hot) {
    const was = this.hot;
    this.hot = hot;
    if (!!was !== !!hot || (hot && was && (hot.part !== was.part || hot.zLo !== was.zLo || hot.pts.length !== was.pts.length))) this.show();
  }

  async pickAt(px, py) {
    if (this.picking) {
      this.pickNext = [px, py];
      return;
    }
    const p = this.surfacePoint(px, py, false);
    if (!p) {
      this.setHot(null);
      return;
    }
    this.picking = true;
    try {
      const r = await this.ctx.client.call("supportPick", { x: p[0], y: p[1], z: p[2] });
      if (this.on && this.draft.length === 0) this.setHot(r.hot);
    } finally {
      this.picking = false;
    }
    const next = this.pickNext;
    this.pickNext = null;
    if (next) this.pickAt(next[0], next[1]);
  }

  // ---- draw ----

  // A click in the view (app.js, on a release with no drag).
  click(px, py, shift, alt = false) {
    if (!this.on || this.ctx.page() !== "3d") return;
    if (this.adding) {
      this.addClick(px, py);
      return;
    }
    // A dot or a segment of a tree: select its branch.
    if (this.draft.length === 0) {
      const t = this.treeAt(px, py);
      if (t) {
        this.tsel = { part: t.part, node: t.node };
        this.tclamp = 0;
        this.sel = -1;
        this.show();
        return;
      }
      if (this.tsel) {
        this.tsel = null;
        this.show();
      }
    }
    // The overhang under the pointer: support under it, in one click.
    if (this.draft.length === 0 && this.hot && !alt && this.outlineAt(px, py) < 0) {
      this.addHot();
      return;
    }
    // The first point of the draft closes it.
    if (this.draft.length >= 3) {
      const q = this.pixelOf(this.draft[0]);
      if (q && Math.hypot(q[0] - px, q[1] - py) < NEAR * this.dpr()) {
        this.close();
        return;
      }
    }
    // With no draft, a click on an outline selects its area.
    if (this.draft.length === 0) {
      const i = this.outlineAt(px, py);
      if (i >= 0) {
        this.sel = i;
        this.show();
        return;
      }
    }
    const p = this.surfacePoint(px, py, !shift);
    if (!p) return;
    if (this.draft.length === 0 && this.sel >= 0) {
      // A click elsewhere ends the selection, and starts an area.
      this.sel = -1;
    }
    this.draft.push(p);
    this.show();
  }

  async addHot() {
    const h = this.hot;
    this.hot = null;
    const r = await this.ctx.client.call("supportAreaAdd", { kind: this.kind, pts: h.pts, zLo: h.zLo, zHi: h.zHi });
    if (r.index >= 0) this.sel = r.index;
    this.setAreas(r.areas);
  }

  async close() {
    if (this.draft.length < 3) return;
    const pts = this.draft;
    this.draft = [];
    const r = await this.ctx.client.call("supportAreaAdd", { kind: this.kind, pts });
    if (r.index < 0) this.ctx.toast?.("The area needs 3 points or more, at most 256.");
    else this.sel = r.index;
    this.setAreas(r.areas);
  }

  // A key of the view while the tool is on. True if it used the key.
  key(e) {
    if (!this.on) return false;
    switch (e.key) {
      case "Enter":
        if (this.draft.length < 3) return false;
        this.close();
        return true;
      case "Backspace":
        if (this.draft.length > 0) {
          this.draft.pop();
          this.show();
          return true;
        }
        if (this.sel >= 0) {
          this.removeSelected();
          return true;
        }
        if (this.tsel) {
          this.deleteBranch();
          return true;
        }
        return false;
      case "Delete":
        if (this.sel >= 0) {
          this.removeSelected();
          return true;
        }
        if (this.tsel) {
          this.deleteBranch();
          return true;
        }
        return false;
      case "Escape":
        if (this.adding) {
          this.adding = null;
          this.show();
          return true;
        }
        if (this.tsel) {
          this.tsel = null;
          this.tclamp = 0;
          this.show();
          return true;
        }
        if (this.draft.length > 0) {
          this.draft = [];
          this.show();
          return true;
        }
        if (this.sel >= 0) {
          this.sel = -1;
          this.show();
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  // ---- drag a point ----

  press(e) {
    if (e.button !== 0 || !this.on || this.ctx.page() !== "3d" || this.draft.length > 0 || this.adding) return;
    const [px, py] = this.at(e);
    const hit = this.pointAt(px, py);
    if (!hit) {
      const t = this.treeAt(px, py);
      if (t) this.pressTree(e, t, px, py);
      return;
    }
    e.preventDefault();
    e.stopPropagation();
    this.sel = hit.area;
    this.drag = { ...hit, sent: 0, busy: false, dirty: false, t0: performance.now(), frames: 0, work: 0 };
    this.ctx.host.style.cursor = "grabbing";
    const target = e.target;
    try {
      target.setPointerCapture(e.pointerId);
    } catch {
      // A pointer with no capture (a test): the events still come here.
    }
    const move = (ev) => {
      const d = this.drag;
      if (!d) return;
      ev.stopPropagation();
      const t0 = performance.now();
      const [mx, my] = this.at(ev);
      const p = this.surfacePoint(mx, my, !ev.shiftKey);
      if (!p) return;
      const a = this.areas[d.area];
      a.pts[d.point] = p;
      a.zLo = Math.min(...a.pts.map((q) => q[2]));
      a.zHi = Math.max(...a.pts.map((q) => q[2]));
      d.frames++;
      // The outline follows at once; the core gets the points at most
      // each 60 ms, and holds the slice.
      this.show();
      d.dirty = true;
      this.send(true);
      // The time of the page for this move (a test reads it).
      d.work += performance.now() - t0;
    };
    const up = (ev) => {
      ev.stopPropagation();
      target.removeEventListener("pointermove", move, true);
      target.removeEventListener("pointerup", up, true);
      target.removeEventListener("pointercancel", up, true);
      const d = this.drag;
      this.drag = null;
      this.ctx.host.style.cursor = "";
      if (d && d.frames > 0) this.dragDone = { ms: performance.now() - d.t0, moves: d.frames, workMs: d.work };
      // The end: the last points, and the slice that waited.
      if (d && d.frames > 0) this.finish(d);
      this.show();
    };
    target.addEventListener("pointermove", move, true);
    target.addEventListener("pointerup", up, true);
    target.addEventListener("pointercancel", up, true);
    this.show();
  }

  // ---- drag a node, a ring, or a branch ----

  pressTree(e, t, px, py) {
    e.preventDefault();
    e.stopPropagation();
    const nd = this.node(t.part, t.node);
    // A segment: the branch moves with the point of the plane at the
    // height of the middle of the segment.
    let z = nd.z;
    if (t.kind === "seg" && nd.down >= 0) z = (nd.z + this.node(t.part, nd.down).z) / 2;
    const start = this.planePoint(px, py, z);
    if (!start) return;
    const branch = t.kind === "seg" ? this.branchOf(t.part, t.node) : [t.node];
    const orig = branch.map((k) => {
      const q = this.node(t.part, k);
      return [q.x, q.y];
    });
    const d = { ...t, z, start, branch, orig, moved: false, sent: 0, busy: false, dirty: false, applied: [0, 0], want: null, t0: performance.now(), frames: 0, work: 0 };
    this.tdrag = d;
    // The drag selects the branch of the node.
    this.tsel = { part: t.part, node: t.node };
    this.sel = -1;
    this.ctx.host.style.cursor = "grabbing";
    const target = e.target;
    try {
      target.setPointerCapture(e.pointerId);
    } catch {
      // A pointer with no capture (a test): the events still come here.
    }
    const move = (ev) => {
      if (this.tdrag !== d) return;
      ev.stopPropagation();
      const t0 = performance.now();
      const [mx, my] = this.at(ev);
      const p = this.planePoint(mx, my, d.z);
      if (!p) return;
      d.moved = true;
      d.frames++;
      this.dragTo(d, p);
      this.show();
      d.dirty = true;
      this.sendTree(true);
      d.work += performance.now() - t0;
    };
    const up = (ev) => {
      ev.stopPropagation();
      target.removeEventListener("pointermove", move, true);
      target.removeEventListener("pointerup", up, true);
      target.removeEventListener("pointercancel", up, true);
      this.ctx.host.style.cursor = "";
      if (d.moved) this.dragDone = { ms: performance.now() - d.t0, moves: d.frames, workMs: d.work };
      if (d.moved) this.finishTree(d);
      else this.tdrag = null;
      this.show();
    };
    target.addEventListener("pointermove", move, true);
    target.addEventListener("pointerup", up, true);
    target.addEventListener("pointercancel", up, true);
    this.show();
  }

  // The local preview of a drag to the plane point p: the nodes follow at
  // once; the core clamps them when its answer comes.
  dragTo(d, p) {
    const a = this.trees.get(d.part).nodes;
    if (d.kind === "ring") {
      const nd = this.node(d.part, d.node);
      d.want = { r: Math.max(0.05, Math.hypot(p[0] - nd.x, p[1] - nd.y)) };
      a[d.node * TREE_STRIDE + 3] = d.want.r;
      return;
    }
    const dx = p[0] - d.start[0];
    const dy = p[1] - d.start[1];
    d.want = { dx, dy };
    d.branch.forEach((k, i) => {
      a[k * TREE_STRIDE] = d.orig[i][0] + dx;
      a[k * TREE_STRIDE + 1] = d.orig[i][1] + dy;
    });
  }

  // The op of the drag now, for the core.
  treeOp(d, hold) {
    const w = d.want;
    if (d.kind === "ring") return ["treeRadius", { part: d.part, node: d.node, r: w.r, hold }];
    if (d.kind === "node") return ["treeMoveNode", { part: d.part, node: d.node, x: d.orig[0][0] + w.dx, y: d.orig[0][1] + w.dy, hold }];
    // A branch: the core moves it from where it is now.
    return ["treeMoveBranch", { part: d.part, node: d.node, dx: w.dx - d.applied[0], dy: w.dy - d.applied[1], hold }];
  }

  // The answer of the core during a drag: its clamp, and for a branch the
  // move that it applied. The local preview stays while the pointer moves.
  answerTree(d, r) {
    this.tclamp = r.clamp ?? 0;
    if (d.kind === "seg" && r.tree) {
      const o = d.branch[0] * TREE_STRIDE;
      d.applied = [r.tree.nodes[o] - d.orig[0][0], r.tree.nodes[o + 1] - d.orig[0][1]];
    }
    if (!d.dirty && r.tree) {
      // No newer move: show the clamped edit.
      this.trees.set(r.tree.part, r.tree);
      this.show();
    }
  }

  async sendTree(hold) {
    const d = this.tdrag;
    if (!d || d.busy || !d.dirty || !d.want) return;
    const now = performance.now();
    if (now - d.sent < 60) {
      clearTimeout(d.timer);
      d.timer = setTimeout(() => this.sendTree(true), 60);
      return;
    }
    d.busy = true;
    d.dirty = false;
    d.sent = now;
    const [op, args] = this.treeOp(d, hold);
    const r = await this.ctx.client.call(op, args);
    d.busy = false;
    if (this.tdrag === d) this.answerTree(d, r);
    if (this.tdrag === d && d.dirty) this.sendTree(true);
  }

  // The end of a drag: the last edit with no hold, so the slice that
  // waited starts, the step of the history ends, and the fall check runs.
  async finishTree(d) {
    clearTimeout(d.timer);
    while (d.busy) await new Promise((res) => setTimeout(res, 5));
    const [op, args] = this.treeOp(d, false);
    const r = await this.ctx.client.call(op, args);
    this.released = performance.now();
    if (this.tdrag === d) this.tdrag = null;
    this.takeTree(r);
    this.show();
  }

  async send(hold) {
    const d = this.drag;
    if (!d || d.busy || !d.dirty) return;
    const now = performance.now();
    if (now - d.sent < 60) {
      clearTimeout(d.timer);
      d.timer = setTimeout(() => this.send(true), 60);
      return;
    }
    d.busy = true;
    d.dirty = false;
    d.sent = now;
    const a = this.areas[d.area];
    await this.ctx.client.call("supportAreaSet", { index: d.area, pts: a.pts, hold });
    d.busy = false;
    if (this.drag === d && d.dirty) this.send(true);
  }

  async finish(d) {
    clearTimeout(d.timer);
    const a = this.areas[d.area];
    if (!a) return;
    await this.ctx.client.call("supportAreaSet", { index: d.area, pts: a.pts, hold: true });
    this.released = performance.now();
    await this.ctx.client.call("sliceHeld");
  }
}

// The distance from (px, py) to the segment a-b, pixels.
function segDist(px, py, a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const l2 = dx * dx + dy * dy;
  const t = l2 > 0 ? Math.max(0, Math.min(1, ((px - a[0]) * dx + (py - a[1]) * dy) / l2)) : 0;
  return Math.hypot(px - a[0] - t * dx, py - a[1] - t * dy);
}
