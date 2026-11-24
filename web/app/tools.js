// tools.js: the tools of the preview (linux/src/ui/preview.c, tool_group;
// view3d.c): Select (V), Move (M; R and G are other keys of it), Measure
// (T), and Support (S), as a group at the left of the toolbar. support.js
// has the Support tool, and gizmo.js the gizmo of the Move tool.
//
// - Select: a click selects a line (app.js does it), or a support
//   (support.js, selectAt). A drag from a line selects layers (app.js,
//   rangeDrag; rangecard.js). Shift and a click add a part to the
//   selection of parts, or take it out (addPart), in each tool.
// - Move (the transform tool): a click selects a part, and the gizmo on
//   it moves, lifts, and turns it (gizmo.js). A drag on a part carries it
//   on the bed, with smart guides (Shift: no snap); the beads follow the
//   pointer on each frame, and the slice follows. The wheel over the view
//   turns the selected part by 15° a step. Ctrl and a drag move a part in
//   the other tools too.
// - Measure: a tape between two points. A click snaps to the end of the
//   nearest line (Shift: no snap). A click on a circle or an arc gives its
//   size, and the point is its center. A third click starts again; Esc
//   clears. The readout shows the distance, its parts along x, y and z,
//   and the distance on the bed. A drag of an end of the tape moves that
//   end (it snaps as a click does).
//
// The view of the page finds the points (zs_view_surface_point), and the
// worker has the parts and the measurements of the lines.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const HINT = "Click a point of the print, or a circle or an arc for its size and center. Shift: no snap.";

export const TOOLS = ["select", "move", "measure", "support"];

// zs_sel_mode.
const SEL_ADD = 1;
const SEL_TOGGLE = 2;

export class Tools {
  // ctx: { client, view (View3D), canvas, buttons {select, move, measure},
  //        readout (element), page() ("2d" or "3d"), layer() (the top
  //        layer), layerZ(l), view2d, select(path, seg, picked),
  //        requestFrame(), toast(text), partSelected(part or null),
  //        toolChanged(tool) }
  constructor(ctx) {
    this.ctx = ctx;
    this.sel = ctx.sel; // the selection model (selection.js)
    // The last facts of each part from the worker (zs_part), by stable
    // id: the name, the turn, and the scale. The model has the place.
    this.facts = new Map();
    // Grows with each change of the selection by the user. A reply that
    // selects parts checks it, so a late reply never undoes a newer click.
    this.stamp = 0;
    this.shownKey = "";
    this.pts = []; // { x, y, z, r, shape }
    this.moving = null; // a drag of parts: { list: [{ index, x0, y0, x, y }], bx0, by0 }
    this.moveSent = 0;
    // A click on the button of the tool that is on: the tool's own action
    // (the Support tool opens or closes its pane).
    for (const t of TOOLS) ctx.buttons[t].onclick = () => (t === this.tool && ctx.again ? ctx.again(t) : this.set(t));
    // The readout floats on the tape (a label at its middle), and in the
    // 2D view an overlay draws the tape itself (the 3D view draws it in
    // the core: zs_view_set_measure).
    const NS = "http://www.w3.org/2000/svg";
    this.overlay = document.createElementNS(NS, "svg");
    this.overlay.classList.add("tape-overlay");
    this.overlay.setAttribute("aria-hidden", "true");
    this.tapeLine = document.createElementNS(NS, "line");
    this.tapeEnds = [0, 1].map(() => document.createElementNS(NS, "circle"));
    for (const c of this.tapeEnds) c.setAttribute("r", "5");
    this.overlay.append(this.tapeLine, ...this.tapeEnds);
    this.label = document.createElement("div");
    this.label.className = "tape-label";
    this.label.hidden = true;
    ctx.canvas.parentElement.append(this.overlay, this.label);
    this.set("select");
  }

  // The tool is in the selection model.
  get tool() { return TOOLS[this.sel.tool] ?? "select"; }
  set tool(t) { this.sel.tool = Math.max(0, TOOLS.indexOf(t)); }

  // The selected parts, from the model: the facts of the worker with the
  // current index and place. `part` is the last of them (the card and the
  // tools of one part use it).
  get parts() { return this.sel.ids().map((id) => this.factsOf(id)).filter(Boolean); }
  get part() {
    const id = this.sel.primary;
    return id ? this.factsOf(id) : null;
  }

