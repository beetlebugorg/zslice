// label.js: the Label tool (L). It puts labels on the surface of a part:
// text, a line, a bar, a ring, the ticks of a dial, or a free line, each
// in a filament of its own. The slice prints a label flush in the outer
// skin of the part (docs/embedding/labels.md).
//
// - A click on a face of a part adds a label there ("LABEL", 5 mm), in
//   the filament after the filament of the part. A click on a label
//   selects it, and its card opens (labelcard.js).
// - A drag of a label moves it on the surface; Shift keeps its plane.
//   The wheel over the selected label turns it 1° a step (Shift: 15°).
//   The handle at its corner scales it; the round handle over it turns
//   it. Delete removes it.
// - The view keeps the beads. The labels of the part show as decals on
//   its surface (gl.js, setLabels): the outline of each label comes from
//   the core (zs_label_outline) with no slice, so a drag, a turn, or a key
//   in the text field draws at once. The end of a change sends the label
//   to the worker (zs_app_label_update), and it slices.
//
// The pick uses the mesh of the part in a paint session of the view
// (zs_paint_new, zs_label_place), on this thread.
//
// The top part of this file is the model of a label (its JSON, its frame,
// and its shapes) with no DOM, for the Node test.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { filaments } from "./filaments.js";

// ---- the model ----

export const SHAPES = ["text", "line", "bar", "ring", "ticks", "polyline"];
export const SHAPE_NAMES = { text: "Text", line: "Line", bar: "Bar", ring: "Ring", ticks: "Ticks", polyline: "Free" };
// The face curves more than this under a label: the label stretches.
export const CURVE_LIMIT = 60;
export const CURVE_TEXT = "The face curves too much here; the label stretches.";

// A new item of a shape. size: the size of the label (the cap height of
// its text), mm.
export function newItem(kind, size = 5) {
  switch (kind) {
    case "text": return { kind, text: "LABEL", size };
    case "line": return { kind, length: 4 * size, width: 1 };
    case "bar": return { kind, width: 4 * size, height: Math.max(1, 0.4 * size), radius: 0 };
    case "ring": return { kind, outer: size, inner: Math.max(0, size - 1) };
    case "ticks": return { kind, count: 11, radius: 1.6 * size, length: 0.3 * size, length_end: 0.6 * size, width: 0.8, start: 225, sweep: -270 };
    case "polyline": return { kind, points: [[-2 * size, -size / 2], [0, size / 2], [2 * size, -size / 2]], width: 1, closed: false, filled: false };
  }
  throw new Error(`no shape ${kind}`);
}

// An item of another shape at the same place, with about the same size.
export function changeShape(item, kind) {
  if (item.kind === kind) return item;
  const out = newItem(kind, Math.max(0.5, itemSize(item) / (item.kind === "text" ? 1 : item.kind === "ring" ? 2 : 4)));
  if (item.at) out.at = item.at.slice();
  if (item.angle) out.angle = item.angle;
  return out;
}

// The fields of each shape that are lengths (a scale changes them).
const LENGTHS = {
  text: ["size", "spacing"],
  line: ["length", "width"],
  bar: ["width", "height", "radius"],
  ring: ["outer", "inner"],
  ticks: ["radius", "length", "length_end", "width"],
  polyline: ["width"],
};

// The size of an item for the card, mm: the cap height of a text, the
// length of a line, the width of a bar, the diameter of a ring, the
// outer diameter of the ticks, the width of a free line.
export function itemSize(it) {
  switch (it.kind) {
    case "text": return it.size;
    case "line": return it.length;
    case "bar": return it.width;
    case "ring": return 2 * it.outer;
    case "ticks": return 2 * (it.radius + Math.max(it.length, it.length_end || 0));
    case "polyline": {
      const xs = it.points.map((p) => p[0]);
      return Math.max(...xs) - Math.min(...xs);
    }
  }
  return 0;
}

// The item scaled by k: its lengths, its place, and its points.
export function scaleItem(it, k) {
  const out = { ...it };
  for (const f of LENGTHS[it.kind] ?? []) if (typeof out[f] === "number") out[f] *= k;
  if (it.at) out.at = [it.at[0] * k, it.at[1] * k];
  if (it.points) out.points = it.points.map(([x, y]) => [x * k, y * k]);
  return out;
}

export function scaleLabel(label, k) {
  return { ...label, items: label.items.map((it) => scaleItem(it, k)) };
}

// The words of a label for a list: its text, or the names of its shapes.
export function labelName(label) {
  if (label.name) return label.name;
  const text = label.items.find((it) => it.kind === "text" && it.text.trim());
  if (text) return `“${text.text.trim()}”`;
  const kinds = [...new Set(label.items.map((it) => SHAPE_NAMES[it.kind]))];
  return kinds.length > 0 ? kinds.join(" and ") : "Empty label";
}

