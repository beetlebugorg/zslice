// view.js: the 3D view of the main thread. The scene and the camera are in
// the core (src/render/view.zig, in web mode); this file calls them, and
// reads the frame data (zs_web_frame) for the WebGL drawing (gl.js).
//
// The view gets its beads from the worker as bytes (zs_view_scene_read),
// so the camera moves at once, also while the worker slices.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { statusText } from "./wasm.js";

// (size_t)-1 of the C API comes to JavaScript as -1 (an i32 on wasm32).
const NONE = -1;

export const MODES = ["Filament", "Feature", "Speed", "Flow", "Layer time", "Line width"];

// A view of the frame data f[name]: n items of `bytes` bytes at ptr, made
// again only when ptr or n changes (f.keys keeps them, at `slot`).
function frameView(f, slot, ptr, n, Type, bytes, name) {
  const key = f.keys;
  if (key[slot] !== ptr || key[slot + 1] !== n || !f[name]) {
    key[slot] = ptr;
    key[slot + 1] = n;
    f[name] = new Type(f.buf, ptr, (n * bytes) / Type.BYTES_PER_ELEMENT);
  }
}

export class View3D {
  constructor(wasm, width, height) {
    this.w = wasm;
    this.x = wasm.x;
    this.v = wasm.newView(width, height);
    this.loaded = false;
    // The answer of a pick or a step: [path, segment].
    this.hit = new Int32Array(2);
  }

  resize(width, height) { this.x.zs_view_resize(this.v, width, height); }

  // Reads a scene of the worker (an ArrayBuffer).
  readScene(buffer) {
    const bytes = new Uint8Array(buffer);
    const rc = this.w.withBytes(bytes, (p, n) => this.x.zs_view_scene_read(this.v, p, n));
    if (rc !== 0) throw new Error(`zslice: the scene did not load (${statusText(rc)})`);
    this.loaded = true;
  }

  // The bed model of model i of the printer library `lib` (a pointer in
  // this instance): the bytes of its files (Uint8Array or null).
  setBed(lib, i, mesh, texture) {
    const w = this.w;
    const mp = mesh?.length ? w.alloc(mesh.length) : 0;
    const tp = texture?.length ? w.alloc(texture.length) : 0;
    try {
      if (mp) w.u8.set(mesh, mp);
      if (tp) w.u8.set(texture, tp);
      return this.x.zs_view_set_bed(this.v, lib, i, mp, mesh?.length ?? 0, tp, texture?.length ?? 0);
    } finally {
      if (mp) w.free(mp, mesh.length);
      if (tp) w.free(tp, texture.length);
    }
  }
  clearBed() { this.x.zs_view_clear_bed(this.v); }

  // ---- the plate set (src/render/plates.zig) ----

  // The plates of the row: the bed size [x, y] of each, and the active
  // plate. The camera moves with the world, so the picture stays still.
  setPlates(beds, active) {
    const w = this.w;
    const n = beds.length;
    const p = n ? w.alloc(8 * n) : 0;
    try {
      const f = new Float32Array(this.x.memory.buffer, p, 2 * n);
      beds.forEach((b, i) => { f[2 * i] = b[0]; f[2 * i + 1] = b[1]; });
      const rc = this.x.zs_view_set_plates(this.v, n, active, p);
      if (rc !== 0) throw new Error(`zslice: the plates did not set (${statusText(rc)})`);
    } finally {
      if (p) w.free(p, 8 * n);
    }
  }
  // The beads of plate i from a scene of the worker (an ArrayBuffer).
  plateScene(i, buffer) {
    const rc = this.w.withBytes(new Uint8Array(buffer), (p, n) => this.x.zs_view_plate_scene_read(this.v, i, p, n));
    if (rc !== 0) throw new Error(`zslice: the plate scene did not load (${statusText(rc)})`);
  }
  plateClear(i) { this.x.zs_view_plate_clear(this.v, i); }
  // Plate i as the footprints of its parts: boxes [[x0, y0, x1, y1]].
  plateOutline(i, boxes) {
    const w = this.w;
    const n = boxes.length;
    const p = n ? w.alloc(16 * n) : 0;
    try {
      if (n) new Float32Array(this.x.memory.buffer, p, 4 * n).set(boxes.flat());
      this.x.zs_view_plate_outline(this.v, i, n, p);
    } finally {
      if (p) w.free(p, 16 * n);
    }
  }
  // flags: 1 stale, 2 the bed model of the view, 4 cannot slice.
  plateFlags(i, flags) { this.x.zs_view_plate_flags(this.v, i, flags); }
  // The plate under a pixel, or -1.
  plateAt(px, py) { return Number(this.x.zs_view_plate_at(this.v, px, py)); }
  // The origin of the bed of plate i in the world of the view: [x, y].
  plateOrigin(i) {
    const c = this.w.cell;
    this.x.zs_view_plate_origin(this.v, i, c, c + 8);
    return [this.w.f64(c), this.w.f64(c + 8)];
  }
  // The pixel of a point of the world (mm): [px, py], or null behind the
  // camera.
  pixelOf(x, y, z) {
    const c = this.w.cell;
    if (!this.x.zs_view_pixel_of(this.v, x, y, z, c, c + 4)) return null;
    const f = this.w.mf32;
    return [f[c >>> 2], f[(c >>> 2) + 1]];
  }
  // Moves the camera to plate i, or to all plates (i < 0).
  framePlate(i) { this.x.zs_view_frame_plate(this.v, i < 0 ? -1 : i); }