  // Part `id` as a zs_part of the worker, or null if it is not on the
  // plate.
  factsOf(id) {
    const b = this.sel.box(id);
    if (!b) return null;
    return {
      ...this.facts.get(id),
      id,
      index: this.sel.indexOf(id),
      x: (b.x0 + b.x1) / 2,
      y: (b.y0 + b.y1) / 2,
      z: b.z0,
      sizeX: b.x1 - b.x0,
      sizeY: b.y1 - b.y0,
      sizeZ: b.z1 - b.z0,
    };
  }

  // The parts of the plate that are not selected.
  otherParts() {
    const out = [];
    for (let i = 0; ; i++) {
      const id = this.sel.idAt(i);
      if (!id) return out;
      if (!this.sel.has(id)) out.push(this.factsOf(id));
    }
  }

  set(tool) {
    this.tool = tool;
    for (const t of TOOLS) this.ctx.buttons[t].classList.toggle("checked", t === tool);
    // The tape goes with its tool.
    if (tool !== "measure") this.clear(true);
    // The part stays selected for the Move tool.
    if (tool !== "move") this.selectPart(null);
    this.ctx.canvas.style.cursor = tool === "measure" || tool === "support" ? "crosshair" : "";
    this.ctx.toolChanged?.(tool);
    this.showReadout();
    // The rings of the Turn tool and the tape show after the next frame.
    this.ctx.requestFrame?.();
  }

  // ---- measure ----

  clear(quiet = false) {
    if (this.pts.length === 0 && quiet) return;
    this.pts = [];
    this.showTape();
    this.showReadout();
  }

  // A click of the measure tape at a device pixel. shift: no snap.
  async measureClick(px, py, shift) {
    const { view } = this.ctx;
    const w = view.w;
    let pt = null;
    let path = -1;
    let seg = 0;
    if (this.ctx.page() === "2d") {
      const v = this.ctx.view2d;
      const layer = this.ctx.layer();
      const x = (px - v.ox) / v.scale;
      const y = (this.ctx.canvas.height - py - v.oy) / v.scale;
      pt = [x, y, this.ctx.layerZ(layer)];
      if (view.pickLayer(layer, x, y)) [path, seg] = view.hit;
    } else {
      const c = w.cell;
      if (!view.x.zs_view_surface_point(view.v, px, py, shift ? 0 : 1, c)) return;
      pt = [w.f64(c), w.f64(c + 8), w.f64(c + 16)];
      if (view.pickSegment(px, py)) [path, seg] = view.hit;
    }
    // A circle or an arc under the pointer: the point is its center.
    if (!shift && path >= 0) {
      const r = await this.ctx.client.call("measureAt", { path, seg });
      const m = r.m;
      if (m && (m.shape === 1 || m.shape === 2)) {
        this.ctx.select(path, seg, false);
        this.add({ x: m.centerX, y: m.centerY, z: pt[2], r: m.radius, shape: m.shape });
        return;
      }
    }
    this.add({ x: pt[0], y: pt[1], z: pt[2], r: 0, shape: 0 });
  }

