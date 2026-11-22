// gizmo.js: the gizmo of the transform tool (M; R and G are other keys of
// it), as the move and turn gizmos of Blender, Fusion, and Bambu Studio.
// With the tool on and a part selected, the gizmo is on the part:
//
// - three rings: red turns the part about X, green about Y, and blue about
//   Z, in steps of 15° (Shift: 1°). The label shows the angle;
// - three arrows out of the rings: red moves the part along X, green
//   along Y, and blue lifts it (Z): up, it floats (with support on it
//   prints on support; with support off it falls when the drag ends, and
//   the card says why); down, it sinks into the bed, and the slice cuts
//   off the part under the bed. The label shows the distance;
// - a drag on the part itself (tools.js, moveStart) carries it on the bed,
//   with smart guides: its edges and center snap to the edges and the
//   centers of the other parts and to the center of the bed (Shift: no
//   snap).
//
// The view updates on each frame of a drag: the beads of the part move or
// turn at once (zs_view_part_preview), and never go below the bed (only a
// lift down sinks). The slice follows: each change goes to the worker as
// a draft slice, the next one when the slice before it is in the view
// (`sliced`). The release ends the drag: one step of the history, the
// exact slice, and the physics (a part turned onto an edge falls flat,
// unless support holds it; a part in the air with support off falls).
//
// The core view draws the rings, the arrows, and the guides, finds the
// handle under the pointer, and gives the angle or the distance of a drag
// (zs_view_set_gizmo, zs_view_gizmo_at, zs_view_ring_*, zs_view_arrow_*,
// zs_view_set_guides, zs_part_snap), so the GTK app, the macOS app, and
// the Windows app have the same gizmo. This file has the events, the
// cursor, the label, and the live slice.
//
// References: the move and rotate gizmos and the sinking objects of
// PrusaSlicer, OrcaSlicer, and Bambu Studio (docs/references/prusaslicer.md),
// and the smart guides (docs/references/papers-and-algorithms.md).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const NAMES = ["X", "Y", "Z"];
// The distance from a handle that still hits it, CSS pixels.
const TOL = 9;
// The distance of a snap on the screen, CSS pixels.
const SNAP_PX = 8;
// The longest wait for the slice of a live change, ms: then the next
// change goes anyway.
const LIVE_WAIT_MS = 700;

// The radius of the rings around part p, mm (the same in each shell).
export function gizmoRadius(p) {
  return 0.62 * Math.max(p.sizeX, p.sizeY, p.sizeZ) + 4;
}

// The center of the gizmo of part p: the middle of its box.
export function gizmoCenter(p) {
  return [p.x, p.y, Math.max(0, p.z ?? 0) + p.sizeZ / 2];
}

export class Gizmo {
  // ctx: { host (the element of the view), view (view.js: x, v, w),
  //        client, part() (the selected part or null), active() (the
  //        tool is on), select(part), frame() (request a frame),
  //        settle(index) -> Promise (the physics after a drag), toast }
  constructor(ctx) {
    this.ctx = ctx;
    this.label = document.createElement("div");
    this.label.className = "turn-label";
    this.label.hidden = true;
    ctx.host.append(this.label);
    this.drag = null; // a drag of a ring or an arrow
    this.live = null; // the live change of a part: see beginLive
    this.on = false;
    // Capture: a press on a handle is a drag of it, not an orbit.
    ctx.host.addEventListener("pointerdown", (e) => this.press(e), true);
    ctx.host.addEventListener("pointermove", (e) => this.hover(e));
  }

  dpr() {
    return window.devicePixelRatio || 1;
  }

  // The pixel of a pointer event in the view, device pixels.
  at(e) {
    const r = this.ctx.host.getBoundingClientRect();
    return [(e.clientX - r.left) * this.dpr(), (e.clientY - r.top) * this.dpr()];
  }

