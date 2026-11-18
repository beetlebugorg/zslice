// support.js: the Support tool (U), the support editor of the 3D view.
//
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
// The core keeps the areas (zs_app_support_area_*, in the worker), slices
// with them, and keeps them in the 3MF and the history. The core view
// draws them (zs_view_support_add). While the tool is on, a pick skips the
// support lines (zs_view_pick_skip_support), so a click finds the part
// under them, and the support lines are faint (a focus on the other
// features), so the outlines show through them. The card turns that off.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";

// The kinds of an area (enum zs_mark_kind).
export const KINDS = [
  { kind: 0, name: "Support grid" },
  { kind: 1, name: "Support tree" },
  { kind: 3, name: "Block" },
];
const BLOCK = 3;
// The distance from a point or an outline that still hits it, CSS pixels.
const NEAR = 10;

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
    }
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
    this.showCard();
    this.ctx.frame();
  }

  // ---- the card ----

  // Before each frame: the card shows only in the 3D view.
  place() {
    const want = this.on && this.ctx.page() === "3d";
    if (want === this.card.hidden) this.showCard();
  }

  showCard() {
    const card = this.card;
    if (!this.on || this.ctx.page() !== "3d") {
      card.hidden = true;
      return;
    }
    card.hidden = false;
    card.replaceChildren();
    const a = this.sel >= 0 ? this.areas[this.sel] : null;
    const title = el("div", "sc-title", a ? `Support area ${this.sel + 1}` : "Draw support");
    card.append(title);
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
    if (a) {
      const info = el("div", "sc-info", `${a.pts.length} points, z ${a.zLo.toFixed(2)} to ${a.zHi.toFixed(2)} mm. Drag a point to move it.`);
      const del = el("button", "tool sc-delete", "Delete");
      del.title = "Delete this area (Delete)";
      del.onclick = () => this.removeSelected();
      card.append(info, del);
    } else {
      const n = this.draft.length;
      const hint = n === 0
        ? "Click points on the part to draw an area. The points snap to the lines; Shift: no snap. Click an outline to select its area."
        : n < 3
          ? `${n} point${n === 1 ? "" : "s"}. Click more points (at least 3). Backspace removes the last one; Esc stops.`
          : `${n} points. Click the first point, or press Enter, to close the area.`;
      card.append(el("div", "sc-info", hint));
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
    this.ctx.host.style.cursor = this.pointAt(px, py) ? "grab" : "crosshair";
  }

  // ---- draw ----

  // A click in the view (app.js, on a release with no drag).
  click(px, py, shift) {
    if (!this.on || this.ctx.page() !== "3d") return;
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
        return false;
      case "Delete":
        if (this.sel >= 0) {
          this.removeSelected();
          return true;
        }
        return false;
      case "Escape":
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
    if (e.button !== 0 || !this.on || this.ctx.page() !== "3d" || this.draft.length > 0) return;
    const [px, py] = this.at(e);
    const hit = this.pointAt(px, py);
    if (!hit) return;
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