  // The pixel of a point of the tape in the view that shows, or null.
  pixelOf(p) {
    if (this.ctx.page() === "2d") {
      const v = this.ctx.view2d;
      return [v.ox + p.x * v.scale, this.ctx.canvas.height - (v.oy + p.y * v.scale)];
    }
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_pixel_of(view.v, p.x, p.y, p.z, c, c + 4)) return null;
    const f = new Float32Array(view.x.memory.buffer, c, 2);
    return [f[0], f[1]];
  }

  // The end of the tape within 14 CSS pixels of a device pixel, or -1.
  endAt(px, py, dpr) {
    let best = -1;
    let bestD = 14 * dpr;
    this.pts.forEach((p, i) => {
      const q = this.pixelOf(p);
      if (!q) return;
      const d = Math.hypot(q[0] - px, q[1] - py);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    });
    return best;
  }

  // A drag of end i of the tape to a device pixel. shift: no snap.
  dragEnd(i, px, py, shift) {
    const p = this.pts[i];
    if (!p) return;
    if (this.ctx.page() === "2d") {
      const v = this.ctx.view2d;
      p.x = (px - v.ox) / v.scale;
      p.y = (this.ctx.canvas.height - py - v.oy) / v.scale;
    } else {
      const { view } = this.ctx;
      const c = view.w.cell;
      if (!view.x.zs_view_surface_point(view.v, px, py, shift ? 0 : 1, c)) return;
      p.x = view.w.f64(c);
      p.y = view.w.f64(c + 8);
      p.z = view.w.f64(c + 16);
    }
    // A moved end is a point, not a center.
    p.r = 0;
    p.shape = 0;
    this.showTape();
    this.showReadout();
  }

  add(p) {
    // A third point starts a new measure.
    if (this.pts.length >= 2) this.pts = [];
    this.pts.push(p);
    this.showTape();
    this.showReadout();
  }

  // The label on the tape and the 2D tape: at the pixels of the points in
  // the view that shows now. app.js calls it after each frame, so it
  // follows the camera.
  placeTape() {
    const dpr = window.devicePixelRatio || 1;
    const pts = this.tool === "measure" ? this.pts.map((p) => this.pixelOf(p)) : [];
    const two = pts.length === 2 && pts[0] && pts[1];
    const flat = this.ctx.page() === "2d";
    this.overlay.style.display = flat && pts.length > 0 ? "" : "none";
    if (flat) {
      pts.forEach((q, i) => {
        const c = this.tapeEnds[i];
        c.style.display = q ? "" : "none";
        if (q) {
          c.setAttribute("cx", String(q[0] / dpr));
          c.setAttribute("cy", String(q[1] / dpr));
        }
      });
      for (let i = pts.length; i < 2; i++) this.tapeEnds[i].style.display = "none";
      this.tapeLine.style.display = two ? "" : "none";
      if (two) {
        this.tapeLine.setAttribute("x1", String(pts[0][0] / dpr));
        this.tapeLine.setAttribute("y1", String(pts[0][1] / dpr));
        this.tapeLine.setAttribute("x2", String(pts[1][0] / dpr));
        this.tapeLine.setAttribute("y2", String(pts[1][1] / dpr));
      }
    }
    if (!two) {
      this.label.hidden = true;
      return;
    }
    // Over the middle of the tape, a little above it.
    const x = (pts[0][0] + pts[1][0]) / 2 / dpr;
    const y = Math.min(pts[0][1], pts[1][1]) / dpr;
    const host = this.ctx.canvas.getBoundingClientRect();
    this.label.hidden = false;
    const w = this.label.offsetWidth;
    const h = this.label.offsetHeight;
    this.label.style.left = `${Math.max(6, Math.min(host.width - w - 6, x - w / 2))}px`;
    this.label.style.top = `${Math.max(6, Math.min(host.height - h - 6, y - h - 14))}px`;
  }

  // The tape in the 3D view (zs_view_set_measure).
  showTape() {
    const { view } = this.ctx;
    const n = this.pts.length;
    const a = new Float64Array(Math.max(n, 1) * 3);
    this.pts.forEach((p, i) => a.set([p.x, p.y, p.z], i * 3));
    view.w.withBytes(new Uint8Array(a.buffer), (ptr) => view.x.zs_view_set_measure(view.v, n, ptr));
    this.ctx.requestFrame();
  }

  showReadout() {
    const el = this.ctx.readout;
    if (this.tool !== "measure") {
      el.hidden = true;
      this.placeTape();
      return;
    }
    const m = this.pts;
    const shape = (p) => (p.r > 0 ? (p.shape === 1 ? `circle ⌀ ${(2 * p.r).toFixed(2)} mm (radius ${p.r.toFixed(2)})` : `arc radius ${p.r.toFixed(2)} mm`) : null);
    let text;
    if (m.length === 0) text = HINT;
    else if (m.length === 1) {
      const s = shape(m[0]);
      text = s
        ? `${s}, center ${m[0].x.toFixed(2)}, ${m[0].y.toFixed(2)} mm: click a second point to measure from its center.`
        : `From ${m[0].x.toFixed(2)}, ${m[0].y.toFixed(2)}, ${m[0].z.toFixed(2)} mm: click a second point.`;
    } else {
      const dx = m[1].x - m[0].x;
      const dy = m[1].y - m[0].y;
      const dz = m[1].z - m[0].z;
      const s0 = shape(m[0]);
      const s1 = shape(m[1]);
      text = `${Math.hypot(dx, dy, dz).toFixed(2)} mm${s0 || s1 ? " between the centers" : ""}   ·   ΔX ${Math.abs(dx).toFixed(2)}   ΔY ${Math.abs(dy).toFixed(2)}   ΔZ ${Math.abs(dz).toFixed(2)}   ·   on the bed ${Math.hypot(dx, dy).toFixed(2)} mm`;
      if (s0 || s1) text += `\nFirst: ${s0 ?? "a point"}   ·   second: ${s1 ?? "a point"}`;
      // The details go on the tape; the bar shows no copy of them.
      const big = document.createElement("div");
      big.className = "tape-dist";
      big.textContent = `${Math.hypot(dx, dy, dz).toFixed(2)} mm`;
      const small = document.createElement("div");
      small.className = "tape-parts";
      small.textContent = `ΔX ${Math.abs(dx).toFixed(2)} · ΔY ${Math.abs(dy).toFixed(2)} · ΔZ ${Math.abs(dz).toFixed(2)}${Math.abs(dz) > 0.005 ? ` · bed ${Math.hypot(dx, dy).toFixed(2)}` : ""}`;
      this.label.replaceChildren(big, small);
      if (s0 || s1) {
        const sh = document.createElement("div");
        sh.className = "tape-parts";
        sh.textContent = `between the centers · ${[s0, s1].filter(Boolean).join(" · ")}`;
        this.label.append(sh);
      }
      el.hidden = true;
      el.textContent = text;
      this.placeTape();
      return;
    }
    el.textContent = text;
    el.hidden = false;
    this.placeTape();
  }

  // ---- move ----

  // The bed point under a device pixel, or null.
  bedPoint(px, py) {
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_bed_point(view.v, px, py, c, c + 8)) return null;
    return [view.w.f64(c), view.w.f64(c + 8)];
  }

  // The part under a device pixel, at its current place, or null. The
  // core picks it (zs_sel_pick), with no reply of the worker, so a pick
  // works while a slice runs.
  partAt(px, py) {
    const id = this.sel.pick(this.ctx.view, px, py);
    if (!id) return null;
    this.fetchFacts([id]);
    return this.factsOf(id);
  }

  // Asks the worker for the facts of parts that the page does not have.
  fetchFacts(ids) {
    for (const id of ids) {
      // A part from the model alone has no scale yet.
      if (this.facts.get(id)?.scale) continue;
      const index = this.sel.indexOf(id);
      if (index < 0) continue;
      this.ctx.client.call("partGet", { index }).then((r) => r.part && this.updatePart(r.part));
    }
  }

  // Selects one part, or none (null). The selection of several parts
  // ends.
  selectPart(part) {
    this.setParts(part ? [part] : []);
  }

  // The selected parts: a list of zs_part. The model keeps their ids.
  setParts(list) {
    this.stamp++;
    this.keepFacts(list);
    this.sel.clear();
    for (const p of list) this.sel.select(this.idOf(p), SEL_ADD);
    this.fetchFacts(this.sel.ids());
    this.show(true);
  }

  // The stable id of a zs_part.
  idOf(p) { return p.id || this.sel.idAt(p.index); }

  keepFacts(list) {
    for (const p of list) {
      if (!p) continue;
      const id = this.idOf(p);
      if (id) this.facts.set(id, { ...this.facts.get(id), ...p, id });
    }
  }

  // Selects parts from the reply of a call, if the user changed nothing
  // since `stamp`.
  selectReply(list, stamp) {
    this.keepFacts(list);
    if (stamp === this.stamp) this.setParts(list);
    else this.show();
  }

  // The card and the frame show the model. The card opens again only for
  // a change (force: the user selected).
  show(force = false) {
    const list = this.parts;
    const key = list.map((p) => `${p.id}:${p.index}:${p.x}:${p.y}:${p.z}:${p.sizeX}:${p.sizeY}:${p.sizeZ}:${p.rotation}:${p.name}:${p.scale}`).join("|");
    if (!force && key === this.shownKey) return;
    this.shownKey = key;
    this.ctx.partSelected?.(list.length ? list[list.length - 1] : null, list);
    this.ctx.view.partBoxes(list.map((p) => [p.x - p.sizeX / 2, p.y - p.sizeY / 2, p.x + p.sizeX / 2, p.y + p.sizeY / 2]));
    this.ctx.requestFrame();
  }

  // The table of the parts changed (the "parts" event): a selected part
  // that is gone left the model. Its facts come again from the worker.
  tableChanged() {
    const ids = new Set(this.sel.ids());
    for (const id of this.facts.keys()) if (this.sel.indexOf(id) < 0) this.facts.delete(id);
    if (!this.moving && !this.ctx.gizmo?.()?.drag) {
      for (const id of ids) {
        const index = this.sel.indexOf(id);
        this.ctx.client.call("partGet", { index }).then((r) => r.part && this.updatePart(r.part));
      }
    }
    this.show();
  }

  // Shift and a click: the part goes into the selection, or out of it if
  // it is in it. A click on no part keeps the selection.
  togglePart(part) {
    if (!part) return;
    this.stamp++;
    this.keepFacts([part]);
    this.sel.select(this.idOf(part), SEL_TOGGLE);
    this.show(true);
  }

  // New facts of a part from a reply. The selection stays as it is.
  updatePart(part) {
    this.keepFacts([part]);
    this.show();
  }

  updateParts(list) {
    this.keepFacts(list.filter(Boolean));
    this.show();
  }

  // A local change of the place of a part: the model has it at once.
  placePart(id, x, y, z) {
    this.sel.place(id, x, y, z);
    this.show();
  }

  // A press of a drag that can move a part: true if a part is there (the
  // drag then moves it). A press on a part of a selection of several
  // parts moves them all.
  // One part: the gizmo carries it (gizmo.js: the snap, the preview, and
  // the live slice).
  async moveStart(px, py) {
    const part = this.partAt(px, py);
    if (!part) return false;
    // The level plane of the point that the pointer took: that point
    // stays under the pointer (also for a part that floats).
    const { view } = this.ctx;
    const c = view.w.cell;
    const hz = view.x.zs_view_surface_point(view.v, px, py, 0, c) ? Math.max(0, view.w.f64(c + 16)) : 0;
    const bed = this.planePoint(px, py, hz);
    if (!bed) return false;
    const group = this.parts.length > 1 && this.parts.some((p) => p.index === part.index);
    if (!group) this.selectPart(part);
    const list = group ? this.parts : [part];
    this.moving = { list: list.map((p) => ({ id: p.id, index: p.index, z: p.z ?? 0, x0: p.x, y0: p.y, x: p.x, y: p.y })), bx0: bed[0], by0: bed[1], hz, one: !group && this.ctx.gizmo?.() };
    if (this.moving.one) this.moving.one.beginLive(part);
    this.ctx.canvas.style.cursor = "move";
    return true;
  }

  // The point on the level plane at height z under a device pixel, or
  // null.
  planePoint(px, py, z) {
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_plane_point(view.v, px, py, z, c, c + 8)) return null;
    return [view.w.f64(c), view.w.f64(c + 8)];
  }

  // The parts follow the point under the pointer. One part: the gizmo
  // moves its beads at once, and the slice follows. Several parts: the
  // boxes show at once, and the worker gets at most one move each 60 ms.
  moveTo(px, py, shift = false, ev = null) {
    const m = this.moving;
    const bed = m && this.planePoint(px, py, m.hz);
    if (!bed) return;
    const dx = bed[0] - m.bx0;
    const dy = bed[1] - m.by0;
    if (m.one) {
      const t = m.one.bodyMove(dx, dy, shift, ev);
      if (t) {
        m.list[0].x = t.x;
        m.list[0].y = t.y;
      }
      return;
    }
    for (const q of m.list) {
      q.x = q.x0 + dx;
      q.y = q.y0 + dy;
    }
    for (const q of m.list) this.placePart(q.id, q.x, q.y, q.z);
    const now = performance.now();
    if (now - this.moveSent > 60) {
      this.moveSent = now;
      // The slice waits for the end of the drag (moveEnd).
      this.sendMove(m, true);
    }
  }

  sendMove(m, hold) {
    if (m.list.length === 1) {
      const q = m.list[0];
      return this.ctx.client.call("partMove", { index: q.index, x: q.x, y: q.y, hold }).then((r) => ({ parts: [r.part] }));
    }
    return this.ctx.client.call("partsMove", { moves: m.list.map((q) => ({ index: q.index, x: q.x, y: q.y })), hold });
  }

  async moveEnd() {
    const m = this.moving;
    this.moving = null;
    this.ctx.canvas.style.cursor = this.tool === "measure" ? "crosshair" : "";
    if (!m) return;
    if (m.one) {
      await m.one.endLive();
      return;
    }
    const r = await this.sendMove(m, false);
    if (r.parts) this.updateParts(r.parts);
  }

  // A click with the move tool (or Ctrl): select the part there, or none.
  async pickPart(px, py) {
    this.selectPart(this.partAt(px, py));
  }

  // Shift and a click: add the part there to the selection, or take it
  // out.
  async addPart(px, py) {
    this.togglePart(this.partAt(px, py));
  }

  // The wheel with the move tool (or Ctrl): turn the selected part 15° a
  // step. Returns true if it turned.
  async turn(dir) {
    if (!this.part) return false;
    const r = await this.ctx.client.call("partRotate", { index: this.part.index, step: dir > 0 ? -15 : 15 });
    if (r.part) this.updatePart(r.part);
    return true;
  }
}