  // Before each frame: the gizmo on the part now, or none.
  place() {
    const p = this.ctx.part();
    const on = !!p && this.ctx.active();
    const x = this.ctx.view.x;
    const v = this.ctx.view.v;
    if (on) {
      // During a drag the gizmo goes with the part.
      const t = this.live?.index === p.index && !this.live.done ? this.live.target : null;
      const c = gizmoCenter(t ? { ...p, ...t } : p);
      x.zs_view_set_gizmo(v, c[0], c[1], c[2], gizmoRadius(p), 1);
    } else if (this.on) {
      x.zs_view_set_gizmo(v, 0, 0, 0, 0, 0);
    }
    this.on = on;
    if (!on && !this.drag) this.label.hidden = true;
  }

  // The handle under the pointer: 0-2 a ring, 3-5 an arrow, or -1. Only
  // the view counts: a card, the dock, or a button over a handle keeps
  // its own clicks.
  handleAt(e) {
    if (!this.on || e.target?.tagName !== "CANVAS") return -1;
    const [px, py] = this.at(e);
    return this.ctx.view.x.zs_view_gizmo_at(this.ctx.view.v, px, py, TOL * this.dpr());
  }

  hover(e) {
    if (this.drag || !this.on) return;
    const h = this.handleAt(e);
    this.ctx.host.style.cursor = h >= 3 ? "move" : h >= 0 ? "grab" : "";
  }

  press(e) {
    if (e.button !== 0 || !this.on || this.drag) return;
    const h = this.handleAt(e);
    if (h < 0) return;
    const [px, py] = this.at(e);
    const x = this.ctx.view.x;
    const v = this.ctx.view.v;
    const p = this.ctx.part();
    if (!p) return;
    const ok = h < 3 ? x.zs_view_ring_press(v, h, px, py) : x.zs_view_arrow_press(v, h - 3, px, py);
    if (!ok) return;
    e.preventDefault();
    e.stopPropagation();
    if (h < 3) {
      // A turn: the center of the box is the pivot of the preview.
      this.drag = { kind: "turn", axis: h, sent: 0, want: 0, busy: false, index: p.index, pivot: gizmoCenter(p), z: p.z ?? 0 };
    } else {
      this.drag = { kind: "move", axis: h - 3, index: p.index };
      this.beginLive(p);
    }
    this.ctx.host.style.cursor = h < 3 ? "grabbing" : "move";
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
      const [mx, my] = this.at(ev);
      if (d.kind === "turn") {
        d.want = Math.round(x.zs_view_ring_drag(v, mx, my, ev.shiftKey ? 1 : 15));
        this.showLabel(ev, `${d.want > 0 ? "+" : ""}${d.want}° about ${NAMES[d.axis]}`);
        this.turnPreview(d);
        this.sendTurn();
      } else {
        const c = this.ctx.view.w.cell;
        if (!x.zs_view_arrow_drag(v, mx, my, c)) return;
        this.arrowMove(d.axis, this.ctx.view.w.f64(c), ev.shiftKey, ev);
      }
    };
    const up = (ev) => {
      ev.stopPropagation();
      target.removeEventListener("pointermove", move, true);
      target.removeEventListener("pointerup", up, true);
      target.removeEventListener("pointercancel", up, true);
      x.zs_view_ring_release(v);
      this.label.hidden = true;
      const d = this.drag;
      this.drag = null;
      this.ctx.host.style.cursor = "";
      if (d?.kind === "turn") {
        // No turn: no slice comes to end the preview.
        if (d.want === (d.shown ?? 0)) x.zs_view_part_preview(v, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
        this.ctx.frame();
        // The last steps go to the core first; then the turn is done, and
        // the slice that waited starts.
        this.finishTurn(d);
      } else {
        this.endLive();
      }
    };
    target.addEventListener("pointermove", move, true);
    target.addEventListener("pointerup", up, true);
    target.addEventListener("pointercancel", up, true);
    this.ctx.frame();
  }

  // ---- a turn ----

  // The beads of the part turn in the view at once (zs_view_part_preview)
  // about the axis of the bed, by the angle of the drag since the slice
  // that the view shows. The slice of the new place ends the preview.
  turnPreview(d) {
    const deg = d.want - (d.shown ?? 0);
    const t = (deg * Math.PI) / 180 / 2;
    const axis = [0, 0, 0];
    axis[d.axis] = 1;
    const s = Math.sin(t);
    const [px, py, pz] = d.pivot;
    // On the bed: the lowest bead stays on the bed. A part with a lift
    // keeps it (the view never draws it below the bed).
    const flags = d.z === 0 ? 1 : 0;
    this.ctx.view.x.zs_view_part_preview(this.ctx.view.v, d.index, axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(t), px, py, pz, 0, 0, 0, flags);
    this.ctx.frame();
  }

