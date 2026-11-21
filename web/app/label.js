// label.js: the Label tool (E). It puts labels on the surface of a part:
// text, a line, a bar, a ring, the ticks of a dial, a free line, or an
// SVG picture, each in a filament of its own. The slice prints a label
// flush in the outer skin of the part (ink), out of the surface
// (raised), or cut into it (cut) (docs/user/labels.md).
//
// - A click on a face of a part adds a label there ("LABEL", 5 mm), in
//   the filament after the filament of the part. A click on a label
//   selects it, and its card opens (labelcard.js).
// - A drag of a label moves it on the surface; Shift keeps its plane.
//   The wheel over the selected label turns it 1° a step (Shift: 15°).
//   The handles on the surface around it: a corner resizes it (Shift:
//   each axis on its own), the round handle over it turns it (Shift: 15°
//   steps). A move or a resize snaps to the smart guides (the core:
//   zs_label_face, zs_label_snap); Alt moves free. Delete removes it.
// - "Place an SVG…" on the card, or an SVG file dropped on a part, makes
//   an SVG picture a shape of a label.
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
export const SHAPE_NAMES = { text: "Text", line: "Line", bar: "Bar", ring: "Ring", ticks: "Ticks", polyline: "Free", svg: "SVG" };
// The modes of a label, and their names on the card.
export const MODES = ["ink", "raised", "cut"];
export const MODE_NAMES = { ink: "Ink", raised: "Raised", cut: "Cut in" };
// The relief of a raised or cut label with a relief of 0 (the core), mm.
export const DEFAULT_RELIEF = 0.6;
// The height of a new SVG shape, mm.
export const SVG_SIZE = 15;
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
  svg: ["size"],
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
    case "svg": return it.size;
  }
  return 0;
}

// A file of an SVG picture.
export function isSvgFile(f) {
  return /\.svg$/i.test(f?.name ?? "") || f?.type === "image/svg+xml";
}

