// paint.js: the Paint tool (P). It paints filaments on the surface of the
// parts, for a print with more than one filament.
//
// The tool shows the mesh of each part of the plate (gl.js, addPaintMesh)
// in place of the beads, each triangle in the color of its filament. Each
// part stays at its place. A click paints the part under the pointer, so
// the tool needs no selection. Two modes:
//
// - Smart select: the region under the pointer lights before the click.
//   A click paints the region with the filament of the card. A region is
//   a part of the mesh that stands out of its surface or sinks into it
//   (a raised letter: its top and its sides), else a flat or smooth face
//   (src/paint.zig, Features). Shift and a click add a region to the
//   selection; a chip of another filament then paints all of it.
// - Brush: a left drag paints a sphere of the brush size along the
//   pointer. Triangles on the edge of the sphere split, so the border is
//   clean. A stroke stays on the part where it starts.
//
// Each part has its own paint session (zs_paint_*), on this thread. A part
// with paint gets its session when the tool opens, because the session
// decodes the paint. A part with no paint gets its session when the
// pointer first comes over its box. A ray tests the boxes first, nearest
// first, so a hover costs a few box tests and one or two grid walks.
//
// The active part is the last part that the user painted. The Inspector
// names it, and "Remove all paint" acts on it. While the pointer is over
// another part, the Inspector names that part.
//
// A right drag turns the view and a middle drag pans, as in the other
// tools (input.js). The end of a click or a stroke sends the paint of its
// part to the worker (paintSet), and it slices. After an undo or another
// change of the plate, sync() reads the parts again. It replaces only the
// meshes and the paint that changed. A sync waits for the end of a stroke.
// The view shows the beads again when the tool closes.
//
// The card of the tool sits in the Inspector, so it never covers a part.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { filaments, inkOn } from "./filaments.js";

function rgb(hex) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || "");
  if (!m) return [0.82, 0.82, 0.8];
  return m.slice(1).map((h) => parseInt(h, 16) / 255);
}

// The distance along a ray to a box, or Infinity for a miss.
function rayBox(ray, box) {
  let near = 0;
  let far = Infinity;
  for (let k = 0; k < 3; k++) {
    const o = ray[k];
    const d = ray[k + 3];
    if (d === 0) {
      if (o < box[k] || o > box[k + 3]) return Infinity;
      continue;
    }
    const a = (box[k] - o) / d;
    const b = (box[k + 3] - o) / d;
    near = Math.max(near, Math.min(a, b));
    far = Math.min(far, Math.max(a, b));
    if (near > far) return Infinity;
  }
  return near;
}

function boxOf(v) {
  const b = [Infinity, Infinity, Infinity, -Infinity, -Infinity, -Infinity];
  for (let i = 0; i < v.length; i += 3) {
    for (let k = 0; k < 3; k++) {
      if (v[i + k] < b[k]) b[k] = v[i + k];
      if (v[i + k] > b[k + 3]) b[k + 3] = v[i + k];
    }
  }
  // The grid of a session rounds its cells: a small margin keeps a ray
  // at the edge of the part.
  for (let k = 0; k < 3; k++) {
    b[k] -= 1e-3;
    b[k + 3] += 1e-3;
  }
  return b;
}

export class PaintTool {
  // ctx: { client, view (View3D), gl (GlRenderer), canvas, host (the
  //        element of the view), part() (the index of the selected part,
  //        or -1), indexOf(id) (the index of a part now, or -1),
  //        requestFrame(), toast(text), button (the tool button),
  //        addFilament() -> Promise<index> }
  constructor(ctx) {
    this.ctx = ctx;
    this.on = false;
    this.opening = false;
    this.run = 0; // counts the closes: a late reply of a closed tool drops
    this.parts = new Map(); // id -> the entry of a part (see apply)
    this.active = null; // the entry that the card acts on
    this.over = null; // the entry under the pointer
    this.mode = "smart";
    this.size = 2; // the radius of the brush, mm
    this.state = 2; // the filament to paint with (from 1)
    this.hover = null; // { e, id, tris }
    this.selection = []; // regions: { e, id, tris }
    this.stroke = null; // { e, changed }
    this.syncing = false;
    this.syncWanted = false;
    this.attach();
  }

  get w() {
    return this.ctx.view.w;
  }

  toggle() {
    if (this.on) this.close();
    else this.open();
  }

