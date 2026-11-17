// core.js: the app core (zs_app_*) for the worker. It keeps one app and
// one 3D view in web mode. The view of the worker only loads each slice and
// writes its beads as bytes (zs_view_scene_write), for the view of the
// main thread (view.js).
//
// It needs no DOM and no worker API, so the Node test uses it too.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { statusText } from "./wasm.js";

export const GROUPS = ["machine", "filament", "project"];
export const STATE = { empty: 0, ready: 1, slicing: 2, done: 3, failed: 4 };

export class Core {
  // wasm: a Wasm (wasm.js) whose onEvent goes to this.onEvent.
  constructor(wasm) {
    this.w = wasm;
    const x = wasm.x;
    const rc = x.zs_app_new_web(wasm.cell);
    if (rc !== 0) throw new Error(`zslice: no app (${statusText(rc)})`);
    this.app = wasm.u32(wasm.cell);
    this.view = wasm.newView(16, 16);
    this.infos = wasm.settingInfos();
    this.modelName = "";
  }

  state() { return this.w.x.zs_app_state(this.app); }

  // ---- the model ----

  loadStl(name, bytes) {
    const w = this.w;
    const rc = w.withString(name, (n) => w.withBytes(bytes, (p, len) => w.x.zs_app_load_stl(this.app, n, p, len)));
    if (rc !== 0) throw new Error(`The file did not open: ${statusText(rc)}.`);
    this.modelName = name;
  }

  modelInfo() {
    const w = this.w;
    if (w.x.zs_app_model_info(this.app, w.cell) !== 0) return null;
    const dv = w.dv;
    return {
      triangles: Number(dv.getBigUint64(w.cell, true)),
      size: [w.f64(w.cell + 8), w.f64(w.cell + 16), w.f64(w.cell + 24)],
    };
  }

  // ---- settings ----

  get(name) {
    const w = this.w;
    return w.withString(name, (n) => w.readText((b, c, l) => w.x.zs_app_setting_get(this.app, n, b, c, l))) ?? "";
  }

  // Returns "" on success, else the reason.
  set(name, value) {
    const w = this.w;
    const rc = w.withStrings([name, String(value)], (n, v) => w.x.zs_app_setting_set(this.app, n, v));
    if (rc === 0) return "";
    if (rc === 14) return "The value is out of the limits.";
    return `The value is not valid (${statusText(rc)}).`;
  }

  // The value of a setting with no change of this print: what a reset
  // gives.
  base(name) {
    const w = this.w;
    return w.withString(name, (n) => w.readText((b, c, l) => w.x.zs_app_setting_base_get(this.app, n, b, c, l))) ?? "";
  }

  // The formula of a setting, or null.
  formula(name) {
    const w = this.w;
    return w.withString(name, (n) => w.readText((b, c, l) => w.x.zs_app_formula_get(this.app, n, b, c, l)));
  }

  // Where the value comes from: { level, profile } (enum zs_level).
  source(name) {
    const w = this.w;
    const cap = 256;
    const buf = w.alloc(cap);
    try {
      const rc = w.withString(name, (n) => w.x.zs_app_setting_source(this.app, -1, n, w.cell, buf, cap));
      if (rc !== 0) return { level: 0, profile: "" };
      return { level: w.i32(w.cell), profile: w.cstr(buf) };
    } finally {
      w.free(buf, cap);
    }
  }

  // All values, with their sources, the reset values, and the formulas:
  // the main thread shows the settings from this.
  snapshot() {
    const values = {};
    for (const info of this.infos) {
      const src = this.source(info.name);
      values[info.name] = {
        value: this.get(info.name),
        level: src.level,
        profile: src.profile,
        base: this.base(info.name),
        formula: this.formula(info.name),
      };
    }
    return { values, quality: this.qualityName() };
  }

  qualityName() { return this.w.cstr(this.w.x.zs_app_quality_name(this.app)); }

  // ---- saved state (the texts of the GTK shell files) ----

  stateText(group) {
    const w = this.w;
    return w.readText((b, c, l) => w.x.zs_app_state_write(this.app, group, b, c, l)) ?? "";
  }

  formulasText() {
    const w = this.w;
    return w.readText((b, c, l) => w.x.zs_app_formulas_write(this.app, b, c, l)) ?? "";
  }

  // The state to keep in localStorage.
  savedState() {
    return {
      machine: this.stateText(0),
      filament: this.stateText(1),
      project: this.stateText(2),
      formulas: this.formulasText(),
      quality: this.qualityName(),
    };
  }

  // Applies a profile text to a group. Returns "" or the error message.
  applyProfile(group, text) {
    const w = this.w;
    const cap = 512;
    const msg = w.alloc(cap);
    w.u8[msg] = 0;
    try {
      const rc = w.withString(text, (t, len) => w.x.zs_app_profile_apply(this.app, group, t, len, msg, cap));
      return rc === 0 ? "" : (w.cstr(msg) || statusText(rc));
    } finally {
      w.free(msg, cap);
    }
  }