  // One step at a time to the core: the turn since the last step.
  async sendTurn(d = this.drag) {
    if (!d || d.kind !== "turn" || d.busy || d.want === d.sent) return;
    d.busy = true;
    const step = d.want - d.sent;
    d.sent = d.want;
    d.flight = this.ctx.client.call("partTurn", { index: d.index, axis: d.axis, degrees: step, hold: true, total: d.sent }).then((r) => {
      if (r.part && this.ctx.part()?.index === r.part.index) this.ctx.select(r.part);
      this.ctx.frame();
    });
    await d.flight;
    d.busy = false;
    this.sendTurn(d);
  }

  // The end of a turn: the step in flight and the last step, then the
  // slice and the physics.
  async finishTurn(d) {
    if (!d) return;
    while (d.busy) await d.flight;
    await this.sendTurn(d);
    if (d.sent !== 0) await this.ctx.settle?.(d.index);
    await this.ctx.client.call("sliceHeld");
  }

  // ---- a move: the arrows, and the drag of the part (tools.js) ----

  // Starts a live change of part p: its place and lift, as the view shows
  // them (target), as the worker has them (sent), and as the slice in
  // the view has them (shown).
  beginLive(p) {
    const pose = { x: p.x, y: p.y, z: p.z ?? 0 };
    const live = { index: p.index, part: p, start: { ...pose }, target: { ...pose }, sent: { ...pose }, shown: { ...pose }, wait: 0, others: null, bed: null };
    this.live = live;
    // The boxes of the other parts and the size of the bed, for the snap.
    this.ctx.client.call("partBoxes", { except: p.index }).then((r) => {
      live.others = r.boxes;
      live.bed = r.bed;
    });
  }

  // The drag of the part on the bed: it goes by (dx, dy) mm from the
  // start, with the snap unless noSnap.
  bodyMove(dx, dy, noSnap, ev) {
    const l = this.live;
    if (!l) return;
    const t = { ...l.start, x: l.start.x + dx, y: l.start.y + dy };
    const snap = noSnap ? null : this.snap(t, ev);
    if (snap) {
      t.x += snap.dx;
      t.y += snap.dy;
    }
    this.showGuides(snap?.guides ?? []);
    t.x = Math.round(t.x * 100) / 100;
    t.y = Math.round(t.y * 100) / 100;
    this.moveLive(t);
    return t;
  }

  // The move of an arrow: `d` mm along `axis` from the start of the drag.
  arrowMove(axis, d, noSnap, ev) {
    const l = this.live;
    if (!l) return;
    const t = { ...l.start };
    if (axis === 2) {
      t.z = l.start.z + d;
      // The bed snaps: a lift near 0 is 0. The part sinks at most to
      // 0.5 mm over the bed.
      if (!noSnap && Math.abs(t.z) < this.mmAlong(2) * SNAP_PX) t.z = 0;
      t.z = Math.max(t.z, -(l.part.sizeZ - 0.5));
      t.z = Math.round(t.z * 100) / 100;
      const s = t.z === 0 ? "On the bed" : t.z > 0 ? `Lift ${t.z.toFixed(2)} mm` : `${(-t.z).toFixed(2)} mm into the bed`;
      this.showLabel(ev, s);
    } else {
      if (axis === 0) t.x = l.start.x + d;
      else t.y = l.start.y + d;
      // The snap on the axis of the arrow only.
      const snap = noSnap ? null : this.snap(t, ev, this.mmAlong(axis) * SNAP_PX);
      if (snap) {
        if (axis === 0) t.x += snap.dx;
        else t.y += snap.dy;
        this.showGuides(snap.guides.filter((g) => (axis === 0 ? g[0] === g[2] : g[1] === g[3])));
      } else this.showGuides([]);
      if (axis === 0) t.x = Math.round(t.x * 100) / 100;
      else t.y = Math.round(t.y * 100) / 100;
      const dd = axis === 0 ? t.x - l.start.x : t.y - l.start.y;
      this.showLabel(ev, `${dd >= 0 ? "+" : ""}${dd.toFixed(2)} mm along ${NAMES[axis]}`);
    }
    this.moveLive(t);
  }