  async open() {
    if (this.on || this.opening) return;
    this.opening = true;
    const run = this.run;
    let r;
    try {
      r = await this.ctx.client.call("paintParts", { known: {} });
    } finally {
      if (run === this.run) this.opening = false;
    }
    if (run !== this.run) return;
    if (!r.parts?.length) {
      this.ctx.toast("Open a model to paint it.");
      return;
    }
    this.apply(r.parts);
    if (this.parts.size === 0) {
      this.ctx.toast("The part has no mesh.");
      return;
    }
    const chosen = this.ctx.part();
    const list = [...this.parts.values()];
    this.active = list.find((e) => e.index === chosen) ?? (list.length === 1 ? list[0] : null);
    this.on = true;
    this.ctx.gl.setPaintView(true);
    const count = filaments().length;
    const base = this.active?.base ?? list[0].base;
    if (this.state === base || this.state > count) this.state = count > 1 ? (base === 1 ? 2 : 1) : 1;
    this.colors();
    this.buildCard();
    this.ctx.button?.classList.add("on");
    this.ctx.requestFrame();
    if (this.syncWanted) this.sync();
  }

  close() {
    this.run++;
    this.opening = false;
    this.syncing = false;
    this.syncWanted = false;
    if (!this.on && this.parts.size === 0) return;
    this.on = false;
    this.ctx.gl.setPaintView(false);
    for (const e of this.parts.values()) this.drop(e);
    this.parts.clear();
    this.active = null;
    this.over = null;
    this.hover = null;
    this.selection = [];
    this.stroke = null;
    this.card?.remove();
    this.card = null;
    this.ctx.button?.classList.remove("on");
    this.ctx.requestFrame();
  }

  // Frees the session and the GPU mesh of a part.
  drop(e) {
    if (e.s) this.w.x.zs_paint_free(e.s);
    e.s = 0;
    if (e.mesh) this.ctx.gl.removePaintMesh(e.mesh);
    e.mesh = null;
  }

  // ---- the parts ----

  // Reads the parts again after a change of the plate (an undo, a move, a
  // new plate). One read runs at a time, and a read waits for a stroke.
  async sync() {
    if (!this.on) return;
    if (this.stroke || this.syncing) {
      this.syncWanted = true;
      return;
    }
    const run = this.run;
    this.syncing = true;
    try {
      do {
        this.syncWanted = false;
        const known = {};
        for (const e of this.parts.values()) known[e.id] = { meshKey: e.meshKey, paintKey: e.paintKey };
        const r = await this.ctx.client.call("paintParts", { known });
        if (run !== this.run) return;
        if (this.stroke) {
          this.syncWanted = true;
          return;
        }
        this.apply(r.parts ?? []);
      } while (this.syncWanted);
    } finally {
      if (run === this.run) this.syncing = false;
    }
    this.labelPart();
    this.ctx.requestFrame();
  }

  // The rows of the worker (paintParts) to the entries. An entry:
  //   id, index, name, base (its filament, from 1), meshKey, paintKey,
  //   gen (counts its meshes), pending (paint on the way to the worker),
  //   box, nf, verts and faces (until its session exists), text (its paint
  //   until its session exists), s (the session), vstates, mesh (GPU).
  apply(rows) {
    const seen = new Set();
    let colors = false;
    for (const row of rows) {
      seen.add(row.id);
      let e = this.parts.get(row.id);
      if (!e && !row.verts) continue;
      if (!e) {
        e = { id: row.id, s: 0, mesh: null, gen: 0, pending: 0, text: "", paintKey: "", meshKey: "" };
        this.parts.set(row.id, e);
      }
      e.index = row.index;
      e.name = row.name;
      if (e.base !== row.filament) {
        e.base = row.filament;
        colors = true;
      }
      if (row.verts) {
        if (!row.faces.length) {
          this.remove(e);
          continue;
        }
        this.setMesh(e, row);
        colors = true;
      }
      if (row.text !== undefined) {
        if (e.pending > 0) this.syncWanted = true;
        else {
          e.paintKey = row.paintKey;
          this.setText(e, row.text);
        }
      }
    }
    for (const e of [...this.parts.values()]) if (!seen.has(e.id)) this.remove(e);
    if (colors) this.colors();
  }

  remove(e) {
    this.forget(e);
    if (this.active === e) this.active = null;
    if (this.over === e) this.setOver(null);
    this.drop(e);
    this.parts.delete(e.id);
  }

