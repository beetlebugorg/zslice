// view.js: the 3D view of the main thread. The scene and the camera are in
// the core (src/render/view.zig, in web mode); this file calls them, and
// reads the frame data (zs_web_frame) for the WebGL drawing (gl.js).
//
// The view gets its beads from the worker as bytes (zs_view_scene_read),
// so the camera moves at once, also while the worker slices.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { statusText } from "./wasm.js";

export const MODES = ["Filament", "Feature", "Speed", "Flow", "Layer time", "Line width"];

export class View3D {
  constructor(wasm, width, height) {
    this.w = wasm;
    this.x = wasm.x;
    this.v = wasm.newView(width, height);
    this.loaded = false;
  }

  resize(width, height) { this.x.zs_view_resize(this.v, width, height); }

  // Reads a scene of the worker (an ArrayBuffer).
  readScene(buffer) {
    const bytes = new Uint8Array(buffer);
    const rc = this.w.withBytes(bytes, (p, n) => this.x.zs_view_scene_read(this.v, p, n));
    if (rc !== 0) throw new Error(`zslice: the scene did not load (${statusText(rc)})`);
    this.loaded = true;
  }

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

  legend() {
    const c = this.w.cell;
    if (!this.x.zs_view_legend(this.v, c, c + 8)) return null;
    return [this.w.f64(c), this.w.f64(c + 8)];
  }

  // Computes one frame, and returns its data: views into wasm memory, valid
  // until the next call into the module.
  frame() {
    this.x.zs_view_draw(this.v);
    const p = this.x.zs_view_web_frame(this.v);
    const buf = this.x.memory.buffer;
    const f32 = new Float32Array(buf, p, 60);
    const u32 = new Uint32Array(buf, p + 240, 21);
    const [boxFirst, boxCount, markFirst, markCount, extras, extrasCount, head, headCount,
      instances, instanceCount, instancesGen, meshVerts, meshVertCount, meshIndex, meshIndexCount, meshGen,
      gridPoints, gridVertices, gridGen, width, height] = u32;
    return {
      box: f32.subarray(0, 28),
      grid: f32.subarray(28, 56),
      clear: f32.subarray(56, 60),
      boxFirst, boxCount, markFirst, markCount,
      extras: new Uint8Array(buf, extras, extrasCount * 32),
      extrasCount,
      head: new Uint8Array(buf, head, headCount * 32),
      headCount,
      instances: new Uint8Array(buf, instances, instanceCount * 32),
      instanceCount, instancesGen,
      meshVerts: new Float32Array(buf, meshVerts, meshVertCount * 4),
      meshIndex: new Uint16Array(buf, meshIndex, meshIndexCount),
      meshGen,
      gridPoints: new Float32Array(buf, gridPoints, gridVertices * 3),
      gridVertices, gridGen,
      width, height,
    };
  }
}