// ---- the frame: vectors of 3 numbers ----

const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const add = (a, b, k = 1) => [a[0] + k * b[0], a[1] + k * b[1], a[2] + k * b[2]];
function unit(a) {
  const l = Math.hypot(a[0], a[1], a[2]);
  return l > 1e-9 ? [a[0] / l, a[1] / l, a[2] / l] : null;
}

export function upOf(label) {
  return cross(label.normal, label.right);
}

// The right of a label with a turn of 0 at a normal: level on a side face
// (|normal.z| <= 0.7: Z x normal, as zs_label_place gives it), else the
// X axis of the bed in the plane.
export function levelRight(n) {
  if (Math.abs(n[2]) <= 0.7) return unit([-n[1], n[0], 0]) ?? [1, 0, 0];
  return unit(add([1, 0, 0], n, -n[0])) ?? unit(add([0, 1, 0], n, -n[1]));
}

// The turn of a label in its plane from its level right, degrees.
export function angleOf(label) {
  const ref = levelRight(label.normal);
  const refUp = cross(label.normal, ref);
  return (Math.atan2(dot(label.right, refUp), dot(label.right, ref)) * 180) / Math.PI;
}

// The label with the turn `deg` from its level right.
export function withAngle(label, deg) {
  const a = (deg * Math.PI) / 180;
  const ref = levelRight(label.normal);
  const refUp = cross(label.normal, ref);
  return { ...label, right: unit(add(ref.map((v) => v * Math.cos(a)), refUp, Math.sin(a))) };
}

// The label turned by `deg` around its normal (counterclockwise from the
// front).
export function turned(label, deg) {
  const a = (deg * Math.PI) / 180;
  const up = upOf(label);
  return { ...label, right: unit(add(label.right.map((v) => v * Math.cos(a)), up, Math.sin(a))) };
}

// The label at a new point and normal of the surface. Its right keeps its
// direction, put into the new plane (else the level right).
export function moved(label, origin, normal) {
  const n = unit(normal) ?? label.normal;
  const r = unit(add(label.right, n, -dot(label.right, n))) ?? levelRight(n);
  return { ...label, origin: origin.slice(), normal: n, right: r };
}

// The point of the plane of a label on a ray (origin o, direction d), as
// { p (bed frame), x, y (mm along right and up) }, or null.
export function planeHit(label, o, d) {
  const n = label.normal;
  const den = dot(d, n);
  if (Math.abs(den) < 1e-9) return null;
  const t = dot(add(label.origin, o, -1), n) / den;
  if (!(t > 0)) return null;
  const p = add(o, d, t);
  const v = add(p, label.origin, -1);
  return { p, x: dot(v, label.right), y: dot(v, upOf(label)) };
}

// A point (x, y) of the plane of a label in the frame of the bed, `lift`
// mm out of the surface.
export function toBed(label, x, y, lift = 0) {
  const up = upOf(label);
  const o = label.origin;
  const r = label.right;
  const n = label.normal;
  return [o[0] + x * r[0] + y * up[0] + lift * n[0], o[1] + x * r[1] + y * up[1] + lift * n[1], o[2] + x * r[2] + y * up[2] + lift * n[2]];
}

// The JSON of the shapes of a label for zs_label_outline: its items and
// its stretch, with no frame.
export function shapeJson(label) {
  const o = { items: label.items };
  if (label.stretch) o.stretch = label.stretch;
  return JSON.stringify(o);
}

// The outline of the shapes of a label in its plane (zs_label_outline):
// { pts (Float32Array of x, y), ends (Uint32Array), box [x0, y0, x1, y1] },
// or null for a bad label (the status in `error`). w: a Wasm.
export function outlineOf(w, label) {
  const bytes = new TextEncoder().encode(shapeJson(label));
  const c = w.cell;
  const rc = w.withBytes(bytes, (p, n) => w.x.zs_label_outline(p, n, c, c + 4, c + 8));
  if (rc !== 0) return null;
  const pp = w.u32(c);
  const ep = w.u32(c + 4);
  const n = w.u32(c + 8);
  const ends = new Uint32Array(w.x.memory.buffer, ep, n).slice();
  const count = n > 0 ? ends[n - 1] : 0;
  const pts = new Float32Array(w.x.memory.buffer, pp, 2 * count).slice();
  const box = [Infinity, Infinity, -Infinity, -Infinity];
  for (let i = 0; i < count; i++) {
    box[0] = Math.min(box[0], pts[2 * i]);
    box[1] = Math.min(box[1], pts[2 * i + 1]);
    box[2] = Math.max(box[2], pts[2 * i]);
    box[3] = Math.max(box[3], pts[2 * i + 1]);
  }
  if (count === 0) box.splice(0, 4, 0, 0, 0, 0);
  return { pts, ends, box };
}

