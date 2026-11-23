// selection.js: the page side of the selection model of the core
// (src/app/selection.zig, the zs_sel_* calls). The page keeps no other copy
// of the active plate, the selected parts, or the selected line.
//
// The model is in the wasm instance of the page, so a click, a pick, and a
// drag need no reply of the worker. The worker owns the plates. It sends
// the table of the parts (the "parts" event), and client.js tells the model
// which requests have their reply (answered).
//
// See docs/internals/selection.md.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// The size of zs_sel_part: a u64 id and six doubles.
const PART_BYTES = 56;

export const SEL_REPLACE = 0;
export const SEL_ADD = 1;
export const SEL_TOGGLE = 2;
export const SEL_REMOVE = 3;

export const FRAME_ALL = -1;

export class SelectionModel {
  constructor(wasm) {
    this.w = wasm;
    this.x = wasm.x;
    if (this.x.zs_sel_new(wasm.cell) !== 0) throw new Error("zslice: no selection model");
    this.s = wasm.u32(wasm.cell);
    // Fixed room for the answers, so a read on each frame allocates
    // nothing.
    this.out = (wasm.alloc(PART_BYTES + 8) + 7) & ~7;
  }

  get gen() { return Number(this.x.zs_sel_generation(this.s)); }

  // ---- from the worker ----

  // A table of zs_sel_part (an ArrayBuffer).
  setParts(buffer) {
    const b = new Uint8Array(buffer);
    this.w.withBytes(b.length ? b : new Uint8Array(8), (p) => this.x.zs_sel_set_parts(this.s, p, b.length / PART_BYTES));
  }

  // The parts of the slice that the view shows now.
  setScene(buffer) {
    const b = new Uint8Array(buffer);
    this.w.withBytes(b.length ? b : new Uint8Array(8), (p) => this.x.zs_sel_set_scene(this.s, p, b.length / PART_BYTES));
  }

  reportPlate(active, count) { this.x.zs_sel_plate_report(this.s, active, count); }
  answered(gen) { this.x.zs_sel_answered(this.s, BigInt(gen)); }

  // ---- the plate ----

  get plate() { return this.x.zs_sel_plate(this.s); }
  requestPlate(i) { this.x.zs_sel_plate_request(this.s, i); }

  // ---- the parts ----

  select(id, mode = SEL_REPLACE) { this.x.zs_sel_select(this.s, BigInt(id), mode); }
  clear() { this.x.zs_sel_clear(this.s); }
  get count() { return this.x.zs_sel_count(this.s); }
  get primary() { return Number(this.x.zs_sel_primary(this.s)); }
  has(id) { return this.x.zs_sel_has(this.s, BigInt(id)) === 1; }

  ids() {
    const out = [];
    const n = this.count;
    for (let k = 0; k < n; k++) out.push(Number(this.x.zs_sel_get(this.s, k)));
    return out;
  }

  // The index of a part on the plate now, or -1.
  indexOf(id) { return this.x.zs_sel_part_index(this.s, BigInt(id)); }

  // The id of the part at an index of the plate now, or 0.
  idAt(index) { return Number(this.x.zs_sel_part_at(this.s, index)); }

  // The box of a part at its current place, or null.
  box(id) {
    const w = this.w;
    const p = this.out;
    if (this.x.zs_sel_part_box(this.s, BigInt(id), p) !== 1) return null;
    return { id, x0: w.f64(p + 8), y0: w.f64(p + 16), z0: w.f64(p + 24), x1: w.f64(p + 32), y1: w.f64(p + 40), z1: w.f64(p + 48) };
  }

  place(id, x, y, z) { return this.x.zs_sel_place(this.s, BigInt(id), x, y, z) === 0; }

  // The id of the part under a device pixel, or 0.
  pick(view, px, py) { return Number(this.x.zs_sel_pick(this.s, view.v, px, py)); }

  // ---- the line ----

  line() {
    const w = this.w;
    const p = this.out;
    this.x.zs_sel_line_get(this.s, p, p + 8, p + 12);
    return { key: w.dv.getBigUint64(p >>> 0, true), path: w.i32(p + 8), seg: w.i32(p + 12) };
  }

  setLine(key, path, seg) { this.x.zs_sel_line_set(this.s, BigInt(key), path, seg); }
  lineFound(path, segments) { this.x.zs_sel_line_found(this.s, path, segments); }

  // ---- the tool and the camera ----

  get tool() { return this.x.zs_sel_tool(this.s); }
  set tool(t) { this.x.zs_sel_tool_set(this.s, t); }

  frame(target) { this.x.zs_sel_frame_request(this.s, target); }

  // The camera target that is due now, or null.
  takeFrame() {
    const c = this.w.cell;
    return this.x.zs_sel_frame_take(this.s, c) === 1 ? this.w.i32(c) : null;
  }
}