  // The hover and the selection of a part lose their triangles.
  forget(e) {
    if (this.hover?.e === e) this.hover = null;
    this.selection = this.selection.filter((r) => r.e !== e);
  }

  setMesh(e, row) {
    this.forget(e);
    this.drop(e);
    e.gen++;
    e.meshKey = row.meshKey;
    e.verts = row.verts;
    e.faces = row.faces;
    e.nf = row.faces.length / 3;
    e.box = boxOf(row.verts);
    e.vstates = null;
    e.mesh = this.ctx.gl.addPaintMesh(row.verts, row.faces);
    // A commit on the way names the old mesh. Its reply does not set the
    // key, so the next read brings the paint.
    if (e.pending > 0) {
      e.paintKey = "";
      this.syncWanted = true;
    }
  }

  setText(e, text) {
    if (e.s) {
      this.w.withBytes(new TextEncoder().encode(text), (p, n) => this.w.x.zs_paint_set_text(e.s, p, n));
      this.upload(e);
      return;
    }
    e.text = text;
    if (text.length > 0 && this.session(e)) this.upload(e);
  }

  // The session of a part, made at the first need. False if it fails.
  session(e) {
    if (e.s) return true;
    if (e.bad || !e.verts) return false;
    const w = this.w;
    const x = w.x;
    const { verts, faces } = e;
    const vp = w.alloc(verts.byteLength);
    const fp = w.alloc(faces.byteLength);
    try {
      new Float32Array(x.memory.buffer, vp, verts.length).set(verts);
      new Uint32Array(x.memory.buffer, fp, faces.length).set(faces);
      if (x.zs_paint_new(vp, verts.length / 3, fp, faces.length / 3, w.cell) !== 0) {
        e.bad = true;
        this.ctx.toast("The paint tool cannot open this part.");
        return false;
      }
    } finally {
      w.free(vp, verts.byteLength);
      w.free(fp, faces.byteLength);
    }
    e.s = w.u32(w.cell);
    if (e.text) w.withBytes(new TextEncoder().encode(e.text), (p, n) => x.zs_paint_set_text(e.s, p, n));
    e.text = "";
    e.verts = null;
    e.faces = null;
    e.vstates = new Uint8Array(3 * e.nf);
    return true;
  }

  // The palette of the shader: k filament k. Color 0 is the filament of
  // each part (setPaintBase).
  colors() {
    const list = filaments();
    const cols = [rgb(list[0].color)];
    for (let k = 1; k <= 17; k++) cols.push(rgb(list[k - 1]?.color ?? list[0].color));
    this.ctx.gl.setPaintColors(cols);
    for (const e of this.parts.values()) {
      if (e.mesh) this.ctx.gl.setPaintBase(e.mesh, rgb(list[(e.base || 1) - 1]?.color ?? list[0].color));
    }
  }

  // The states of the triangles of a part to the GPU, with the light of
  // the region under the pointer and of the selection.
  upload(e) {
    if (!e?.s || !e.mesh) return;
    const w = this.w;
    const n = w.x.zs_paint_states(e.s, w.cell);
    const p = w.u32(w.cell);
    const st = new Uint8Array(w.x.memory.buffer, p, n);
    const vs = e.vstates;
    for (let t = 0; t < n; t++) {
      const s = st[t];
      vs[3 * t] = vs[3 * t + 1] = vs[3 * t + 2] = s;
    }
    const lit = (tris) => {
      for (const t of tris) if (vs[3 * t] !== 255) vs[3 * t] = vs[3 * t + 1] = vs[3 * t + 2] = vs[3 * t] | 128;
    };
    if (this.hover?.e === e) lit(this.hover.tris);
    for (const r of this.selection) if (r.e === e) lit(r.tris);
    this.ctx.gl.setPaintStates(e.mesh, vs);
    // The pieces of the split triangles.
    const nl = w.x.zs_paint_leaves(e.s, w.cell);
    const lp = w.u32(w.cell);
    const src = new Float32Array(w.x.memory.buffer, lp, 10 * nl);
    const out = new Float32Array(21 * nl);
    for (let i = 0; i < nl; i++) {
      const q = src.subarray(10 * i, 10 * i + 10);
      const ux = q[3] - q[0], uy = q[4] - q[1], uz = q[5] - q[2];
      const wx = q[6] - q[0], wy = q[7] - q[1], wz = q[8] - q[2];
      let nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
      const len = Math.hypot(nx, ny, nz) || 1;
      nx /= len; ny /= len; nz /= len;
      for (let k = 0; k < 3; k++) out.set([q[3 * k], q[3 * k + 1], q[3 * k + 2], nx, ny, nz, q[9]], 21 * i + 7 * k);
    }
    this.ctx.gl.setPaintLeaves(e.mesh, out);
    this.ctx.requestFrame();
  }

