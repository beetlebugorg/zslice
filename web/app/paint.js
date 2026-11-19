// paint.js: the Paint tool (P). It paints filaments on the surface of a
// part, for a print with more than one filament.
//
// The tool shows the mesh of the part (gl.js, setPaintMesh) in place of
// the beads, each triangle in the color of its filament. Two modes:
//
// - Smart select: the region under the pointer lights before the click.
//   A click paints the region with the filament of the card. A region is
//   a part of the mesh that stands out of its surface or sinks into it
//   (a raised letter: its top and its sides), else a flat or smooth face
//   (src/paint.zig, Features). Shift and a click add a region to the
//   selection; a chip of another filament then paints all of it.
// - Brush: a left drag paints a sphere of the brush size along the
//   pointer. Triangles on the edge of the sphere split, so the border is
//   clean.
//
// A right drag turns the view and a middle drag pans, as in the other
// tools (input.js). Each hover and each step of the brush is a call to
// the paint session of the view (zs_paint_*, on this thread), with no
// wait for the worker, so it keeps the frame rate. The end of a click or
// a stroke sends the paint to the worker (paintSet), and it slices. The
// view shows the beads again when the tool closes.
//
// The card of the tool sits at the left, next to the tools, so it never
// covers the part.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { filaments, inkOn } from "./filaments.js";

function rgb(hex) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || "");
  if (!m) return [0.82, 0.82, 0.8];
  return m.slice(1).map((h) => parseInt(h, 16) / 255);
}

export class PaintTool {
  // ctx: { client, view (View3D), gl (GlRenderer), canvas, host (the
  //        element of the view), part() (the index of the part to paint),
  //        partFilament(i) -> Promise<number> (its filament, from 1),
  //        requestFrame(), toast(text), button (the tool button),
  //        addFilament() -> Promise<index> }
  constructor(ctx) {
    this.ctx = ctx;
    this.on = false;
    this.s = 0; // the paint session (zs_paint)
    this.mode = "smart";
    this.size = 2; // the radius of the brush, mm
    this.state = 2; // the filament to paint with (from 1)
    this.hover = null; // { id, tris: Uint32Array }
    this.selection = []; // regions: { id, tris }
    this.stroke = null;
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
    if (this.on) return;
    const index = this.ctx.part();
    if (index < 0) {
      this.ctx.toast("Open a model to paint it.");
      return;
    }
    const r = await this.ctx.client.call("paintOpen", { index });
    if (r.error || !r.faces?.length) {
      this.ctx.toast(r.error || "The part has no mesh.");
      return;
    }
    this.index = index;
    this.base = await this.ctx.partFilament(index);
    this.verts = r.verts;
    this.faces = r.faces;
    const w = this.w;
    const x = w.x;
    const vp = w.alloc(r.verts.byteLength);
    const fp = w.alloc(r.faces.byteLength);
    try {
      new Float32Array(x.memory.buffer, vp, r.verts.length).set(r.verts);
      new Uint32Array(x.memory.buffer, fp, r.faces.length).set(r.faces);
      if (x.zs_paint_new(vp, r.verts.length / 3, fp, r.faces.length / 3, w.cell) !== 0) {
        this.ctx.toast("The paint tool cannot open this part.");
        return;
      }
    } finally {
      w.free(vp, r.verts.byteLength);
      w.free(fp, r.faces.byteLength);
    }
    this.s = w.u32(w.cell);
    if (r.text) w.withBytes(new TextEncoder().encode(r.text), (p, n) => x.zs_paint_set_text(this.s, p, n));
    // The mesh for the GPU: the points of each triangle and its normal.
    const nf = r.faces.length / 3;
    const pos = new Float32Array(9 * nf);
    const nrm = new Float32Array(3 * nf);
    const v = r.verts;
    for (let t = 0; t < nf; t++) {
      const a = 3 * r.faces[3 * t], b = 3 * r.faces[3 * t + 1], c = 3 * r.faces[3 * t + 2];
      pos.set([v[a], v[a + 1], v[a + 2], v[b], v[b + 1], v[b + 2], v[c], v[c + 1], v[c + 2]], 9 * t);
      const ux = v[b] - v[a], uy = v[b + 1] - v[a + 1], uz = v[b + 2] - v[a + 2];
      const wx = v[c] - v[a], wy = v[c + 1] - v[a + 1], wz = v[c + 2] - v[a + 2];
      const nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
      const len = Math.hypot(nx, ny, nz) || 1;
      nrm.set([nx / len, ny / len, nz / len], 3 * t);
    }
    this.nf = nf;
    this.vstates = new Uint8Array(3 * nf);
    this.ctx.gl.setPaintMesh(pos, nrm);
    this.on = true;
    if (this.state === this.base) this.state = filaments().length > 1 ? (this.base === 1 ? 2 : 1) : 1;
    this.colors();
    this.upload();
    this.buildCard();
    this.ctx.button?.classList.add("on");
    this.ctx.requestFrame();
  }