// The frame of a label at a ray of the view (zs_label_place) on a paint
// session `s`: { origin, normal, right, curve (degrees) }, or null.
export function placeAt(w, s, ray, radius = 5) {
  const c = w.alloc(24 + 80);
  try {
    new Float32Array(w.x.memory.buffer, c, 6).set(ray);
    const out = c + 24;
    if (!w.x.zs_label_place(s, c, radius, out)) return null;
    const f = new Float64Array(w.x.memory.buffer, out, 10);
    return { origin: [f[0], f[1], f[2]], normal: [f[3], f[4], f[5]], right: [f[6], f[7], f[8]], curve: f[9] };
  } finally {
    w.free(c, 24 + 80);
  }
}

// The filament of a new label on a part in filament `base` (from 1), with
// `count` filaments on the plate: the filament after it, else the first
// other one. With one filament: 1 (the card offers to add one).
export function nextFilament(base, count) {
  if (count <= 1) return 1;
  if (base + 1 <= count) return base + 1;
  return base === 1 ? 2 : 1;
}

function rgb(hex) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || "");
  if (!m) return [0.82, 0.82, 0.8];
  return m.slice(1).map((h) => parseInt(h, 16) / 255);
}

// ---- the tool ----

// The lift of the decal out of the surface, mm.
const LIFT = 0.05;
// The pause after the last change of a label before it goes to the
// worker: a turn with the wheel or keys in the text field are one step.
const COMMIT_MS = 400;

export class LabelTool {
  // ctx: { client, view (View3D), gl (GlRenderer), canvas, host (the
  //        element of the view), button (the tool button), Card (the
  //        class of the card, labelcard.js), part() (the selected part,
  //        or -1), partAt(px, py) -> Promise<zs_part or null> (device
  //        pixels), pixelOf({x, y, z}) -> device pixels or null,
  //        page() ("2d" or "3d"), requestFrame(), toast(text),
  //        addFilament() -> Promise<index>, opened() (the tool opens) }
  constructor(ctx) {
    this.ctx = ctx;
    this.on = false;
    this.index = -1; // the part of the labels that show
    this.base = 1; // the filament of that part
    this.labels = [];
    this.sel = -1; // the id of the selected label
    this.curve = 0; // the curve of the face under the selected label
    this.info = null; // zs_app_label_info of the selected label
    this.shapes = new Map(); // id -> { key, outline }
    this.sessions = new Map(); // part index -> zs_paint session
    this.drag = null;
    this.drawing = -1; // the item that gets the points of clicks
    this.timer = 0;
    this.pending = -1; // the label with a change that waits (see change)
    this.card = null;
    this.handle = null;
    this.attach();
  }

  get w() {
    return this.ctx.view.w;
  }

  get label() {
    return this.labels.find((l) => l.id === this.sel) ?? null;
  }

  toggle() {
    if (this.on) this.close();
    else this.open();
  }

  async open(index = this.ctx.part(), id = -1) {
    if (!this.on) {
      this.on = true;
      this.ctx.button?.classList.add("on");
      this.ctx.canvas.style.cursor = "crosshair";
      this.ctx.opened?.();
      if (id < 0) this.ctx.toast("Click a face of a part to put a label there. Drag a label to move it; the wheel turns it.");
    }
    if (index >= 0) await this.load(index, id);
  }

  close() {
    if (!this.on) return;
    this.flush();
    this.on = false;
    this.ctx.button?.classList.remove("on");
    this.ctx.canvas.style.cursor = "";
    this.freeSessions();
    this.labels = [];
    this.index = -1;
    this.select(-1);
    this.ctx.gl.setLabels(null);
    this.ctx.requestFrame();
  }

  freeSessions() {
    for (const s of this.sessions.values()) this.w.x.zs_paint_free(s);
    this.sessions.clear();
    this.poses?.clear();
  }

  // The labels of part `index` from the worker. id: the label to select
  // (-1: keep the selection if the label is still there).
  async load(index, id = -1) {
    const r = await this.ctx.client.call("labelsGet", { index });
    if (!this.on) return;
    // A part at another place or size needs a new pick mesh; else the
    // mesh stays (it took the most time of a new label).
    this.poses ??= new Map();
    if (this.poses.get(index) !== r.pose) {
      const s = this.sessions.get(index);
      if (s) this.w.x.zs_paint_free(s);
      this.sessions.delete(index);
      this.poses.set(index, r.pose);
    }
    if (index !== this.index) this.select(-1);
    // A change that waits for its pause keeps its values.
    const keep = index === this.index && this.pending >= 0 ? this.labels.find((l) => l.id === this.pending) : null;
    this.index = index;
    this.labels = (r.labels ?? []).map((l) => (keep && l.id === keep.id ? keep : l));
    this.base = r.filament ?? 1;
    if (id >= 0) this.select(id);
    else if (!this.label) this.select(-1);
    else this.refreshCard();
    this.redraw();
    // The pick mesh now, so the first click on the part is quick.
    this.session(index);
  }