  // Uploads each part in the list once.
  uploadAll(list) {
    for (const e of new Set(list)) this.upload(e);
  }

  // The ray of the camera through a pixel (CSS pixels of the canvas).
  ray(px, py) {
    const w = this.w;
    const dpr = window.devicePixelRatio || 1;
    if (!w.x.zs_view_ray(this.ctx.view.v, px * dpr, py * dpr, w.cell)) return null;
    return Array.from(new Float32Array(w.x.memory.buffer, w.cell, 6));
  }

  // The hit of a ray on one part: { e, tri, t, p }, or null.
  hitOn(e, ray) {
    if (!this.session(e)) return null;
    const w = this.w;
    const c = w.cell;
    new Float32Array(w.x.memory.buffer, c, 6).set(ray);
    if (!w.x.zs_paint_hit(e.s, c, c + 24, c + 28)) return null;
    const t = new Float32Array(w.x.memory.buffer, c + 28, 1)[0];
    return { e, tri: w.u32(c + 24), t, p: [ray[0] + ray[3] * t, ray[1] + ray[4] * t, ray[2] + ray[5] * t] };
  }

  // The first hit of a ray on all parts, or null. The boxes come in order
  // of distance, so the walk stops at the first box behind the best hit.
  hitAny(ray) {
    const list = [];
    for (const e of this.parts.values()) {
      const near = rayBox(ray, e.box);
      if (near !== Infinity) list.push({ e, near });
    }
    list.sort((a, b) => a.near - b.near);
    let best = null;
    for (const { e, near } of list) {
      if (best && near > best.t) break;
      const h = this.hitOn(e, ray);
      if (h && (!best || h.t < best.t)) best = h;
    }
    return best;
  }

  // The region of the smart select of a triangle: { e, id, tris }. A
  // region with the id `same` gives that one back, with no copy: a hover
  // over one region costs a lookup.
  region(e, tri, same = null) {
    const w = this.w;
    const c = w.cell;
    if (w.x.zs_paint_region(e.s, tri, c, c + 4, c + 8) !== 0) return null;
    const id = w.u32(c + 8);
    if (same && same.e === e && same.id === id) return same;
    const p = w.u32(c);
    const n = w.u32(c + 4);
    return { e, id, tris: new Uint32Array(w.x.memory.buffer, p, n).slice() };
  }

  fill(e, tris, state) {
    const w = this.w;
    const p = w.alloc(4 * tris.length);
    try {
      new Uint32Array(w.x.memory.buffer, p, tris.length).set(tris);
      return w.x.zs_paint_fill(e.s, p, tris.length, state);
    } finally {
      w.free(p, 4 * tris.length);
    }
  }

  // The paint of a part to the worker: it slices again.
  commit(e) {
    const w = this.w;
    if (w.x.zs_paint_text(e.s, w.cell, w.cell + 4) !== 0) return;
    const text = w.text(w.u32(w.cell), w.u32(w.cell + 4));
    const index = this.ctx.indexOf(e.id);
    if (index < 0) return;
    const gen = e.gen;
    e.pending++;
    const done = (r) => {
      e.pending--;
      if (gen === e.gen && r?.paintKey) e.paintKey = r.paintKey;
      if (e.pending === 0 && this.syncWanted && !this.syncing) this.sync();
    };
    this.ctx.client.call("paintSet", { index, text }).then(done, () => done(null));
  }

  // The state of a filament number on a part: its own filament is 0.
  stateOf(e, n) {
    return n === e.base ? 0 : n;
  }

  setFilament(n) {
    this.state = n;
    // The selection takes the new filament. Each part is one step of the
    // history.
    const changed = new Set();
    for (const r of this.selection) if (this.fill(r.e, r.tris, this.stateOf(r.e, n)) > 0) changed.add(r.e);
    for (const e of changed) this.commit(e);
    this.uploadAll(this.selection.map((r) => r.e));
    this.drawChips();
  }

  setActive(e) {
    if (this.active === e) return;
    this.active = e;
    this.labelPart();
    this.drawChips();
  }