  setLayerRange(lo, hi) { this.x.zs_view_set_layer_range(this.v, lo, hi); }
  orbit(dx, dy) { this.x.zs_view_orbit(this.v, dx, dy); }
  rotate(dx, dy) { this.x.zs_view_rotate(this.v, dx, dy); }
  pan(dx, dy) { this.x.zs_view_pan(this.v, dx, dy); }
  zoomAt(factor, px, py) { this.x.zs_view_zoom_at(this.v, factor, px, py); }
  resetSmooth() { this.x.zs_view_reset_smooth(this.v); }
  // Moves the camera for dt seconds. True while it still moves.
  animate(dt) { return this.x.zs_view_animate(this.v, dt) !== 0; }
  // A bit for each feature in focus (0: none); zmax < 0: all layers.
  focus(features, zmax) { this.x.zs_view_focus(this.v, features >>> 0, zmax); }
  setTime(t) { this.x.zs_view_set_time(this.v, t); }
  duration() { return this.x.zs_view_duration(this.v); }
  layerAtTime(t) { return this.x.zs_view_layer_at_time(this.v, t); }

  // ---- the selection ----

  // The path and the segment under a pixel: sets this.hit = [path, seg]
  // and returns true, or returns false. No new object for a pick.
  pickSegment(px, py) {
    const c = this.w.cell;
    const p = this.x.zs_view_pick_segment(this.v, px, py, c);
    if (p === NONE) return false;
    this.hit[0] = p;
    this.hit[1] = this.w.m32[c >>> 2];
    return true;
  }

  // The same in the 2D view: the path of `layer` at (x, y) mm.
  pickLayer(layer, x, y) {
    const c = this.w.cell;
    const p = this.x.zs_view_pick_layer(this.v, layer, x, y, c);
    if (p === NONE) return false;
    this.hit[0] = p;
    this.hit[1] = this.w.m32[c >>> 2];
    return true;
  }

  // Highlights a path (-1: none), its segment (-1: none), and with
  // `isolate` shows the other beads as ghosts.
  highlight(path, seg, isolate) {
    this.x.zs_view_highlight(this.v, path < 0 ? NONE : path);
    if (path >= 0) this.x.zs_view_highlight_segment(this.v, path, seg);
    this.x.zs_view_isolate(this.v, isolate && path >= 0 ? 1 : 0);
  }

  // Ranges of instances [first, end) into `out` (a 2-item typed array).
  range(fn, i, out) {
    const c = this.w.cell;
    fn(this.v, i, c, c + 4);
    const m = this.w.m32;
    out[0] = m[c >>> 2];
    out[1] = m[(c >>> 2) + 1];
    return out;
  }
  layerBeads(layer, out) { return this.range(this.x.zs_view_layer_beads, layer, out); }
  layerMarks(layer, out) { return this.range(this.x.zs_view_layer_marks, layer, out); }
  pathBeads(path, out) { return this.range(this.x.zs_view_path_beads, path, out); }
  pathLayer(path) { return this.x.zs_view_path_layer(this.v, path); }
  pathSegments(path) { return this.x.zs_view_path_segments(this.v, path); }

  // One step along the print (the keys h and l). Sets this.hit, or
  // returns false at an end of the print. seg < 0: the whole path.
  step(path, seg, dir, wholePath) {
    const c = this.w.cell;
    const m = this.w.m32;
    m[c >>> 2] = path;
    this.w.mi32[(c >>> 2) + 1] = seg;
    if (!this.x.zs_view_step(this.v, c, c + 4, dir, wholePath ? 1 : 0)) return false;
    this.hit[0] = this.w.m32[c >>> 2];
    this.hit[1] = this.w.mi32[(c >>> 2) + 1];
    return true;
  }

  nearestOnLayer(path, layer) {
    const p = this.x.zs_view_nearest_on_layer(this.v, path, layer);
    return p === NONE ? -1 : p;
  }

  segmentEndTime(path, seg) { return this.x.zs_view_segment_end_time(this.v, path, Math.max(0, seg)); }

  // The segment that prints at time t: sets this.hit.
  segmentAtTime(t) {
    const c = this.w.cell;
    if (!this.x.zs_view_segment_at_time(this.v, t, c, c + 4)) return false;
    const m = this.w.m32;
    this.hit[0] = m[c >>> 2];
    this.hit[1] = m[(c >>> 2) + 1];
    return true;
  }

  // The start point of bead b (x, y in mm), from the instances of the
  // last frame.
  beadPoint(b) {
    const p = this.x.zs_view_web_frame(this.v);
    const m = this.w.m32;
    const inst = m[(p + 240 + 32) >>> 2];
    const f = new Float32Array(this.x.memory.buffer, inst + b * 32, 2);
    return { x: f[0], y: f[1] };
  }