  // After an undo, a slice, or another plate: the labels again, and a
  // new mesh for the pick (the part can be at another place).
  async reload() {
    if (!this.on || this.drag) return;
    // load() makes a new pick mesh only if the part moved or changed size.
    if (this.index >= 0) await this.load(this.index);
    this.loadInfo();
  }

  // The paint session of the mesh of part `index`, for the pick.
  async session(index) {
    const have = this.sessions.get(index);
    if (have) return have;
    const r = await this.ctx.client.call("paintOpen", { index });
    if (r.error || !r.faces?.length) return 0;
    const w = this.w;
    const vp = w.alloc(r.verts.byteLength);
    const fp = w.alloc(r.faces.byteLength);
    try {
      new Float32Array(w.x.memory.buffer, vp, r.verts.length).set(r.verts);
      new Uint32Array(w.x.memory.buffer, fp, r.faces.length).set(r.faces);
      if (w.x.zs_paint_new(vp, r.verts.length / 3, fp, r.faces.length / 3, w.cell) !== 0) return 0;
    } finally {
      w.free(vp, r.verts.byteLength);
      w.free(fp, r.faces.byteLength);
    }
    const s = w.u32(w.cell);
    // Another call could have made one in the meantime.
    const other = this.sessions.get(index);
    if (other) {
      w.x.zs_paint_free(s);
      return other;
    }
    this.sessions.set(index, s);
    return s;
  }

  // The ray of the view at a CSS pixel of the canvas: [o, d] or null.
  ray(px, py) {
    const w = this.w;
    const dpr = window.devicePixelRatio || 1;
    const c = w.cell;
    if (!w.x.zs_view_ray(this.ctx.view.v, px * dpr, py * dpr, c)) return null;
    const f = new Float32Array(w.x.memory.buffer, c, 6);
    return [Array.from(f.subarray(0, 3)), Array.from(f.subarray(3, 6))];
  }

  // The outline of a label, made again only when its shapes change.
  outline(label) {
    const key = shapeJson(label);
    const have = this.shapes.get(label.id);
    if (have && have.key === key) return have.outline;
    const outline = outlineOf(this.w, label);
    if (outline) this.shapes.set(label.id, { key, outline });
    return outline ?? have?.outline ?? null;
  }

  // The label under a CSS pixel: { label, x, y } (the point in its plane),
  // or null. The selected label first.
  labelAt(px, py) {
    const r = this.ray(px, py);
    if (!r) return null;
    const order = [...this.labels].sort((a, b) => (b.id === this.sel) - (a.id === this.sel));
    for (const l of order) {
      const o = this.outline(l);
      if (!o) continue;
      const h = planeHit(l, r[0], r[1]);
      const m = 1;
      if (h && h.x >= o.box[0] - m && h.x <= o.box[2] + m && h.y >= o.box[1] - m && h.y <= o.box[3] + m) return { label: l, x: h.x, y: h.y };
    }
    return null;
  }

  // The decals of the labels of the part to the GPU.
  redraw() {
    const list = [];
    const fil = filaments();
    for (const l of this.labels) {
      const o = this.outline(l);
      if (!o) continue;
      const n = o.pts.length / 2;
      const pts = new Float32Array(3 * n);
      const up = upOf(l);
      for (let i = 0; i < n; i++) {
        const x = o.pts[2 * i];
        const y = o.pts[2 * i + 1];
        for (let k = 0; k < 3; k++) pts[3 * i + k] = l.origin[k] + x * l.right[k] + y * up[k] + LIFT * l.normal[k];
      }
      const color = rgb(fil[l.filament - 1]?.color ?? fil[0]?.color);
      // The outline of the selected label in a color that stands out of
      // its fill.
      const light = 0.3 * color[0] + 0.59 * color[1] + 0.11 * color[2];
      const edge = l.id === this.sel ? (light > 0.5 ? [0.1, 0.1, 0.12] : [1, 0.85, 0.2]) : null;
      list.push({ pts, ends: o.ends, color, edge });
    }
    this.ctx.gl.setLabels(list);
    this.ctx.requestFrame();
  }

  // ---- the selection and the card ----