  // The part under the pointer: the Inspector names it. The brush lights
  // the whole part, because it has no region to light.
  setOver(e) {
    if (this.over === e) return;
    this.over = e;
    this.ctx.gl.setPaintFocus(this.mode === "brush" ? e?.mesh ?? null : null);
    this.labelPart();
    this.ctx.requestFrame();
  }

  // The name of a part, with its number: copies have the same name.
  partName(e) {
    return `${e.name || "Part"} (part ${e.index + 1} of ${this.parts.size})`;
  }

  labelPart() {
    if (!this.partLine) return;
    const e = this.over ?? this.active;
    let text = "Click a part to paint it.";
    if (this.over && this.over !== this.active) text = `Under the pointer: ${this.partName(e)}`;
    else if (e) text = `Painting: ${this.partName(e)}`;
    if (this.partLine.textContent !== text) this.partLine.textContent = text;
    if (this.clearButton) {
      const a = this.active;
      this.clearButton.disabled = !a;
      this.clearButton.title = a ? `${this.partName(a)} prints with its own filament again` : "Click a part first";
    }
  }

  // The hover goes (the pointer left the parts, or the mode changed).
  clearHover() {
    const old = this.hover?.e;
    this.hover = null;
    this.setOver(null);
    if (old) this.upload(old);
  }

  attach() {
    const canvas = this.ctx.canvas;
    const at = (e) => {
      const r = canvas.getBoundingClientRect();
      return [e.clientX - r.left, e.clientY - r.top];
    };
    canvas.addEventListener("pointerdown", (e) => {
      if (!this.on || e.button !== 0) return;
      e.stopImmediatePropagation();
      e.preventDefault();
      const ray = this.ray(...at(e));
      const h = ray ? this.hitAny(ray) : null;
      if (this.mode === "smart") {
        if (!h) {
          const old = this.selection.map((r) => r.e);
          if (!e.shiftKey) this.selection = [];
          this.uploadAll(old);
          return;
        }
        const r = this.region(h.e, h.tri);
        if (!r) return;
        this.setActive(h.e);
        const old = this.selection.map((s) => s.e);
        if (e.shiftKey) {
          if (!this.selection.some((s) => s.e === r.e && s.id === r.id)) this.selection.push(r);
        } else this.selection = [r];
        if (this.fill(h.e, r.tris, this.stateOf(h.e, this.state)) > 0) this.commit(h.e);
        this.uploadAll([...old, h.e]);
        return;
      }
      canvas.setPointerCapture(e.pointerId);
      this.stroke = { e: h?.e ?? null, changed: 0 };
      if (h) {
        this.setActive(h.e);
        this.dab(h.p);
      }
    }, { capture: true });
    canvas.addEventListener("pointermove", (e) => {
      if (!this.on) return;
      const [px, py] = at(e);
      if (this.stroke) {
        e.stopImmediatePropagation();
        const ray = this.ray(px, py);
        if (!ray) return;
        // A stroke that starts off the parts takes the first part it meets.
        const h = this.stroke.e ? this.hitOn(this.stroke.e, ray) : this.hitAny(ray);
        if (h) {
          if (!this.stroke.e) {
            this.stroke.e = h.e;
            this.setActive(h.e);
          }
          this.dab(h.p);
        }
        return;
      }
      if (e.buttons !== 0) return;
      const ray = this.ray(px, py);
      const h = ray ? this.hitAny(ray) : null;
      this.setOver(h?.e ?? null);
      if (this.mode !== "smart") return;
      const r = h ? this.region(h.e, h.tri, this.hover) : null;
      if (r === this.hover) return;
      const old = this.hover?.e;
      this.hover = r;
      this.uploadAll([old, r?.e]);
    }, { capture: true });
    canvas.addEventListener("pointerleave", () => {
      if (this.on && !this.stroke) this.clearHover();
    });
    const end = (e) => {
      if (!this.on || !this.stroke) return;
      e.stopImmediatePropagation();
      const { e: part, changed } = this.stroke;
      this.stroke = null;
      if (part && changed > 0) this.commit(part);
      if (this.syncWanted) this.sync();
    };
    canvas.addEventListener("pointerup", end, { capture: true });
    canvas.addEventListener("pointercancel", end, { capture: true });
  }