  // The box of the beads (min x, min y, max x, max y in mm), or null.
  bounds() {
    const c = this.w.cell;
    if (this.x.zs_view_bounds(this.v, c) !== 0) return null;
    const f = this.w.mf64;
    return [f[c >>> 3], f[(c >>> 3) + 1], f[(c >>> 3) + 2], f[(c >>> 3) + 3]];
  }

  // The outlines of all layers, as copies (for the GPU, once a slice).
  outlines() {
    const c = this.w.cell;
    this.x.zs_view_outlines(this.v, c, c + 4, c + 8, c + 12, c + 16, c + 20);
    const m = this.w.m32;
    const k = c >>> 2;
    const buf = this.x.memory.buffer;
    return {
      points: new Float32Array(buf, m[k], m[k + 1] * 2).slice(),
      ringEnds: new Uint32Array(buf, m[k + 2], m[k + 3]).slice(),
      layerEnds: new Uint32Array(buf, m[k + 4], m[k + 5]).slice(),
    };
  }

  legend() {
    const c = this.w.cell;
    if (!this.x.zs_view_legend(this.v, c, c + 8)) return null;
    return [this.w.f64(c), this.w.f64(c + 8)];
  }

  // Computes one frame, and returns its data: views into wasm memory, valid
  // until the next call into the module. The object and its views stay the
  // same from frame to frame; a view is made again only when its place or
  // its size in memory changes, so a frame allocates nothing.
  frame() {
    this.x.zs_view_draw(this.v);
    const p = this.x.zs_view_web_frame(this.v);
    const buf = this.x.memory.buffer;
    const m = this.w.m32;
    const k = (p + 240) >>> 2;
    let f = this.f;
    if (!f || f.buf !== buf || f.p !== p) {
      f = this.f = {
        buf, p, keys: new Uint32Array(24).fill(0xffffffff),
        box: new Float32Array(buf, p, 28),
        grid: new Float32Array(buf, p + 112, 28),
        clear: new Float32Array(buf, p + 224, 4),
        bed: new Float32Array(buf, p + 352, 28),
        bedVerts: null, bedTex: null,
        extras: null, head: null, instances: null, meshVerts: null, meshIndex: null, gridPoints: null, draws: null,
      };
    }
    f.boxFirst = m[k];
    f.boxCount = m[k + 1];
    f.markFirst = m[k + 2];
    f.markCount = m[k + 3];
    f.extrasCount = m[k + 5];
    frameView(f, 0, m[k + 4], f.extrasCount, Uint8Array, 32, "extras");
    f.headCount = m[k + 7];
    frameView(f, 2, m[k + 6], f.headCount, Uint8Array, 32, "head");
    f.instanceCount = m[k + 9];
    f.instancesGen = m[k + 10];
    frameView(f, 4, m[k + 8], f.instanceCount, Uint8Array, 32, "instances");
    frameView(f, 6, m[k + 11], m[k + 12], Float32Array, 16, "meshVerts");
    frameView(f, 8, m[k + 13], m[k + 14], Uint16Array, 2, "meshIndex");
    f.meshGen = m[k + 15];
    f.gridVertices = m[k + 17];
    frameView(f, 10, m[k + 16], f.gridVertices, Float32Array, 12, "gridPoints");
    f.gridGen = m[k + 18];
    f.width = m[k + 19];
    f.height = m[k + 20];
    // The ranges of beads to draw: first, count, and the mesh (0 full,
    // 1 and 2 coarser) of each.
    f.drawsCount = m[k + 22];
    frameView(f, 12, m[k + 21], f.drawsCount, Uint32Array, 12, "draws");
    f.meshFullCount = m[k + 23];
    // The meshes of lod 1 and 2: first index and count.
    f.lod1First = m[k + 24];
    f.lod2First = m[k + 25];
    f.lod1Count = m[k + 26];
    f.lod2Count = m[k + 27];
    // The bed model (k + 28 .. k + 55 is its push data).
    f.bedVertexCount = m[k + 57];
    frameView(f, 14, m[k + 56], f.bedVertexCount, Float32Array, 32, "bedVerts");
    f.bedVertices = m[k + 58];
    f.bedGen = m[k + 59];
    f.bedTexWidth = m[k + 61];
    f.bedTexHeight = m[k + 62];
    frameView(f, 16, m[k + 60], f.bedTexWidth * f.bedTexHeight, Uint8Array, 4, "bedTex");
    // The other plates (zs_web_plate, 40 words each) and their draws.
    // gl.js reads the plates from all memory (f.m32, f.mf32) at f.plates.
    f.plates = m[k + 63];
    f.platesCount = m[k + 64];
    f.plateDrawsCount = m[k + 66];
    frameView(f, 18, m[k + 65], f.plateDrawsCount, Uint32Array, 12, "plateDraws");
    f.plateGridVertices = m[k + 68];
    f.plateGridDim = m[k + 69];
    f.plateGridGen = m[k + 70];
    f.plateGridPtr = m[k + 67];
    f.m32 = m;
    f.mf32 = this.w.mf32;
    return f;
  }

}