  select(id) {
    if (id !== this.sel) {
      this.flush();
      this.drawing = -1;
    }
    this.sel = id;
    const l = this.label;
    if (!l) {
      this.sel = -1;
      this.info = null;
      this.curve = 0;
      this.card?.close();
      this.card = null;
      this.handle?.remove();
      this.handle = null;
      this.turnHandle?.remove();
      this.turnHandle = null;
      this.redraw();
      return;
    }
    if (!this.card) this.card = new this.ctx.Card(this, this.ctx.host);
    this.card.show(l);
    this.makeHandle();
    this.redraw();
    this.loadInfo();
  }

  refreshCard() {
    if (this.card && this.label) this.card.refresh(this.label);
  }

  async loadInfo() {
    const l = this.label;
    if (!l) return;
    const r = await this.ctx.client.call("labelInfo", { index: this.index, labelId: l.id });
    if (this.sel !== l.id) return;
    this.info = r.info;
    this.card?.showInfo(this.info);
  }

  // ---- the changes ----

  // A change of the selected label: the preview at once, and the worker
  // after a pause (commit: at once).
  change(fn, commit = false) {
    const l = this.label;
    if (!l) return false;
    const next = fn(l);
    if (!next) return false;
    // A bad shape (a field out of range): the label stays.
    if (shapeJson(next) !== shapeJson(l) && !outlineOf(this.w, next)) return false;
    Object.assign(l, next);
    this.redraw();
    this.card?.update(l);
    clearTimeout(this.timer);
    this.pending = l.id;
    // A drag sends the label at its end (one step of the history).
    if (commit) this.flush();
    else if (!this.drag && !this.scaling) this.timer = setTimeout(() => this.flush(), COMMIT_MS);
    return true;
  }

  // Sends the pending change of the selected label to the worker.
  async flush() {
    clearTimeout(this.timer);
    const id = this.pending;
    this.pending = -1;
    if (id < 0) return;
    const l = this.labels.find((x) => x.id === id);
    if (!l) return;
    const r = await this.ctx.client.call("labelUpdate", { index: this.index, labelId: id, label: l });
    if (!r.ok) this.ctx.toast("The label did not change: a value is out of range.");
    this.loadInfo();
  }

  editItem(i, patch) {
    return this.change((l) => {
      const items = l.items.slice();
      items[i] = { ...items[i], ...patch };
      return { ...l, items };
    });
  }

  setShape(i, kind) {
    this.change((l) => {
      const items = l.items.slice();
      items[i] = changeShape(items[i], kind);
      return { ...l, items };
    }, true);
    this.card?.show(this.label);
  }

  // A new item in the label: under the items that are there (ticks go
  // around the center, under the text).
  addItem(kind) {
    this.change((l) => {
      const o = this.outline(l);
      const size = l.items.find((it) => it.kind === "text")?.size ?? 5;
      const it = newItem(kind, size);
      if (kind === "ticks" || kind === "ring") {
        const r = kind === "ticks" ? it.radius + it.length_end : it.outer;
        it.at = [0, (o ? o.box[1] : 0) - r - 1];
      } else if (o && l.items.length > 0) it.at = [0, o.box[1] - size];
      return { ...l, items: [...l.items, it] };
    }, true);
    this.card?.show(this.label);
  }

  removeItem(i) {
    this.change((l) => (l.items.length > 1 ? { ...l, items: l.items.filter((_, k) => k !== i) } : null), true);
    this.card?.show(this.label);
  }

  setFilament(n) {
    this.change((l) => ({ ...l, filament: n }), true);
  }

  setDepth(mm) {
    this.change((l) => ({ ...l, depth: Math.max(0, Math.min(10, mm)) }), true);
  }

  setAngle(deg) {
    this.change((l) => withAngle(l, deg));
  }

  turn(deg) {
    this.change((l) => turned(l, deg));
  }

  scale(k) {
    this.change((l) => scaleLabel(l, k));
  }

  async addFilament() {
    const i = await this.ctx.addFilament();
    if (i >= 0) this.setFilament(i + 1);
    this.card?.show(this.label);
  }

  async remove() {
    const l = this.label;
    if (!l) return;
    clearTimeout(this.timer);
    this.pending = -1;
    const r = await this.ctx.client.call("labelRemove", { index: this.index, labelId: l.id });
    this.labels = r.labels ?? this.labels.filter((x) => x.id !== l.id);
    this.shapes.delete(l.id);
    this.select(-1);
  }

  // ---- copy and paste (clipboard.js) ----

  // A copy of the selected label for the clipboard (no id), or null.
  copyLabel() {
    const l = this.label;
    if (!l) return null;
    const out = JSON.parse(JSON.stringify(l));
    delete out.id;
    return out;
  }