  // mm along `axis` for one CSS pixel, at the center of the gizmo of the
  // live part.
  mmAlong(axis) {
    const l = this.live;
    const { view } = this.ctx;
    const c = gizmoCenter({ ...l.part, ...l.start });
    const d = [...c];
    d[axis] += 10;
    const a = view.pixelOf(c[0], c[1], c[2]);
    const b = view.pixelOf(d[0], d[1], d[2]);
    const px = a && b ? Math.hypot(b[0] - a[0], b[1] - a[1]) / this.dpr() : 0;
    return px > 0.5 ? 10 / px : 0.2;
  }

  // mm on the bed for one CSS pixel near the pointer.
  mmPerPx(ev) {
    const { view } = this.ctx;
    const r = this.ctx.host.getBoundingClientRect();
    const [px, py] = ev ? this.at(ev) : [(r.width / 2) * this.dpr(), (r.height / 2) * this.dpr()];
    const c = view.w.cell;
    if (!view.x.zs_view_bed_point(view.v, px, py, c, c + 8)) return 0.2;
    const a = [view.w.f64(c), view.w.f64(c + 8)];
    if (!view.x.zs_view_bed_point(view.v, px + 10 * this.dpr(), py, c, c + 8)) return 0.2;
    const b = [view.w.f64(c), view.w.f64(c + 8)];
    return Math.max(0.01, Math.hypot(b[0] - a[0], b[1] - a[1]) / 10);
  }

  // The snap of the part at place t (zs_part_snap): { dx, dy, guides },
  // or null with no boxes yet.
  snap(t, ev, tol = this.mmPerPx(ev) * SNAP_PX) {
    const l = this.live;
    if (!l?.others || !l.bed) return null;
    const p = l.part;
    const box = [t.x - p.sizeX / 2, t.y - p.sizeY / 2, t.x + p.sizeX / 2, t.y + p.sizeY / 2];
    const { view } = this.ctx;
    const w = view.w;
    const n = l.others.length;
    const cap = 12;
    const doubles = 4 + 4 * n + 2 + 4 * cap;
    const ptr = w.alloc(doubles * 8);
    try {
      const f = new Float64Array(view.x.memory.buffer, ptr, doubles);
      f.set(box, 0);
      l.others.forEach((o, i) => f.set(o, 4 + 4 * i));
      const o = 4 + 4 * n;
      const k = view.x.zs_part_snap(ptr, ptr + 32, n, l.bed[0], l.bed[1], tol, ptr + 8 * o, ptr + 8 * (o + 2), cap);
      // The memory can grow in the call: a new view of it.
      const g = new Float64Array(view.x.memory.buffer, ptr, doubles);
      const list = [];
      for (let i = 0; i < k; i++) list.push(Array.from(g.subarray(o + 2 + 4 * i, o + 6 + 4 * i)));
      return { dx: g[o], dy: g[o + 1], guides: list };
    } finally {
      w.free(ptr, doubles * 8);
    }
  }

  showGuides(lines) {
    const { view } = this.ctx;
    const a = new Float64Array(Math.max(1, lines.length) * 4);
    lines.forEach((g, i) => a.set(g, i * 4));
    view.w.withBytes(new Uint8Array(a.buffer), (p) => view.x.zs_view_set_guides(view.v, p, lines.length));
    this.ctx.frame();
  }

  // The part goes to t ({ x, y, z }): the view at once, the worker when
  // the slice before is in the view.
  moveLive(t) {
    const l = this.live;
    if (!l) return;
    l.target = { ...t };
    this.preview();
    this.sendLive();
  }

