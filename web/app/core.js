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

  // ---- a selected line (the Selected page) ----

  // What path `path` is, its numbers, why, and its settings, with their
  // values at its z (zs_app_inspect, zs_app_setting_get_at), or null.
  // seg: the selected segment (-1: none), for the support mark there.
  inspect(path, seg = -1) {
    const w = this.w;
    const size = 128; // zs_inspect on wasm32
    const p = w.alloc(size);
    try {
      if (w.x.zs_app_inspect(this.app, path, p) !== 0) return null;
      const s = (o) => w.cstr(w.u32(p + o));
      const info = {
        feature: w.i32(p),
        layer: w.u32(p + 4),
        path: w.u32(p + 8),
        z: w.f64(p + 16),
        height: w.f64(p + 24),
        lineWidth: w.f64(p + 32),
        beadWidth: w.f64(p + 40),
        length: w.f64(p + 48),
        plannedSpeed: w.f64(p + 56),
        speed: w.f64(p + 64),
        flow: w.f64(p + 72),
        startTime: w.f64(p + 80),
        endTime: w.f64(p + 88),
        title: s(96),
        explain: s(100),
        settings: s(104),
        whyPlanned: s(108),
        whyReal: s(112),
        whyFlow: s(116),
        slowReason: w.i32(p + 120),
      };
      // The values of its settings at its z, and the changes for its
      // layers (overrides).
      info.values = {};
      for (const name of info.settings.split("\n")) {
        if (!name || name.startsWith("#")) continue;
        info.values[name] = this.valueAt(info.z, name);
      }
      info.mark = this.markOfPath(path, seg, info);
      info.measure = this.measure(path, seg < 0 ? 0 : seg);
      return info;
    } finally {
      w.free(p, size);
    }
  }

  // The measurements of path `path` at segment `seg` (zs_app_measure): the
  // segment, its straight edge, the path and its size, and the radius of a
  // circle or an arc. Null with no slice.
  measure(path, seg) {
    const w = this.w;
    const size = 88; // zs_measure on wasm32
    const p = w.alloc(size);
    try {
      if (w.x.zs_app_measure(this.app, path, seg, p) !== 0) return null;
      return {
        segment: w.f64(p),
        edge: w.f64(p + 8),
        path: w.f64(p + 16),
        closed: w.i32(p + 24) !== 0,
        sizeX: w.f64(p + 32),
        sizeY: w.f64(p + 40),
        shape: w.i32(p + 48),
        radius: w.f64(p + 56),
        angle: w.f64(p + 80),
      };
    } finally {
      w.free(p, size);
    }
  }

  // ---- the history of changes (src/app/history.zig) ----

  // The facts of the state now: lines of "scope\tkey\tvalue".
  historyFacts() {
    const w = this.w;
    return w.readText((b, c, l) => w.x.zs_app_history_facts(this.app, b, c, l)) ?? "";
  }

  // The changes from facts `a` to facts `b`: lines of
  // "scope\tkey\told\tnew".
  historyDiff(a, b) {
    const w = this.w;
    return w.withString(a, (pa, la) => w.withString(b, (pb, lb) =>
      w.readText((buf, c, l) => w.x.zs_history_diff(pa, la, pb, lb, buf, c, l)))) ?? "";
  }

  // The changes in words, one line for each, with the layer numbers of
  // the last slice.
  historyDescribe(changes) {
    const w = this.w;
    return w.withString(changes, (p, len) => w.readText((b, c, l) => w.x.zs_app_history_describe(this.app, p, len, b, c, l))) ?? "";
  }

  // The kind of a step ("walls", "infill", "speed", "move", ...).
  historyKind(changes) {
    const w = this.w;
    return w.withString(changes, (p, len) => w.cstr(w.x.zs_history_kind(p, len)));
  }

  // Undoes one change line and keeps the others. Returns 0 or a status.
  historyRevert(line) {
    const w = this.w;
    return w.withString(line, (p, len) => w.x.zs_app_history_revert(this.app, p, len));
  }

  // ---- the printability check (src/app/checks.zig) ----

  // The issues of the slice, the worst first (zs_app_checks): { kind,
  // severity (0 note, 1 warning, 2 problem), layer, path, x, y, value,
  // text }. The path is the line of the issue, or the line of its layer
  // nearest to its place (a bridge line for a bridge, skin for an
  // overhang), or -1. Null if the check fails.
  checks() {
    const w = this.w;
    const p = w.alloc(12);
    try {
      if (w.x.zs_app_checks(this.app, p, p + 4, p + 8) !== 0) return null;
      const ip = w.u32(p);
      const n = w.u32(p + 4);
      const tp = w.u32(p + 8);
      const issues = [];
      for (let i = 0; i < n; i++) {
        const q = ip + i * 48; // zs_issue on wasm32
        const kind = w.u8[q];
        const layer = w.u32(q + 4);
        const x = w.f64(q + 16);
        const y = w.f64(q + 24);
        let path = w.u32(q + 8);
        if (path === 0xffffffff) {
          const feature = kind === 5 ? 10 : kind === 2 ? 2 : -1; // bridge, skin
          path = feature >= 0 ? this.w.x.zs_app_pick_feature(this.app, layer, feature, x, y) : -1;
          if (path < 0) path = this.w.x.zs_app_pick_layer(this.app, layer, x, y);
        }
        issues.push({
          kind,
          severity: w.u8[q + 1],
          layer,
          path: path < 0 ? -1 : path,
          x,
          y,
          value: w.f64(q + 32),
          text: w.text(tp + w.u32(q + 40), w.u32(q + 44)),
        });
      }
      return issues;
    } finally {
      w.free(p, 12);
    }
  }

  // ---- gaps (src/gaps.zig) ----

  // The gaps of layer `layer` (zs_app_layer_gaps), the largest first, with
  // their cells as runs (y, x0, x1 for each run, in mm), the size of a
  // cell, and the top z of the layer. Null with no slice.
  gaps(layer) {
    const w = this.w;
    const p = w.alloc(16);
    try {
      if (w.x.zs_app_layer_gaps(this.app, layer, p, p + 4, p + 8, p + 12) !== 0) return null;
      const gp = w.u32(p);
      const n = w.u32(p + 4);
      const rp = w.u32(p + 8);
      const nr = w.u32(p + 12);
      const gaps = [];
      for (let i = 0; i < n; i++) {
        const q = gp + i * 48; // zs_gap on wasm32
        gaps.push({
          area: w.f64(q),
          x: w.f64(q + 8),
          y: w.f64(q + 16),
          width: w.f64(q + 24),
          features: w.u32(q + 32),
          atEdge: w.u8[q + 36] !== 0,
          runStart: w.u32(q + 40),
          runLen: w.u32(q + 44),
        });
      }
      const runs = nr > 0 ? new Float32Array(w.x.memory.buffer, rp, nr * 3).slice() : new Float32Array(0);
      return { gaps, runs, cell: w.x.zs_app_gap_cell(this.app, layer) };
    } finally {
      w.free(p, 16);
    }
  }

  // The gap of layer `layer` at x, y (mm), or the nearest within 0.3 mm,
  // or -1.
  gapAt(layer, x, y) {
    return Number(this.w.x.zs_app_gap_at(this.app, layer, x, y, 0));
  }

  // The settings that can close gap `index` of layer `layer`, the best
  // first: { name, value, why, now } (zs_app_gap_advice).
  gapAdvice(layer, index) {
    const w = this.w;
    const cap = 8;
    const size = 24; // zs_gap_step on wasm32
    const p = w.alloc(cap * size + 4);
    try {
      if (w.x.zs_app_gap_advice(this.app, layer, index, p, cap, p + cap * size) !== 0) return [];
      const n = Math.min(w.u32(p + cap * size), cap);
      const steps = [];
      for (let i = 0; i < n; i++) {
        const q = p + i * size;
        steps.push({
          name: w.text(w.u32(q), w.u32(q + 4)),
          value: w.text(w.u32(q + 8), w.u32(q + 12)),
          why: w.text(w.u32(q + 16), w.u32(q + 20)),
        });
      }
      for (const st of steps) st.now = this.get(st.name);
      return steps;
    } finally {
      w.free(p, cap * size + 4);
    }
  }

  // The value of a setting at z, and 1 if an override covers z.
  valueAt(z, name) {
    const w = this.w;
    const value = w.withString(name, (n) => w.readText((b, c, l) => w.x.zs_app_setting_get_at(this.app, z, n, b, c, l))) ?? "";
    const over = w.withString(name, (n) => w.x.zs_app_override_at(this.app, z, n)) === 1;
    return { value, over, ...this.source(name), base: this.base(name) };
  }

  // A change from the Selected page: for the layers zmin to zmax (an
  // override) if the setting can change by layer, else for this print.
  setScoped(name, value, zmin, zmax, perLayer) {
    if (!perLayer) return this.set(name, value);
    const w = this.w;
    const rc = w.withStrings([name, String(value)], (n, v) => w.x.zs_app_override_set(this.app, zmin, zmax, n, v));
    if (rc === 0) return "";
    if (rc === 14) return "The value is out of the limits.";
    return `The value is not valid (${statusText(rc)}).`;
  }

  // Removes the change of the Selected page: the override of the range,
  // or the overrides at z, else the change of this print.
  resetScoped(name, zmin, zmax, z) {
    const w = this.w;
    const removed = w.withString(name, (n) => w.x.zs_app_override_remove(this.app, zmin, zmax, n)) === 1 ||
      w.withString(name, (n) => w.x.zs_app_override_clear_at(this.app, z, n)) > 0;
    return removed ? "" : this.reset(name);
  }

  // The report of a line for "Copy for AI" (zs_app_line_report).
  lineReport(path) {
    const w = this.w;
    const file = `${(this.modelName || "part").replace(/\.(stl|3mf)$/i, "")}.gcode (Export G-code saves it)`;
    const rc = w.withString(file, (f) => w.x.zs_app_line_report(this.app, path, f, w.cell, w.cell + 4));
    if (rc !== 0) return null;
    return w.text(w.u32(w.cell), w.u32(w.cell + 4));
  }

  // The path of `feature` on `layer` nearest to (x, y): the same line
  // after a new slice (zs_app_pick_feature), or -1.
  refind(layer, feature, x, y) {
    const p = this.w.x.zs_app_pick_feature(this.app, layer, feature, x, y);
    return p < 0 ? -1 : p;
  }

  // ---- support marks (the context menu) ----

  markCount() { return this.w.x.zs_app_mark_count(this.app); }

  // The mark at a selected line: above it for a support line, else on
  // its layer (linux/src/ui/inspector.c, mark_of_selection). The place is
  // the one of the menu (the middle of the selected segment), so the mark
  // of a long segment shows too.
  markOfPath(path, seg, info) {
    const w = this.w;
    if (this.markCount() === 0) return null;
    const pt = this.pathPoint(path, seg);
    if (!pt) return null;
    const support = info.feature === 6 || info.feature === 7;
    const m = support ? w.x.zs_app_mark_at(this.app, pt[0], pt[1], info.z + 500, 500) : w.x.zs_app_mark_at(this.app, pt[0], pt[1], info.z, 0.05);
    if (m < 0) return null;
    const c = w.cell;
    if (w.x.zs_app_mark_get(this.app, m, c, c + 8, c + 16, c + 24, c + 32) !== 0) return null;
    return { index: m, r: w.f64(c + 24), kind: w.i32(c + 32) };
  }

  // A point of a path in mm: the middle of segment `seg`, or of the
  // middle segment (seg < 0), and the z of its layer (toolpath data of
  // the app; view3d.c, mark_place).
  pathPoint(path, seg) {
    const w = this.w;
    const t = w.alloc(96);
    try {
      if (w.x.zs_app_toolpaths(this.app, t) !== 0) return null;
      const pts = w.u32(t);
      const ends = w.u32(t + 4);
      const count = w.u32(t + 24);
      if (path >= count) return null;
      const a = path === 0 ? 0 : w.u32(ends + 4 * (path - 1));
      const b = w.u32(ends + 4 * path);
      if (b <= a) return null;
      const i = seg >= 0 && a + seg + 1 < b ? a + seg : a + Math.floor((b - a) / 2) - (b - a > 1 ? 1 : 0);
      const j = i + 1 < b ? i + 1 : i;
      const f = new Float32Array(w.x.memory.buffer, pts, 2 * b);
      const layerEnds = w.u32(t + 28);
      const nLayers = w.u32(t + 44);
      const layerZ = w.u32(t + 32);
      let layer = 0;
      while (layer < nLayers && w.u32(layerEnds + 4 * layer) <= path) layer++;
      const z = layer < nLayers ? new Float32Array(w.x.memory.buffer, layerZ, nLayers)[layer] : 0;
      return [(f[2 * i] + f[2 * j]) / 2, (f[2 * i + 1] + f[2 * j + 1]) / 2, z];
    } finally {
      w.free(t, 96);
    }
  }

  // ---- the plate ----

  addStl(name, bytes) {
    const w = this.w;
    const r = w.withString(name, (n) => w.withBytes(bytes, (p, len) => w.x.zs_app_add_stl(this.app, n, p, len)));
    if (r < 0) throw new Error(`The file did not open: ${statusText(-r)}.`);
    if (!this.modelName) this.modelName = name;
    return r;
  }

  partOfPath(path) { return this.w.x.zs_app_part_of_path(this.app, path); }

  // The plate as a 3MF file (zs_app_write_3mf), as bytes, or null.
  plate3mf() {
    const w = this.w;
    if (w.x.zs_app_part_count(this.app) === 0) return null;
    if (w.x.zs_app_write_3mf(this.app, w.cell, w.cell + 4) !== 0) return null;
    const p = w.u32(w.cell);
    const n = w.u32(w.cell + 4);
    return w.u8.slice(p, p + n);
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