  // Pastes a copy of label `src`. With a pixel (px, py, CSS pixels) on a
  // face of a part: there, with the same turn. Else on the part of the
  // tool (or `part`), under the label of the copy on the same face. One
  // call to the worker: one step of the history. Returns true for a new
  // label.
  async pasteLabel(src, px = null, py = null, part = -1) {
    if (!this.on) await this.open(-1, 0);
    const dpr = window.devicePixelRatio || 1;
    let at = null;
    let index = this.index >= 0 ? this.index : part;
    if (px != null) {
      const hit = await this.ctx.partAt(px * dpr, py * dpr);
      if (hit) {
        if (hit.index !== this.index) await this.load(hit.index);
        index = hit.index;
        const s = await this.session(hit.index);
        const r = this.ray(px, py);
        at = s && r ? placeAt(this.w, s, [...r[0], ...r[1]]) : null;
      }
    }
    if (index < 0) {
      this.ctx.toast("Point at a part to paste the label there.");
      return false;
    }
    if (index !== this.index) await this.load(index);
    let label;
    if (at) {
      label = withAngle({ ...src, origin: at.origin, normal: at.normal, right: at.right }, angleOf(src));
      this.curve = at.curve;
    } else {
      // Under the label of the copy: its height and 1 mm lower, on the
      // surface again (a ray in along the normal).
      const o = this.outline(src);
      const h = o ? o.box[3] - o.box[1] : 5;
      const down = add(src.origin, upOf(src), -(h + 1));
      label = { ...src, origin: down };
      const s = await this.session(index);
      const from = add(down, src.normal, 5);
      const p = s ? placeAt(this.w, s, [...from, ...src.normal.map((v) => -v)]) : null;
      if (p) label = moved(label, p.origin, p.normal);
    }
    const res = await this.ctx.client.call("labelAdd", { index, label });
    if (!(res.id >= 0)) {
      this.ctx.toast("The label does not fit here.");
      return false;
    }
    this.labels = res.labels;
    this.select(res.id);
    this.redraw();
    return true;
  }

  // A click on no label of the loaded part: first the labels of the part
  // under the pointer (it can be another part, or the labels came after
  // the tool opened), then a label there is selected; else a new one.
  async missAt(px, py) {
    const dpr = window.devicePixelRatio || 1;
    const part = await this.ctx.partAt(px * dpr, py * dpr);
    if (part && this.on && part.index !== this.index) await this.load(part.index);
    const hit = this.labelAt(px, py);
    if (hit) {
      this.select(hit.label.id);
      return;
    }
    await this.addAt(px, py, part);
  }

  // A new label at a pixel of the view: on the face of the part there.
  async addAt(px, py, known = undefined) {
    const dpr = window.devicePixelRatio || 1;
    const part = known !== undefined ? known : await this.ctx.partAt(px * dpr, py * dpr);
    if (!part || !this.on) {
      this.select(-1);
      return;
    }
    if (part.index !== this.index) await this.load(part.index);
    const s = await this.session(part.index);
    const r = this.ray(px, py);
    const at = s && r ? placeAt(this.w, s, [...r[0], ...r[1]]) : null;
    if (!at) {
      this.ctx.toast("Click a face of the part to put a label there.");
      return;
    }
    const count = filaments().length;
    const label = { origin: at.origin, normal: at.normal, right: at.right, filament: nextFilament(this.base, count), depth: 0, items: [newItem("text")] };
    const res = await this.ctx.client.call("labelAdd", { index: part.index, label });
    if (res.id < 0) {
      this.ctx.toast("The label does not fit here.");
      return;
    }
    this.labels = res.labels;
    this.curve = at.curve;
    this.select(res.id);
    // The text field gets the keys at once.
    this.card?.focusText();
  }

  // A point of a free line at a pixel: into the item that draws.
  drawPoint(px, py) {
    const l = this.label;
    const r = this.ray(px, py);
    const it = l?.items[this.drawing];
    if (!r || !it || it.kind !== "polyline") return;
    const h = planeHit(l, r[0], r[1]);
    if (!h) return;
    const a = (-(it.angle ?? 0) * Math.PI) / 180;
    const x = h.x - (it.at?.[0] ?? 0);
    const y = h.y - (it.at?.[1] ?? 0);
    const p = [x * Math.cos(a) - y * Math.sin(a), x * Math.sin(a) + y * Math.cos(a)];
    this.drawn.push(p);
    if (this.drawn.length >= 2) this.editItem(this.drawing, { points: this.drawn.slice() });
  }

  startDrawing(i) {
    this.drawing = i;
    this.drawn = [];
    this.card?.show(this.label);
  }

  stopDrawing() {
    this.drawing = -1;
    this.flush();
    this.card?.show(this.label);
  }

  // ---- the pointer ----