  // One step of the brush at a point of the surface of the stroke's part.
  dab(p) {
    const e = this.stroke.e;
    const n = this.w.x.zs_paint_brush(e.s, p[0], p[1], p[2], this.size, this.stateOf(e, this.state), Math.max(0.1, this.size / 6));
    if (n > 0) {
      this.stroke.changed += n;
      this.upload(e);
    }
  }

  // Takes all paint off the active part.
  clearAll() {
    const e = this.active;
    if (!e || !this.session(e)) return;
    const all = new Uint32Array(e.nf);
    for (let i = 0; i < e.nf; i++) all[i] = i;
    if (this.fill(e, all, 0) > 0) this.commit(e);
    const old = this.selection.map((r) => r.e);
    this.selection = [];
    this.uploadAll([...old, e]);
  }

  buildCard() {
    const card = el("div", "part-card paint-card");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", "Paint");
    const head = el("div", "lc-head");
    const title = el("div", "lc-title", "Paint");
    const close = el("button", "flat icon lc-close", "×");
    close.title = "Close the Paint tool (P or Esc)";
    close.setAttribute("aria-label", "Close");
    close.onclick = () => this.close();
    head.append(title, close);
    this.partLine = el("div", "lc-size paint-part", "");
    const modes = el("div", "pc-actions paint-modes");
    const mode = (name, label, tip) => {
      const b = el("button", "pc-action", label);
      b.title = tip;
      b.classList.toggle("on", this.mode === name);
      b.onclick = () => {
        this.clearHover();
        this.mode = name;
        for (const x of modes.children) x.classList.toggle("on", x === b);
        size.hidden = name !== "brush";
        this.hint.textContent = this.hintText();
      };
      modes.append(b);
    };
    mode("smart", "Smart select", "Click a region of any part: a raised letter, a logo, or a face. Shift and a click add regions.");
    mode("brush", "Brush", "Drag over the surface of any part to paint it.");
    const size = el("label", "pc-cut-row paint-size");
    const slider = Object.assign(document.createElement("input"), { type: "range", min: "0.3", max: "10", step: "0.1", value: String(this.size) });
    const num = el("span", "dim", `${this.size.toFixed(1)} mm`);
    slider.oninput = () => {
      this.size = Number(slider.value);
      num.textContent = `${this.size.toFixed(1)} mm`;
    };
    size.append("Size ", slider, num);
    size.hidden = this.mode !== "brush";
    this.chips = el("div", "fil-editor paint-chips");
    const clear = el("button", "flat pc-add", "Remove all paint");
    clear.onclick = () => this.clearAll();
    this.clearButton = clear;
    this.hint = el("div", "dim caption", this.hintText());
    card.append(head, this.partLine, modes, size, el("div", "pc-heading", "Filament"), this.chips, this.hint, clear);
    card.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !e.target.closest("input, select, textarea")) {
        e.preventDefault();
        e.stopPropagation();
        this.close();
      }
    });
    this.ctx.cardHost.append(card);
    this.card = card;
    this.ctx.reveal?.();
    this.labelPart();
    this.drawChips();
  }

  hintText() {
    return this.mode === "smart"
      ? "Click a raised letter, a logo, or a face of any part to paint it. Shift and a click add more. Right drag turns the view."
      : "Drag over the surface of any part to paint it. Right drag turns the view.";
  }

  drawChips() {
    if (!this.chips) return;
    const base = this.active?.base;
    const list = filaments();
    const chips = list.map((f) => {
      const b = document.createElement("button");
      b.className = "fil-chip";
      b.classList.toggle("on", f.index + 1 === this.state);
      b.style.background = f.color;
      b.style.color = inkOn(f.color);
      b.textContent = String(f.index + 1);
      b.title = `Paint with filament ${f.index + 1} (${f.material}, ${f.color})${f.index + 1 === base ? ": the filament of the part" : ""}`;
      b.onclick = () => this.setFilament(f.index + 1);
      return b;
    });
    const plus = document.createElement("button");
    plus.className = "fil-chip fil-add";
    plus.textContent = "+";
    plus.title = "Add a filament to the plate";
    plus.onclick = async () => {
      const i = await this.ctx.addFilament();
      if (i >= 0) {
        this.colors();
        this.setFilament(i + 1);
      }
    };
    chips.push(plus);
    this.chips.replaceChildren(...chips);
  }

  // After a new slice or a new list of filaments: the palette again, and
  // the parts if they changed.
  refresh() {
    if (!this.on) return;
    this.colors();
    this.drawChips();
    this.sync();
    this.ctx.requestFrame();
  }
}