// An SVG shape of the source `svg`.
export function svgItem(svg, size = SVG_SIZE) {
  return { kind: "svg", svg, size };
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

// The label turned by `deg` around its normal, about the point `c` [x, y]
// of its plane: that point stays.
export function turnedAbout(label, deg, c) {
  const t = turned(label, deg);
  const u0 = upOf(label);
  const u1 = upOf(t);
  const o = add(add(label.origin, add(label.right, t.right, -1), c[0]), add(u0, u1, -1), c[1]);
  return { ...t, origin: o };
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

// ---- the handles: the geometry, with no DOM ----

// The snap distance of the smart guides, CSS pixels.
export const SNAP_PX = 6;
// The sizes of the handles, CSS pixels: the gap of the frame around the
// label, the side of a corner square, the radius of the turn handle and
// its distance over the frame.
const HANDLE = { gap: 4, side: 9, r: 5, over: 22 };

// The handles of a label with the outline box `box` (mm in its plane) at
// `mpp` mm for each pixel: { box (the frame), hs (the half side of a
// corner), turn [x, y], r }.
export function handleGeom(box, mpp) {
  const g = HANDLE.gap * mpp;
  const b = [box[0] - g, box[1] - g, box[2] + g, box[3] + g];
  return { box: b, hs: (HANDLE.side / 2) * mpp, turn: [(b[0] + b[2]) / 2, b[3] + HANDLE.over * mpp], r: HANDLE.r * mpp };
}

// The handle at the point (x, y) of the plane: { kind: "corner", corner:
// [sx, sy] (+1: the high side) } or { kind: "turn" }, or null. A handle
// has a hit area a little larger than its decal.
export function hitHandle(g, x, y) {
  const m = 1.6;
  if (Math.hypot(x - g.turn[0], y - g.turn[1]) <= g.r * m) return { kind: "turn" };
  for (const sx of [-1, 1]) for (const sy of [-1, 1]) {
    const cx = sx > 0 ? g.box[2] : g.box[0];
    const cy = sy > 0 ? g.box[3] : g.box[1];
    if (Math.abs(x - cx) <= g.hs * m && Math.abs(y - cy) <= g.hs * m) return { kind: "corner", corner: [sx, sy] };
  }
  return null;
}

// The box of a resize from the corner `corner` of box b0 to the point p
// of the plane: the opposite corner stays. With `free`, each axis on its
// own; else one scale. { box, anchor, k: [ks, kt] }.
export function resizeBox(b0, corner, p, free) {
  const anchor = [corner[0] > 0 ? b0[0] : b0[2], corner[1] > 0 ? b0[1] : b0[3]];
  const c0 = [corner[0] > 0 ? b0[2] : b0[0], corner[1] > 0 ? b0[3] : b0[1]];
  const v = [c0[0] - anchor[0], c0[1] - anchor[1]];
  let k;
  if (free) {
    k = [Math.abs(v[0]) > 1e-9 ? (p[0] - anchor[0]) / v[0] : 1, Math.abs(v[1]) > 1e-9 ? (p[1] - anchor[1]) / v[1] : 1];
  } else {
    const kk = ((p[0] - anchor[0]) * v[0] + (p[1] - anchor[1]) * v[1]) / Math.max(1e-12, v[0] * v[0] + v[1] * v[1]);
    k = [kk, kk];
  }
  k = k.map((x) => Math.max(0.05, x));
  return { box: boxFrom(anchor, c0, k), anchor, k };
}

function boxFrom(anchor, c0, k) {
  const c = [anchor[0] + k[0] * (c0[0] - anchor[0]), anchor[1] + k[1] * (c0[1] - anchor[1])];
  return [Math.min(anchor[0], c[0]), Math.min(anchor[1], c[1]), Math.max(anchor[0], c[0]), Math.max(anchor[1], c[1])];
}

// The scales of a box b against box b0: [ks, kt].
export function scalesOf(b0, b) {
  return [(b[2] - b[0]) / Math.max(1e-12, b0[2] - b0[0]), (b[3] - b[1]) / Math.max(1e-12, b0[3] - b0[1])];
}

// The label `start` resized by k = [ks, kt] about the point `anchor` of
// its plane. One scale: the sizes of the shapes change. Two scales: the
// stretch changes.
export function resized(start, anchor, k, free) {
  let next;
  if (free) {
    const s = start.stretch ?? [1, 1];
    next = { ...start, stretch: [s[0] * k[0], s[1] * k[1]] };
  } else next = scaleLabel(start, k[0]);
  const up = upOf(start);
  const ds = (1 - k[0]) * anchor[0];
  const dt = (1 - k[1]) * anchor[1];
  next.origin = add(add(start.origin, start.right, ds), up, dt);
  return next;
}

// Label l in the plane of the frame f (origin, normal): the normals
// within 2.5° and the origin of l within 0.2 mm of the plane of f.
export function samePlane(f, l) {
  if (dot(f.normal, l.normal) < Math.cos((2.5 * Math.PI) / 180)) return false;
  return Math.abs(dot(add(l.origin, f.origin, -1), f.normal)) < 0.2;
}

// A rectangle (counterclockwise) as points [x, y].
export function rect(x0, y0, x1, y1) {
  return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
}

export function circle(cx, cy, r, n = 24) {
  const out = [];
  for (let k = 0; k < n; k++) out.push([cx + r * Math.cos((2 * Math.PI * k) / n), cy + r * Math.sin((2 * Math.PI * k) / n)]);
  return out;
}

// A guide [s0, t0, s1, t1] as a thin rectangle of width w, or null.
export function segment(s, w) {
  const dx = s[2] - s[0];
  const dy = s[3] - s[1];
  const l = Math.hypot(dx, dy);
  if (!(l > 1e-9)) return null;
  const nx = (-dy / l) * (w / 2);
  const ny = (dx / l) * (w / 2);
  return [[s[0] - nx, s[1] - ny], [s[2] - nx, s[3] - ny], [s[2] + nx, s[3] + ny], [s[0] + nx, s[1] + ny]];
}

// A decal of polygons in the plane of label l (gl.js, setLabels).
export function decal(l, polys, color, edge = null) {
  let n = 0;
  for (const p of polys) n += p.length;
  const pts = new Float32Array(3 * n);
  const ends = new Uint32Array(polys.length);
  let i = 0;
  polys.forEach((p, k) => {
    for (const [x, y] of p) pts.set(toBed(l, x, y, 2 * LIFT), 3 * i++);
    ends[k] = i;
  });
  return { pts, ends, color, edge };
}

function rgb(hex) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || "");
  if (!m) return [0.82, 0.82, 0.8];
  return m.slice(1).map((h) => parseInt(h, 16) / 255);
}