  attach() {
    const canvas = this.ctx.canvas;
    const at = (e) => {
      const r = canvas.getBoundingClientRect();
      return [e.clientX - r.left, e.clientY - r.top];
    };
    canvas.addEventListener("pointerdown", (e) => {
      if (!this.on || e.button !== 0 || this.ctx.page() !== "3d" || e.ctrlKey) return;
      e.stopImmediatePropagation();
      e.preventDefault();
      const [px, py] = at(e);
      if (this.drawing >= 0) {
        this.drawPoint(px, py);
        return;
      }
      const hit = this.labelAt(px, py);
      if (!hit) {
        this.missAt(px, py);
        return;
      }
      if (hit.label.id !== this.sel) this.select(hit.label.id);
      canvas.setPointerCapture(e.pointerId);
      const l = this.label;
      this.drag = { id: l.id, dx: hit.x, dy: hit.y, start: { ...l }, moved: false, px, py };
      this.session(this.index);
    }, { capture: true });
    canvas.addEventListener("pointermove", (e) => {
      if (!this.on || !this.drag) return;
      e.stopImmediatePropagation();
      const [px, py] = at(e);
      const d = this.drag;
      if (!d.moved && Math.hypot(px - d.px, py - d.py) < 3) return;
      d.moved = true;
      this.moveTo(px, py, e.shiftKey);
    }, { capture: true });
    const end = (e) => {
      if (!this.on || !this.drag) return;
      e.stopImmediatePropagation();
      const d = this.drag;
      this.drag = null;
      if (d.moved) this.flush();
    };
    canvas.addEventListener("pointerup", end, { capture: true });
    canvas.addEventListener("pointercancel", end, { capture: true });
    // The wheel over the selected label turns it.
    canvas.addEventListener("wheel", (e) => {
      if (!this.on || this.sel < 0 || e.ctrlKey || this.ctx.page() !== "3d") return;
      const [px, py] = at(e);
      const hit = this.labelAt(px, py);
      if (!hit || hit.label.id !== this.sel) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      // Shift and a wheel scroll sideways in some browsers.
      const delta = e.deltaY || e.deltaX;
      if (!delta) return;
      this.turn((delta < 0 ? 1 : -1) * (e.shiftKey ? 15 : 1));
    }, { capture: true, passive: false });
  }

  // The selected label under the pointer while it drags: on the surface,
  // or in its plane with Shift.
  moveTo(px, py, keepPlane) {
    const d = this.drag;
    const r = this.ray(px, py);
    if (!r) return;
    if (keepPlane) {
      const h = planeHit(d.start, r[0], r[1]);
      if (!h) return;
      const up = upOf(d.start);
      const origin = add(add(h.p, d.start.right, -d.dx), up, -d.dy);
      this.change((l) => ({ ...l, origin, normal: d.start.normal, right: d.start.right }));
      return;
    }
    const s = this.sessions.get(this.index);
    if (!s) return;
    const p = placeAt(this.w, s, [...r[0], ...r[1]]);
    if (!p) return;
    this.change((l) => {
      const m = moved(l, p.origin, p.normal);
      m.origin = add(add(m.origin, m.right, -d.dx), upOf(m), -d.dy);
      return m;
    });
    if (Math.abs(p.curve - this.curve) > 1e-6) {
      this.curve = p.curve;
      this.card?.showCurve(this.curve);
    }
  }

  // ---- the corner handle: a drag scales the label ----