  // The beads of the part at the target, from the place of the slice in
  // the view. A lift down sinks the part into the bed (the bed hides the
  // part under it); else the view keeps it over the bed.
  preview() {
    const l = this.live;
    if (!l) return;
    const t = l.target;
    const s = l.shown;
    const flags = t.z < 0 ? 4 : 0;
    this.ctx.view.x.zs_view_part_preview(this.ctx.view.v, l.index, 0, 0, 0, 1, 0, 0, 0, t.x - s.x, t.y - s.y, t.z - s.z, flags);
    this.ctx.frame();
  }

  sendLive() {
    const l = this.live;
    if (!l) return;
    const t = l.target;
    const same = t.x === l.sent.x && t.y === l.sent.y && t.z === l.sent.z;
    if (same || performance.now() < l.wait) return;
    l.sent = { ...t };
    l.wait = performance.now() + LIVE_WAIT_MS;
    this.ctx.client.call("partPlace", { index: l.index, x: t.x, y: t.y, z: t.z, hold: true, live: true }).then((r) => {
      if (r.part && this.ctx.part()?.index === r.part.index && this.live === l) this.ctx.select({ ...r.part, ...l.target });
    });
    // No slice in time: the next change goes anyway.
    clearTimeout(l.timer);
    l.timer = setTimeout(() => {
      l.wait = 0;
      this.sendLive();
    }, LIVE_WAIT_MS);
  }

  // A slice is in the view (app.js, the "sliced" event): m.live is the
  // pose of the live part in it, m.turn the turn of a live turn.
  sliced(m) {
    const d = this.drag;
    if (d?.kind === "turn" && m.turn !== undefined) {
      d.shown = m.turn;
      const p = this.ctx.part();
      if (p) d.pivot = gizmoCenter(p);
      this.turnPreview(d);
    }
    const l = this.live;
    // A drag with no live slice: the first slice after its end is the
    // slice of its place.
    if (l?.done && !m.live) {
      this.live = null;
      return;
    }
    if (l && m.live && m.live.index === l.index) {
      l.shown = { x: m.live.x, y: m.live.y, z: m.live.z };
      l.wait = 0;
      const t = l.target;
      // The slice of the end of the drag: the beads are where the part
      // is, and the load ended the preview.
      if (l.done && t.x === l.shown.x && t.y === l.shown.y && t.z === l.shown.z) {
        this.live = null;
        return;
      }
      this.preview();
      this.sendLive();
    }
  }

  // A fall of part `index` starts (app.js): the live change ends, and the
  // fall moves the beads from the place of the slice in the view. Returns
  // the offset of the part from those beads (mm), or null.
  takeLive(index) {
    const l = this.live;
    if (!l || l.index !== index) return null;
    this.live = null;
    clearTimeout(l.timer);
    return [l.target.x - l.shown.x, l.target.y - l.shown.y, l.target.z - l.shown.z];
  }

  // The end of a live change: the last place, one step of the history,
  // the exact slice, and the physics.
  async endLive() {
    const l = this.live;
    if (!l) return;
    clearTimeout(l.timer);
    this.showGuides([]);
    const t = l.target;
    const moved = t.x !== l.start.x || t.y !== l.start.y || t.z !== l.start.z;
    if (!moved) {
      this.live = null;
      this.ctx.view.x.zs_view_part_preview(this.ctx.view.v, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
      this.ctx.frame();
      return;
    }
    // The preview stays until the slice of this place is in the view
    // (sliced), so the part does not jump back to the place of a draft.
    l.done = true;
    l.wait = Infinity;
    const r = await this.ctx.client.call("partPlace", { index: l.index, x: t.x, y: t.y, z: t.z, hold: true });
    l.sent = { ...t };
    if (r.part && this.ctx.part()?.index === r.part.index) this.ctx.select(r.part);
    // A part in the air with no support falls, and the toast says why.
    const why = r.part?.note?.startsWith("Support is off") ? r.part.note : "";
    await this.ctx.settle?.(l.index, why);
    await this.ctx.client.call("sliceHeld");
  }

  showLabel(ev, text) {
    const host = this.ctx.host.getBoundingClientRect();
    this.label.textContent = text;
    this.label.hidden = false;
    this.label.style.left = `${ev.clientX - host.left + 16}px`;
    this.label.style.top = `${ev.clientY - host.top - 30}px`;
  }
}