  close() {
    if (!this.on) return;
    this.on = false;
    this.ctx.gl.setPaintMesh(null);
    if (this.s) this.w.x.zs_paint_free(this.s);
    this.s = 0;
    this.hover = null;
    this.selection = [];
    this.card?.remove();
    this.card = null;
    this.ctx.button?.classList.remove("on");
    this.ctx.requestFrame();
  }

  // The palette of the shader: 0 the filament of the part, k filament k.
  colors() {
    const list = filaments();
    const cols = [rgb(list[(this.base || 1) - 1]?.color ?? list[0].color)];
    for (let k = 1; k <= 17; k++) cols.push(rgb(list[k - 1]?.color ?? list[0].color));
    this.ctx.gl.setPaintColors(cols);
  }

  // The states of the triangles to the GPU, with the light of the
  // region under the pointer and of the selection.
  upload() {
    const w = this.w;
    const n = w.x.zs_paint_states(this.s, w.cell);
    const p = w.u32(w.cell);
    const st = new Uint8Array(w.x.memory.buffer, p, n);
    const vs = this.vstates;
    for (let t = 0; t < n; t++) {
      const s = st[t];
      vs[3 * t] = vs[3 * t + 1] = vs[3 * t + 2] = s;
    }
    const lit = (tris) => {
      for (const t of tris) if (vs[3 * t] !== 255) vs[3 * t] = vs[3 * t + 1] = vs[3 * t + 2] = vs[3 * t] | 128;
    };
    if (this.hover) lit(this.hover.tris);
    for (const r of this.selection) lit(r.tris);
    this.ctx.gl.setPaintStates(vs);
    // The pieces of the split triangles.
    const nl = w.x.zs_paint_leaves(this.s, w.cell);
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
    this.ctx.gl.setPaintLeaves(out);
    this.ctx.requestFrame();
  }

  // The triangle under a pixel (CSS pixels of the canvas), or -1.
  hit(px, py) {
    const w = this.w;
    const x = w.x;
    const dpr = window.devicePixelRatio || 1;
    const c = w.cell;
    if (!x.zs_view_ray(this.ctx.view.v, px * dpr, py * dpr, c)) return { tri: -1 };
    if (!x.zs_paint_hit(this.s, c, c + 24, c + 28)) return { tri: -1 };
    const f = new Float32Array(x.memory.buffer, c, 8);
    const t = f[7];
    return { tri: w.u32(c + 24), p: [f[0] + f[3] * t, f[1] + f[4] * t, f[2] + f[5] * t] };
  }

  // The region of the smart select of a triangle: { id, tris }. A region
  // with the id `same` gives that one back, with no copy: a hover over
  // one region costs a lookup.
  region(tri, same = null) {
    const w = this.w;
    const c = w.cell;
    if (w.x.zs_paint_region(this.s, tri, c, c + 4, c + 8) !== 0) return null;
    const id = w.u32(c + 8);
    if (same && same.id === id) return same;
    const p = w.u32(c);
    const n = w.u32(c + 4);
    return { id, tris: new Uint32Array(w.x.memory.buffer.slice(p, p + 4 * n)) };
  }

  fill(tris, state) {
    const w = this.w;
    const p = w.alloc(4 * tris.length);
    try {
      new Uint32Array(w.x.memory.buffer, p, tris.length).set(tris);
      return w.x.zs_paint_fill(this.s, p, tris.length, state);
    } finally {
      w.free(p, 4 * tris.length);
    }
  }

  // The paint to the worker: it slices again.
  commit() {
    const w = this.w;
    if (w.x.zs_paint_text(this.s, w.cell, w.cell + 4) !== 0) return;
    const text = w.text(w.u32(w.cell), w.u32(w.cell + 4));
    this.ctx.client.call("paintSet", { index: this.index, text });
  }

  // The state of a filament number: the filament of the part is 0.
  stateOf(n) {
    return n === this.base ? 0 : n;
  }