  makeHandle() {
    if (this.handle) return;
    const h = document.createElement("div");
    h.className = "label-handle";
    h.title = "Drag to make the label larger or smaller";
    h.setAttribute("aria-hidden", "true");
    h.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      const l = this.label;
      const c = this.screenCenter();
      if (!l || !c) return;
      h.setPointerCapture(e.pointerId);
      const host = this.ctx.host.getBoundingClientRect();
      const d0 = Math.max(4, Math.hypot(e.clientX - host.left - c[0], e.clientY - host.top - c[1]));
      const start = { ...l };
      this.scaling = true;
      const move = (ev) => {
        const k = Math.max(0.05, Math.hypot(ev.clientX - host.left - c[0], ev.clientY - host.top - c[1]) / d0);
        this.change(() => scaleLabel(start, k));
      };
      const up = () => {
        h.removeEventListener("pointermove", move);
        h.removeEventListener("pointerup", up);
        h.removeEventListener("pointercancel", up);
        this.scaling = false;
        this.flush();
      };
      h.addEventListener("pointermove", move);
      h.addEventListener("pointerup", up);
      h.addEventListener("pointercancel", up);
    });
    this.ctx.host.append(h);
    this.handle = h;
    this.makeTurnHandle();
  }

  // ---- the turn handle: a drag around the label turns it ----

  makeTurnHandle() {
    if (this.turnHandle) return;
    const h = document.createElement("div");
    h.className = "label-turn";
    h.title = "Drag to turn the label. Shift: steps of 15°.";
    h.setAttribute("aria-hidden", "true");
    h.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      const l = this.label;
      const c = this.screenCenter();
      const o = l && this.outline(l);
      if (!l || !c || !o) return;
      try {
        h.setPointerCapture(e.pointerId);
      } catch {
        // A pointer the browser does not know (a test): no capture.
      }
      const host = this.ctx.host.getBoundingClientRect();
      const at = (ev) => Math.atan2(ev.clientY - host.top - c[1], ev.clientX - host.left - c[0]);
      const a0 = at(e);
      const start = { ...l };
      const base = angleOf(start);
      // The way the label turns on the screen: its right and up axes as
      // the screen shows them (the label can face the camera or not).
      const cx = (o.box[0] + o.box[2]) / 2;
      const cy = (o.box[1] + o.box[3]) / 2;
      const p0 = this.screen(l, cx, cy);
      const pr = this.screen(l, cx + 1, cy);
      const pu = this.screen(l, cx, cy + 1);
      const cross = p0 && pr && pu ? (pr[0] - p0[0]) * (pu[1] - p0[1]) - (pr[1] - p0[1]) * (pu[0] - p0[0]) : -1;
      const sign = cross < 0 ? -1 : 1;
      this.scaling = true;
      const move = (ev) => {
        let d = (sign * (at(ev) - a0) * 180) / Math.PI;
        if (ev.shiftKey) d = Math.round((base + d) / 15) * 15 - base;
        this.change(() => turned(start, d));
      };
      const up = () => {
        h.removeEventListener("pointermove", move);
        h.removeEventListener("pointerup", up);
        h.removeEventListener("pointercancel", up);
        this.scaling = false;
        this.flush();
      };
      h.addEventListener("pointermove", move);
      h.addEventListener("pointerup", up);
      h.addEventListener("pointercancel", up);
    });
    this.ctx.host.append(h);
    this.turnHandle = h;
  }

  // A point of the plane of the selected label on the screen (CSS pixels
  // of the host), or null.
  screen(l, x, y) {
    const dpr = window.devicePixelRatio || 1;
    const p = toBed(l, x, y, LIFT);
    const q = this.ctx.pixelOf({ x: p[0], y: p[1], z: p[2] });
    return q ? [q[0] / dpr, q[1] / dpr] : null;
  }

  screenCenter() {
    const l = this.label;
    const o = l && this.outline(l);
    if (!o) return null;
    return this.screen(l, (o.box[0] + o.box[2]) / 2, (o.box[1] + o.box[3]) / 2);
  }

  // The box of the selected label on the screen (CSS pixels of the
  // host), with its handle, or null.
  screenBox() {
    const l = this.label;
    const o = l && this.outline(l);
    if (!o) return null;
    const box = [Infinity, Infinity, -Infinity, -Infinity];
    const m = 1;
    for (const x of [o.box[0] - m, o.box[2] + m]) for (const y of [o.box[1] - m, o.box[3] + m]) {
      const q = this.screen(l, x, y);
      if (!q) continue;
      box[0] = Math.min(box[0], q[0]);
      box[1] = Math.min(box[1], q[1]);
      box[2] = Math.max(box[2], q[0]);
      box[3] = Math.max(box[3], q[1]);
    }
    if (!(box[0] <= box[2])) return null;
    const g = 12; // the handle
    return [box[0] - g, box[1] - g, box[2] + g, box[3] + g];
  }

  // After each frame: the handle at the upper right corner of the label,
  // and the card beside the label.
  place() {
    if (!this.on || this.sel < 0) return;
    const l = this.label;
    const o = l && this.outline(l);
    if (this.handle) {
      const q = o && this.ctx.page() === "3d" ? this.screen(l, o.box[2] + 0.5, o.box[3] + 0.5) : null;
      this.handle.hidden = !q;
      if (q) {
        this.handle.style.left = `${q[0]}px`;
        this.handle.style.top = `${q[1]}px`;
      }
    }
    // The turn handle: 3 mm over the middle of the top of the label.
    if (this.turnHandle) {
      const q = o && this.ctx.page() === "3d" ? this.screen(l, (o.box[0] + o.box[2]) / 2, o.box[3] + 3) : null;
      this.turnHandle.hidden = !q;
      if (q) {
        this.turnHandle.style.left = `${q[0]}px`;
        this.turnHandle.style.top = `${q[1]}px`;
      }
    }
    this.card?.place(this.screenBox());
  }

  // After a new list of filaments: the colors and the chips again.
  refresh() {
    if (!this.on) return;
    this.redraw();
    this.refreshCard();
  }
}