  // Restores the state of savedState: the groups, then the quality profile
  // under the changes of this print, then the formulas (the order of the
  // GTK shell). Returns the errors.
  restore(saved) {
    const errors = [];
    for (let g = 0; g < 3; g++) {
      const text = saved?.[GROUPS[g]];
      if (!text) continue;
      const e = this.applyProfile(g, text);
      if (e) errors.push(`${GROUPS[g]}: ${e}`);
    }
    if (saved?.quality && saved.quality !== "custom") {
      const e = this.setQuality(saved.quality, true);
      if (e) errors.push(`quality: ${e}`);
    }
    if (saved?.formulas) {
      const w = this.w;
      w.withString(saved.formulas, (t, len) => w.x.zs_app_formulas_read(this.app, t, len));
    }
    return errors;
  }

  // A built-in quality profile. keepEdits: the changes of this print stay.
  setQuality(name, keepEdits) {
    const w = this.w;
    const text = `extends = "${name}"\n`;
    const cap = 512;
    const msg = w.alloc(cap);
    w.u8[msg] = 0;
    try {
      const rc = w.withStrings([name, text], (n, t) => w.x.zs_app_quality_set(this.app, n, t, text.length, keepEdits ? 1 : 0, msg, cap));
      return rc === 0 ? "" : (w.cstr(msg) || statusText(rc));
    } finally {
      w.free(msg, cap);
    }
  }

  // A built-in printer or filament profile: the group goes back to the
  // defaults, then takes the profile. On an error the settings stay.
  loadProfile(group, text) {
    const before = this.stateText(group);
    this.w.x.zs_app_group_reset(this.app, group);
    const e = this.applyProfile(group, text);
    if (e) {
      this.w.x.zs_app_group_reset(this.app, group);
      this.applyProfile(group, before);
    }
    return e;
  }

  // Resets one setting: its value of the cascade under this print.
  reset(name) {
    return this.set(name, this.base(name));
  }

  // ---- the slice ----

  // Slices now (on this thread). Returns the state.
  slice() {
    const rc = this.w.x.zs_app_request_slice(this.app);
    if (rc !== 0 && rc !== 12) return { state: this.state(), error: statusText(rc) };
    return { state: this.state(), error: "" };
  }

  stats() {
    const w = this.w;
    if (w.x.zs_app_stats(this.app, w.cell) !== 0) return null;
    const c = w.cell;
    return {
      layerCount: w.u32(c),
      retractions: w.u32(c + 4),
      filamentMm: w.f64(c + 8),
      filamentG: w.f64(c + 16),
      printTimeS: w.f64(c + 24),
      travelMm: w.f64(c + 32),
    };
  }

  // The time, length, volume, and path count of each feature.
  featureStats() {
    const w = this.w;
    const n = 11;
    const p = w.alloc(32 * n);
    try {
      if (w.x.zs_app_feature_stats(this.app, p) !== 0) return null;
      const out = [];
      for (let i = 0; i < n; i++) {
        const q = p + 32 * i;
        out.push({ timeS: w.f64(q), lengthMm: w.f64(q + 8), volumeMm3: w.f64(q + 16), paths: w.u32(q + 24) });
      }
      return out;
    } finally {
      w.free(p, 32 * n);
    }
  }

  // For each layer: its nozzle z, its height, the time at its end, and 1
  // if it slows down to cool.
  layers() {
    const w = this.w;
    const p = w.alloc(96);
    try {
      if (w.x.zs_app_toolpaths(this.app, p) !== 0) return null;
      const f32 = (ptr, n) => new Float32Array(w.x.memory.buffer, ptr, n).slice();
      const pathEndTime = w.u32(p + 20);
      const layerEnds = w.u32(p + 28);
      const n = w.u32(p + 44);
      const ends = new Uint32Array(w.x.memory.buffer, layerEnds, n).slice();
      const times = new Float32Array(w.x.memory.buffer, pathEndTime, w.u32(p + 24));
      const end = new Float32Array(n);
      for (let i = 0; i < n; i++) end[i] = ends[i] > 0 ? times[ends[i] - 1] : (i > 0 ? end[i - 1] : 0);
      return {
        z: f32(w.u32(p + 32), n),
        height: f32(w.u32(p + 36), n),
        endTime: end,
        slowed: new Uint8Array(w.x.memory.buffer, w.u32(p + 60), n).slice(),
      };
    } finally {
      w.free(p, 96);
    }
  }

  // The beads of the slice for the main thread, in a color mode (enum
  // zs_view_mode). Returns an ArrayBuffer, or null.
  scene(mode) {
    const w = this.w;
    const x = w.x;
    x.zs_view_set_mode(this.view, mode);
    if (x.zs_view_load(this.view, this.app) !== 0) return null;
    if (x.zs_view_scene_write(this.view, w.cell, w.cell + 4) !== 0) return null;
    const p = w.u32(w.cell);
    const n = w.u32(w.cell + 4);
    const out = w.u8.slice(p, p + n).buffer;
    x.zs_buffer_free(p, n);
    return out;
  }

  // The G-code of the slice, as bytes.
  gcode() {
    const w = this.w;
    if (w.x.zs_app_gcode(this.app, w.cell, w.cell + 4) !== 0) return null;
    const p = w.u32(w.cell);
    const n = w.u32(w.cell + 4);
    return w.u8.slice(p, p + n);
  }
}