// The name of a label of an SVG file: the file name with no ".svg".
function svgName(name) {
  return (name || "").replace(/\.svg$/i, "").slice(0, 120);
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
    this.guides = []; // the lines of the smart guides in a drag
    this.face = null; // the features of the face (faceAt)
    this.handleScale = 0; // the mm of a pixel of the handles drawn
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
    const sl = this.label;
    if (sl && this.ctx.page() === "3d") list.push(...this.handleDecals(sl));
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
      this.guides = [];
      this.redraw();
      return;
    }
    if (!this.card) this.card = new this.ctx.Card(this, this.ctx.host);
    this.card.show(l);
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
    else if (!this.drag) this.timer = setTimeout(() => this.flush(), COMMIT_MS);
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

  // Ink, raised, or cut.
  setMode(mode) {
    this.change((l) => {
      const out = { ...l, mode };
      if (mode === "ink") delete out.relief;
      else out.relief = l.relief || DEFAULT_RELIEF;
      return out;
    }, true);
  }

  setRelief(mm) {
    this.change((l) => ({ ...l, relief: Math.max(0, Math.min(10, mm)) }), true);
  }

  // An SVG picture into the selected label: it replaces the new text
  // "LABEL", else it goes under the shapes. false for a picture
  // with no shape that the core reads.
  placeSvg(svg, name = "") {
    const it = svgItem(svg);
    if (!outlineOf(this.w, { items: [it] })) {
      this.ctx.toast("The SVG has no filled shape to place.");
      return false;
    }
    this.change((l) => {
      const fresh = l.items.length === 1 && l.items[0].kind === "text" && l.items[0].text === "LABEL";
      if (fresh) return { ...l, name: l.name || svgName(name), items: [it] };
      const o = this.outline(l);
      return { ...l, items: [...l.items, { ...it, at: [0, (o ? o.box[1] : 0) - it.size / 2 - 1] }] };
    }, true);
    this.card?.show(this.label);
    return true;
  }

  // An SVG file dropped at a CSS pixel: a new label of it on the face of
  // the part there.
  async dropSvg(svg, px, py, name = "") {
    if (!outlineOf(this.w, { items: [svgItem(svg)] })) {
      this.ctx.toast("The SVG has no filled shape to place.");
      return;
    }
    if (!this.on) await this.open(-1, 0);
    const dpr = window.devicePixelRatio || 1;
    const part = await this.ctx.partAt(px * dpr, py * dpr);
    if (!part) {
      this.ctx.toast("Drop the SVG on a part.");
      return;
    }
    if (part.index !== this.index) await this.load(part.index);
    const s = await this.session(part.index);
    const r = this.ray(px, py);
    const at = s && r ? placeAt(this.w, s, [...r[0], ...r[1]]) : null;
    if (!at) {
      this.ctx.toast("Drop the SVG on a face of the part.");
      return;
    }
    const count = filaments().length;
    const label = { name: svgName(name), origin: at.origin, normal: at.normal, right: at.right, filament: nextFilament(this.base, count), depth: 0, items: [svgItem(svg)] };
    const res = await this.ctx.client.call("labelAdd", { index: part.index, label });
    if (!(res.id >= 0)) {
      this.ctx.toast("The SVG does not fit here.");
      return;
    }
    this.labels = res.labels;
    this.curve = at.curve;
    this.select(res.id);
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
      // Under the label of the copy (its height and 1 mm lower), else over
      // it, on the surface again: a ray in along the normal. Only a face
      // over the bed (z ≥ 0) takes it; else no label (a label at the foot
      // of a part went below the bed, in the air).
      const o = this.outline(src);
      const h = o ? o.box[3] - o.box[1] : 5;
      const s = await this.session(index);
      label = null;
      for (const k of [-(h + 1), h + 1]) {
        const start = add(src.origin, upOf(src), k);
        const from = add(start, src.normal, 5);
        const p = s ? placeAt(this.w, s, [...from, ...src.normal.map((v) => -v)]) : null;
        if (p && p.origin[2] >= 0) {
          label = moved({ ...src, origin: start }, p.origin, p.normal);
          break;
        }
      }
      if (!label) {
        this.ctx.toast("The label does not fit here. Point at a face of the part, then paste.");
        return false;
      }
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
      const capture = () => {
        try {
          canvas.setPointerCapture(e.pointerId);
        } catch {
          // A pointer the browser does not know (a test): no capture.
        }
      };
      const hk = this.handleAt(px, py);
      if (hk) {
        capture();
        this.startHandle(hk, px, py);
        return;
      }
      const hit = this.labelAt(px, py);
      if (!hit) {
        this.missAt(px, py);
        return;
      }
      if (hit.label.id !== this.sel) this.select(hit.label.id);
      capture();
      const l = this.label;
      this.drag = { mode: "move", id: l.id, dx: hit.x, dy: hit.y, start: { ...l }, moved: false, px, py };
      this.session(this.index);
    }, { capture: true });
    canvas.addEventListener("pointermove", (e) => {
      if (!this.on) return;
      const [px, py] = at(e);
      if (!this.drag) {
        // The cursor over a handle.
        if (this.sel >= 0 && this.ctx.page() === "3d" && this.drawing < 0) {
          const hk = this.handleAt(px, py);
          canvas.style.cursor = !hk ? "crosshair" : hk.kind === "turn" ? "grab" : hk.corner[0] === hk.corner[1] ? "nesw-resize" : "nwse-resize";
        }
        return;
      }
      e.stopImmediatePropagation();
      this.dragTo(px, py, e.shiftKey, e.altKey);
    }, { capture: true });
    const end = (e) => {
      if (!this.on || !this.drag) return;
      e.stopImmediatePropagation();
      this.endDrag();
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
    // An SVG file dropped on a part: a label of it there.
    this.ctx.host?.addEventListener("drop", (e) => {
      const f = [...(e.dataTransfer?.files ?? [])].find((x) => isSvgFile(x));
      if (!f) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      this.ctx.host.classList.remove("drop");
      const [px, py] = at(e);
      f.text().then((t) => this.dropSvg(t, px, py, f.name));
    }, { capture: true });
  }

  // A drag of a handle starts (hk: handleAt).
  startHandle(hk, px, py) {
    const l = this.label;
    const o = l && this.outline(l);
    if (!o) return;
    this.session(this.index);
    if (hk.kind === "corner") {
      this.drag = { mode: "resize", id: l.id, corner: hk.corner, start: { ...l }, box0: o.box.slice(), moved: false, px, py };
      return;
    }
    const c = this.screenCenter();
    if (!c) return;
    // The way the label turns on the screen: its right and up axes as
    // the screen shows them (the label can face the camera or not).
    const cx = (o.box[0] + o.box[2]) / 2;
    const cy = (o.box[1] + o.box[3]) / 2;
    const p0 = this.screen(l, cx, cy);
    const pr = this.screen(l, cx + 1, cy);
    const pu = this.screen(l, cx, cy + 1);
    const cr = p0 && pr && pu ? (pr[0] - p0[0]) * (pu[1] - p0[1]) - (pr[1] - p0[1]) * (pu[0] - p0[0]) : -1;
    // The center of the box in the plane stays where it is: a turn of
    // the frame turns the shapes about the origin of the plane.
    this.drag = { mode: "turn", id: l.id, start: { ...l }, c, a0: Math.atan2(py - c[1], px - c[0]), sign: cr < 0 ? -1 : 1, center: [cx, cy], base: angleOf(l), moved: false, px, py };
  }

  // The pointer moves in a drag.
  dragTo(px, py, shift, alt) {
    const d = this.drag;
    if (!d.moved && Math.hypot(px - d.px, py - d.py) < 3) return;
    d.moved = true;
    if (d.mode === "move") this.moveTo(px, py, shift, alt);
    else if (d.mode === "resize") this.resizeTo(px, py, shift, alt);
    else this.turnTo(px, py, shift);
  }

  endDrag() {
    const d = this.drag;
    this.drag = null;
    this.guides = [];
    this.redraw();
    if (d.moved) this.flush();
  }

  // The selected label under the pointer while it drags: on the surface,
  // or in its plane with Shift. It snaps to the guides (Alt: free).
  moveTo(px, py, keepPlane, free = false) {
    const d = this.drag;
    const r = this.ray(px, py);
    if (!r) return;
    let next;
    if (keepPlane) {
      const h = planeHit(d.start, r[0], r[1]);
      if (!h) return;
      const up = upOf(d.start);
      const origin = add(add(h.p, d.start.right, -d.dx), up, -d.dy);
      next = { ...this.label, origin, normal: d.start.normal, right: d.start.right };
    } else {
      const s = this.sessions.get(this.index);
      if (!s) return;
      const p = placeAt(this.w, s, [...r[0], ...r[1]]);
      if (!p) return;
      next = moved(this.label, p.origin, p.normal);
      next.origin = add(add(next.origin, next.right, -d.dx), upOf(next), -d.dy);
      if (Math.abs(p.curve - this.curve) > 1e-6) {
        this.curve = p.curve;
        this.card?.showCurve(this.curve);
      }
    }
    this.guides = [];
    const o = this.outline(next);
    if (!free && o) {
      const sn = this.snapBox(next, o.box, "move");
      if (sn) {
        next.origin = add(add(next.origin, next.right, sn.d[0]), upOf(next), sn.d[1]);
        this.guides = sn.guides;
      }
    }
    this.change(() => next);
  }

  // A corner handle under the pointer: the opposite corner stays. Shift:
  // each axis on its own. It snaps to the guides (Alt: free).
  resizeTo(px, py, freeAspect, free) {
    const d = this.drag;
    const r = this.ray(px, py);
    const h = r && planeHit(d.start, r[0], r[1]);
    if (!h) return;
    const rb = resizeBox(d.box0, d.corner, [h.x, h.y], freeAspect);
    let k = rb.k;
    this.guides = [];
    if (!free) {
      const sn = this.snapBox(d.start, rb.box, "resize", { corner: d.corner, aspect: !freeAspect });
      if (sn) {
        k = scalesOf(d.box0, sn.box);
        if (!freeAspect) k = [k[0], k[0]];
        this.guides = sn.guides;
      }
    }
    this.change(() => resized(d.start, rb.anchor, k, freeAspect));
  }

  // The turn handle under the pointer: the label turns about the center
  // of its box. Shift: steps of 15°.
  turnTo(px, py, steps) {
    const d = this.drag;
    let deg = (d.sign * (Math.atan2(py - d.c[1], px - d.c[0]) - d.a0) * 180) / Math.PI;
    if (steps) deg = Math.round((d.base + deg) / 15) * 15 - d.base;
    this.change(() => turnedAbout(d.start, deg, d.center));
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
  // host), with its handles, or null.
  screenBox() {
    const l = this.label;
    const g = l && this.handleGeom(l);
    if (!g) return null;
    const box = [Infinity, Infinity, -Infinity, -Infinity];
    const pts = [[g.box[0], g.box[1]], [g.box[2], g.box[1]], [g.box[2], g.box[3]], [g.box[0], g.box[3]], [g.turn[0], g.turn[1] + g.r]];
    for (const [x, y] of pts) {
      const q = this.screen(l, x, y);
      if (!q) continue;
      box[0] = Math.min(box[0], q[0]);
      box[1] = Math.min(box[1], q[1]);
      box[2] = Math.max(box[2], q[0]);
      box[3] = Math.max(box[3], q[1]);
    }
    if (!(box[0] <= box[2])) return null;
    const m = 8;
    return [box[0] - m, box[1] - m, box[2] + m, box[3] + m];
  }

  // After each frame: the handles keep their size on the screen (a zoom
  // draws them again), and the card goes beside the label.
  place() {
    if (!this.on || this.sel < 0) return;
    const l = this.label;
    if (l && this.handleScale) {
      const mpp = this.mmPerPx(l);
      if (Math.abs(mpp - this.handleScale) > 0.08 * this.handleScale) this.redraw();
    }
    this.card?.place(this.screenBox());
  }

  // ---- the handles and the smart guides ----
  //
  // The selected label has a frame on the surface, a square handle at
  // each corner (a drag resizes it: the aspect stays, Shift frees it),
  // and a round handle over it (a drag turns it: Shift, 15° steps). They
  // are decals in the plane of the label, with sizes in pixels of the
  // screen. A drag of the body moves the label. A move or a resize snaps
  // to the smart guides of the core (zs_label_face, zs_label_snap): the
  // other labels of the face, its holes, and the centers of the face and
  // of the part. Alt moves free. The guides show as thin lines.

  // The mm of the plane of label l in one CSS pixel at its center.
  mmPerPx(l) {
    const o = this.outline(l);
    if (!o) return 0.1;
    const cx = (o.box[0] + o.box[2]) / 2;
    const cy = (o.box[1] + o.box[3]) / 2;
    const p0 = this.screen(l, cx, cy);
    const pr = this.screen(l, cx + 1, cy);
    const pu = this.screen(l, cx, cy + 1);
    if (!p0 || !pr || !pu) return 0.1;
    const d = Math.max(Math.hypot(pr[0] - p0[0], pr[1] - p0[1]), Math.hypot(pu[0] - p0[0], pu[1] - p0[1]));
    return d > 1e-6 ? 1 / d : 0.1;
  }

  // The places of the handles of label l in its plane (mm): the frame
  // box, the half side of a corner square, and the center and the radius
  // of the turn handle.
  handleGeom(l, mpp = this.mmPerPx(l)) {
    const o = this.outline(l);
    if (!o) return null;
    return handleGeom(o.box, mpp);
  }

  // The handle of the selected label at a CSS pixel: { kind: "corner",
  // corner: [sx, sy] } or { kind: "turn" }, or null.
  handleAt(px, py) {
    const l = this.label;
    if (!l || this.ctx.page() !== "3d") return null;
    const r = this.ray(px, py);
    const g = this.handleGeom(l);
    if (!r || !g) return null;
    const h = planeHit(l, r[0], r[1]);
    if (!h) return null;
    return hitHandle(g, h.x, h.y);
  }

  // The features of the face under label l (zs_label_face), kept while
  // the label stays in the same plane.
  faceAt(l) {
    const s = this.sessions.get(this.index);
    if (!s) return null;
    const f = this.face;
    if (f && f.index === this.index && samePlane(f.frame, l)) return f.json;
    // A curved face changes the plane at each step: a new face at most
    // each 150 ms there.
    const now = performance.now();
    if (f && f.index === this.index && now - f.time < 150) return null;
    const w = this.w;
    const c = w.alloc(72);
    let json = null;
    try {
      new Float64Array(w.x.memory.buffer, c, 9).set([...l.origin, ...l.normal, ...l.right]);
      const t = w.readText((b, cap, ol) => w.x.zs_label_face(s, c, b, cap, ol));
      json = t ? JSON.parse(t) : null;
    } finally {
      w.free(c, 72);
    }
    this.face = { index: this.index, frame: { origin: l.origin.slice(), normal: l.normal.slice() }, json, time: now };
    return json;
  }

  // The snap of a box of label l (zs_label_snap): { box, d, guides }, or
  // null.
  snapBox(l, box, op, extra = {}) {
    const mpp = this.mmPerPx(l);
    const others = [];
    for (const x of this.labels) {
      if (x.id === l.id) continue;
      const o = this.outline(x);
      if (o && o.pts.length > 0) others.push({ origin: x.origin, normal: x.normal, right: x.right, box: o.box });
    }
    const json = JSON.stringify({ op, frame: { origin: l.origin, normal: l.normal, right: l.right }, box, tol: SNAP_PX * mpp, others, face: this.faceAt(l), ...extra });
    const w = this.w;
    const t = w.withBytes(new TextEncoder().encode(json), (p, n) => w.readText((b, cap, ol) => w.x.zs_label_snap(p, n, b, cap, ol)));
    return t ? JSON.parse(t) : null;
  }

  // The decals of the handles and the guides of the selected label.
  handleDecals(l) {
    const mpp = this.mmPerPx(l);
    this.handleScale = mpp;
    const g = this.handleGeom(l, mpp);
    if (!g) return [];
    const out = [];
    const accent = [0.16, 0.5, 1];
    const lw = 1.5 * mpp;
    const [b0, b1, b2, b3] = g.box;
    // The frame: a ring of the width of a line.
    out.push(decal(l, [rect(b0 - lw / 2, b1 - lw / 2, b2 + lw / 2, b3 + lw / 2), rect(b0 + lw / 2, b1 + lw / 2, b2 - lw / 2, b3 - lw / 2).reverse()], accent));
    // The stem and the turn handle.
    const mx = (b0 + b2) / 2;
    out.push(decal(l, [rect(mx - lw / 2, b3, mx + lw / 2, g.turn[1] - g.r)], accent));
    out.push(decal(l, [circle(g.turn[0], g.turn[1], g.r)], [1, 1, 1], accent));
    // The corners.
    for (const [x, y] of [[b0, b1], [b2, b1], [b2, b3], [b0, b3]]) out.push(decal(l, [rect(x - g.hs, y - g.hs, x + g.hs, y + g.hs)], [1, 1, 1], accent));
    // The guides.
    const gw = 1.2 * mpp;
    for (const s of this.guides ?? []) {
      const p = segment(s, gw);
      if (p) out.push(decal(l, [p], [0.95, 0.2, 0.6]));
    }
    return out;
  }

  // After a new list of filaments: the colors and the chips again.
  refresh() {
    if (!this.on) return;
    this.redraw();
    this.refreshCard();
  }
}