  setFilament(n) {
    this.state = n;
    // The selection takes the new filament.
    let changed = 0;
    for (const r of this.selection) changed += this.fill(r.tris, this.stateOf(n));
    if (changed > 0) this.commit();
    this.upload();
    this.drawChips();
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
      const [px, py] = at(e);
      const h = this.hit(px, py);
      if (this.mode === "smart") {
        if (h.tri < 0) {
          if (!e.shiftKey) this.selection = [];
          this.upload();
          return;
        }
        const r = this.region(h.tri);
        if (!r) return;
        if (e.shiftKey) {
          if (!this.selection.some((s) => s.id === r.id)) this.selection.push(r);
        } else this.selection = [r];
        if (this.fill(r.tris, this.stateOf(this.state)) > 0) this.commit();
        this.upload();
        return;
      }
      canvas.setPointerCapture(e.pointerId);
      this.stroke = { changed: 0 };
      if (h.tri >= 0) this.dab(h.p);
    }, { capture: true });
    canvas.addEventListener("pointermove", (e) => {
      if (!this.on) return;
      const [px, py] = at(e);
      if (this.stroke) {
        e.stopImmediatePropagation();
        const h = this.hit(px, py);
        if (h.tri >= 0) this.dab(h.p);
        return;
      }
      if (e.buttons !== 0) return;
      if (this.mode !== "smart") return;
      const h = this.hit(px, py);
      const r = h.tri >= 0 ? this.region(h.tri, this.hover) : null;
      if (r === this.hover) return;
      this.hover = r;
      this.upload();
    }, { capture: true });
    const end = (e) => {
      if (!this.on || !this.stroke) return;
      e.stopImmediatePropagation();
      if (this.stroke.changed > 0) this.commit();
      this.stroke = null;
    };
    canvas.addEventListener("pointerup", end, { capture: true });
    canvas.addEventListener("pointercancel", end, { capture: true });
  }

  // One step of the brush at a point of the surface.
  dab(p) {
    const n = this.w.x.zs_paint_brush(this.s, p[0], p[1], p[2], this.size, this.stateOf(this.state), Math.max(0.1, this.size / 6));
    if (n > 0) {
      this.stroke.changed += n;
      this.upload();
    }
  }

  clearAll() {
    const all = new Uint32Array(this.nf);
    for (let i = 0; i < this.nf; i++) all[i] = i;
    if (this.fill(all, 0) > 0) this.commit();
    this.selection = [];
    this.upload();
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
    const modes = el("div", "pc-actions paint-modes");
    const mode = (name, label, tip) => {
      const b = el("button", "pc-action", label);
      b.title = tip;
      b.classList.toggle("on", this.mode === name);
      b.onclick = () => {
        this.mode = name;
        this.hover = null;
        for (const x of modes.children) x.classList.toggle("on", x === b);
        size.hidden = name !== "brush";
        this.hint.textContent = this.hintText();
        this.upload();
      };
      modes.append(b);
    };
    mode("smart", "Smart select", "Click a region: a raised letter, a logo, or a face. Shift and a click add regions.");
    mode("brush", "Brush", "Drag over the surface to paint it.");
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
    clear.title = "The whole part prints with its own filament again";
    clear.onclick = () => this.clearAll();
    this.hint = el("div", "dim caption", this.hintText());
    card.append(head, modes, size, el("div", "pc-heading", "Filament"), this.chips, this.hint, clear);
    card.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !e.target.closest("input, select, textarea")) {
        e.preventDefault();
        e.stopPropagation();
        this.close();
      }
    });
    this.ctx.host.append(card);
    this.card = card;
    this.drawChips();
  }

  hintText() {
    return this.mode === "smart"
      ? "Click a raised letter, a logo, or a face to paint it. Shift and a click add more. Right drag turns the view."
      : "Drag over the surface to paint it. Right drag turns the view.";
  }

  drawChips() {
    if (!this.chips) return;
    const list = filaments();
    const chips = list.map((f) => {
      const b = document.createElement("button");
      b.className = "fil-chip";
      b.classList.toggle("on", f.index + 1 === this.state);
      b.style.background = f.color;
      b.style.color = inkOn(f.color);
      b.textContent = String(f.index + 1);
      b.title = `Paint with filament ${f.index + 1} (${f.material}, ${f.color})${f.index + 1 === this.base ? ": the filament of the part" : ""}`;
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

  // After a new list of filaments (a new color): the palette again.
  refresh() {
    if (!this.on) return;
    this.colors();
    this.drawChips();
    this.ctx.requestFrame();
  }
}
