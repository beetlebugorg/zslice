// tools.js: the tools of the preview (linux/src/ui/preview.c, tool_group;
// view3d.c): Select (S), Move (M), and Measure (T), as a group at the left
// of the toolbar.
//
// - Select: a click selects a line (app.js does it).
// - Move: a drag on a part moves it on the bed, and the wheel over the view
//   turns the selected part by 15° a step. Ctrl does the same in the other
//   tools.
// - Measure: a tape between two points. A click snaps to the end of the
//   nearest line (Shift: no snap). A click on a circle or an arc gives its
//   size, and the point is its center. A third click starts again; Esc
//   clears. The readout shows the distance, its parts along x, y and z,
//   and the distance on the bed.
//
// The view of the page finds the points (zs_view_surface_point), and the
// worker has the parts and the measurements of the lines.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const HINT = "Click a point of the print, or a circle or an arc for its size and center. Shift: no snap.";

export const TOOLS = ["select", "move", "measure"];

export class Tools {
  // ctx: { client, view (View3D), canvas, buttons {select, move, measure},
  //        readout (element), page() ("2d" or "3d"), layer() (the top
  //        layer), layerZ(l), view2d, select(path, seg, picked),
  //        requestFrame(), toast(text) }
  constructor(ctx) {
    this.ctx = ctx;
    this.tool = "select";
    this.pts = []; // { x, y, z, r, shape }
    this.part = null; // the selected part (zs_part of the worker)
    this.moving = null; // a drag of a part: { index, x0, y0, bx0, by0 }
    this.moveSent = 0;
    for (const t of TOOLS) ctx.buttons[t].onclick = () => this.set(t);
    this.set("select");
  }

  set(tool) {
    this.tool = tool;
    for (const t of TOOLS) this.ctx.buttons[t].classList.toggle("checked", t === tool);
    // The tape goes with its tool.
    if (tool !== "measure") this.clear(true);
    if (tool !== "move") this.selectPart(null);
    this.ctx.canvas.style.cursor = tool === "measure" ? "crosshair" : "";
    this.showReadout();
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

  add(p) {
    // A third point starts a new measure.
    if (this.pts.length >= 2) this.pts = [];
    this.pts.push(p);
    this.showTape();
    this.showReadout();
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
    }
    el.textContent = text;
    el.hidden = false;
  }

  // ---- move ----

  // The bed point under a device pixel, or null.
  bedPoint(px, py) {
    const { view } = this.ctx;
    const c = view.w.cell;
    if (!view.x.zs_view_bed_point(view.v, px, py, c, c + 8)) return null;
    return [view.w.f64(c), view.w.f64(c + 8)];
  }

  // The part under a device pixel (its line, or its footprint), or null.
  async partAt(px, py) {
    const { view } = this.ctx;
    const path = view.x.zs_view_pick(view.v, px, py);
    const bed = this.bedPoint(px, py);
    const r = await this.ctx.client.call("partAt", { path: path >= 0 ? path : -1, bed: !!bed, x: bed?.[0] ?? 0, y: bed?.[1] ?? 0 });
    return r.part;
  }

  selectPart(part) {
    this.part = part;
    const { view } = this.ctx;
    if (part) view.x.zs_view_part_box(view.v, part.x - part.sizeX / 2, part.y - part.sizeY / 2, part.x + part.sizeX / 2, part.y + part.sizeY / 2);
    else view.x.zs_view_part_box(view.v, 0, 0, 0, 0);
    this.ctx.requestFrame();
  }

  // A press of a drag that can move a part: true if a part is there (the
  // drag then moves it).
  async moveStart(px, py) {
    const part = await this.partAt(px, py);
    const bed = this.bedPoint(px, py);
    if (!part || !bed) return false;
    this.selectPart(part);
    this.moving = { index: part.index, x0: part.x, y0: part.y, bx0: bed[0], by0: bed[1], x: part.x, y: part.y };
    this.ctx.canvas.style.cursor = "move";
    return true;
  }

  // The part follows the bed point under the pointer. The box shows at
  // once; the worker gets at most one move each 60 ms.
  moveTo(px, py) {
    const m = this.moving;
    const bed = m && this.bedPoint(px, py);
    if (!bed) return;
    m.x = m.x0 + bed[0] - m.bx0;
    m.y = m.y0 + bed[1] - m.by0;
    if (this.part) this.selectPart({ ...this.part, x: m.x, y: m.y });
    const now = performance.now();
    if (now - this.moveSent > 60) {
      this.moveSent = now;
      this.ctx.client.call("partMove", { index: m.index, x: m.x, y: m.y });
    }
  }

  async moveEnd() {
    const m = this.moving;
    this.moving = null;
    this.ctx.canvas.style.cursor = this.tool === "measure" ? "crosshair" : "";
    if (!m) return;
    const r = await this.ctx.client.call("partMove", { index: m.index, x: m.x, y: m.y });
    if (r.part) this.selectPart(r.part);
  }

  // A click with the move tool (or Ctrl): select the part there, or none.
  async pickPart(px, py) {
    this.selectPart(await this.partAt(px, py));
  }

  // The wheel with the move tool (or Ctrl): turn the selected part 15° a
  // step. Returns true if it turned.
  async turn(dir) {
    if (!this.part) return false;
    const r = await this.ctx.client.call("partRotate", { index: this.part.index, step: dir > 0 ? -15 : 15 });
    if (r.part) this.selectPart(r.part);
    return true;
  }
}
