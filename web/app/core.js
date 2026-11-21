// core.js: the app core (zs_app_*) for the worker. It keeps one app. A 3D
// view in web mode lives only while it loads a slice and writes its beads
// as bytes (zs_view_scene_write), for the view of the main thread
// (view.js). The Core keeps a copy of the last bytes (`lastScene`), out of
// wasm memory.
//
// It needs no DOM and no worker API, so the Node test uses it too.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { statusText } from "./wasm.js";

export const GROUPS = ["machine", "filament", "project"];
export const STATE = { empty: 0, ready: 1, slicing: 2, done: 3, failed: 4 };

// Why a file did not open, in words a beginner can act on (the texts of
// the core: zs_status_message).
function openError(rc, w) {
  const text = w?.x?.zs_status_message ? w.cstr(w.x.zs_status_message(rc)) : statusText(rc);
  return `The file did not open. ${text}`;
}

// The values of a node of the support trees in core.supportTrees.
export const TREE_STRIDE = 9;

// The speed ratios that give a speed in mm/s (setting_effect.ratioSpeed).
const RATIO_SPEEDS = [
  "project.outer_wall_speed", "project.inner_wall_speed", "project.skin_speed", "project.infill_speed",
  "project.first_layer_speed", "project.ironing_speed", "project.slope_smoothing_speed",
  "project.slope_ironing_speed", "project.bridge_speed",
];

export class Core {
  // wasm: a Wasm (wasm.js) whose onEvent goes to this.onEvent. infos: the
  // setting infos of another Core of the same Wasm, to share. app: an app
  // that a plate set owns (zs_set_app); without it, the Core makes its
  // own app.
  constructor(wasm, infos = null, app = 0) {
    this.w = wasm;
    const x = wasm.x;
    this.owned = !app;
    if (!app) {
      const rc = x.zs_app_new_web(wasm.cell);
      if (rc !== 0) throw new Error(`zslice: no app (${statusText(rc)})`);
      app = wasm.u32(wasm.cell);
    }
    this.app = app;
    this.last = null;
    this.infos = infos ?? wasm.settingInfos();
    this.modelName = "";
  }

  // Frees the app (only an app of this Core). The Core is of no use after
  // it.
  free() {
    if (this.owned) this.w.x.zs_app_free(this.app);
    this.app = 0;
    this.last = null;
  }

  // Frees the memory that only makes the next slice faster (zs_app_trim):
  // for a plate that is not the active plate.
  trim() {
    this.w.x.zs_app_trim(this.app);
  }

  state() { return this.w.x.zs_app_state(this.app); }

  // ---- the model ----

  loadStl(name, bytes) {
    const w = this.w;
    const rc = w.withString(name, (n) => w.withBytes(bytes, (p, len) => w.x.zs_app_load_stl(this.app, n, p, len)));
    if (rc !== 0) throw new Error(openError(rc, w));
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

  // The zslice settings of Cura settings ({ key: value }) for the whole
  // plate: { sets: [[name, value]], near: [[key, value, why]],
  // unused: [[key, value, why]] }. It changes no setting.
  curaSettings(pairs) {
    const w = this.w;
    const text = Object.entries(pairs).map(([k, v]) => `${k}=${v}`).join("\n");
    const out = w.withString(text, (t) => w.readText((b, c, l) => w.x.zs_app_cura_settings(this.app, t, b, c, l)));
    const r = { sets: [], near: [], unused: [] };
    for (const line of (out ?? "").split("\n")) {
      const [kind, ...rest] = line.split("\t");
      if (kind === "set") r.sets.push(rest);
      else if (kind === "near" || kind === "unused") r[kind].push(rest);
    }
    return r;
  }

  // The settings of part i that zslice does not use: [[key, value, why]].
  partUnused(i) {
    const w = this.w;
    const out = w.readText((b, c, l) => w.x.zs_app_part_unused(this.app, i, b, c, l)) ?? "";
    return out.split("\n").filter(Boolean).map((l) => l.split("\t"));
  }

  // ---- printdeck.yml projects (src/project.zig) ----

  // The parts and the suggested plates of a printdeck.yml text. counts:
  // one entry for each part ("-" or null: the count of the file, 0: not
  // on a plate). Returns the plan, or { error, line }.
  projectPlan(text, counts = []) {
    const w = this.w;
    const c = counts.map((n) => (n == null ? "-" : String(n))).join(",");
    const out = w.withStrings([text, c], (t, cs) => w.readText((b, cap, l) => w.x.zs_project_plan(t, cs, b, cap, l)));
    return JSON.parse(out ?? '{"error":"no answer"}');
  }

  // A set of files of a repository for a plate: { path: bytes }. Returns
  // a handle for projectProfiles and projectLoad; free it with filesFree.
  filesNew(files) {
    const w = this.w;
    const f = w.x.zs_files_new();
    for (const [path, bytes] of Object.entries(files)) {
      const rc = w.withString(path, (p) => w.withBytes(bytes, (d, n) => w.x.zs_files_add(f, p, d, n)));
      if (rc !== 0) {
        w.x.zs_files_free(f);
        throw new Error(`The file ${path} did not load (${statusText(rc)}).`);
      }
    }
    return f;
  }

  filesFree(f) {
    this.w.x.zs_files_free(f);
  }

  // The machine, filament, and project profiles of plate i:
  // { machine: { name, text }, filament, project } or { error }.
  projectProfiles(files, text, counts, plate) {
    const w = this.w;
    const c = counts.map((n) => (n == null ? "-" : String(n))).join(",");
    const out = w.withStrings([text, c], (t, cs) => w.readText((b, cap, l) => w.x.zs_project_profiles(files, t, cs, plate, b, cap, l)));
    return JSON.parse(out ?? '{"error":"plate out of range"}');
  }

  // Loads plate i: its profiles, its settings, and its parts. Returns ""
  // or the reason it did not load. fits: false if the parts do not all
  // fit on the bed (they are on the plate).
  projectLoad(files, text, counts, plate) {
    const p = this.projectProfiles(files, text, counts, plate);
    if (p.error) return { error: p.error };
    for (const [group, g] of [["machine", 0], ["filament", 1], ["project", 2]]) {
      const e = this.loadProfile(g, p[group].text);
      if (e) return { error: `The ${group} profile ${p[group].name}: ${e}` };
    }
    const w = this.w;
    const c = counts.map((n) => (n == null ? "-" : String(n))).join(",");
    const cap = 1024;
    const msg = w.alloc(cap);
    try {
      const rc = w.withStrings([text, c], (t, cs) => w.x.zs_app_project_load(this.app, files, t, cs, plate, msg, cap));
      const m = w.cstr(msg);
      if (rc === 14) return { error: "", fits: false, message: m };
      if (rc !== 0) return { error: m || statusText(rc) };
      return { error: "", fits: true, profiles: p };
    } finally {
      w.free(msg, cap);
    }
  }

  // The parts of a 3MF file keep their places in the file.
  setKeepPlaces(on) {
    this.w.x.zs_app_set_keep_places(this.app, on ? 1 : 0);
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
    // The speed in mm/s of each speed ratio (zs_app_ratio_speed): the
    // editors show it next to the ratio.
    const w = this.w;
    for (const name of RATIO_SPEEDS) {
      if (!values[name]) continue;
      const rc = w.withStrings([name, values[name].value], (n, v) => w.x.zs_app_ratio_speed(this.app, n, v, w.cell));
      if (rc === 0) values[name].speed = w.f64(w.cell);
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

  // The print as it forms: simulates the plastic of the last slice, and
  // shows it in the toolpaths (zs_app_simulate_print). A new scene draws
  // it. Returns its numbers, or null.
  simulatePrint() {
    const w = this.w;
    if (w.x.zs_app_simulate_print(this.app, w.cell) !== 0) return null;
    return this.readSimStats(w.cell);
  }

  // The numbers of the last simulated print (zs_app_sim_stats), or null.
  simStats() {
    const w = this.w;
    if (w.x.zs_app_sim_stats(this.app, w.cell) !== 0) return null;
    return this.readSimStats(w.cell);
  }

  // A zs_print_sim_stats at c (wasm32: size_t and ptrdiff_t are 4 bytes).
  readSimStats(c) {
    const w = this.w;
    return {
      masses: w.u32(c),
      softMasses: w.u32(c + 4),
      moved: w.u32(c + 8),
      movedPaths: w.u32(c + 12),
      maxMove: w.dv.getFloat32(c + 16, true),
      massG: w.f64(c + 24),
      peakSoft: w.u32(c + 32),
      steps: w.u32(c + 36),
      failed: w.u32(c + 40),
      firstFailedLayer: w.dv.getInt32(c + 44, true),
      maxDrop: w.dv.getFloat32(c + 48, true),
      materialExact: w.dv.getInt32(c + 52, true) === 1,
      material: w.cstr(c + 56),
    };
  }

  // The largest drop (mm) and the failed masses of each layer of the last
  // simulated print (zs_app_sim_layer), or null.
  simLayers(count) {
    const w = this.w;
    const c = w.cell;
    const drop = new Float32Array(count);
    const failed = new Uint32Array(count);
    for (let l = 0; l < count; l++) {
      if (w.x.zs_app_sim_layer(this.app, l, c, c + 4) !== 0) return null;
      drop[l] = w.dv.getFloat32(c, true);
      failed[l] = w.u32(c + 4);
    }
    return { drop, failed };
  }

  // Shows the simulated print (true) or the slice (false). False if there
  // is no simulation of the last slice.
  showSimulated(on) {
    return this.w.x.zs_app_show_simulated(this.app, on ? 1 : 0) === 0;
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
    const view = w.newView(16, 16);
    try {
      x.zs_view_set_mode(view, mode);
      if (x.zs_view_load(view, this.app) !== 0) return null;
      if (x.zs_view_scene_write(view, w.cell, w.cell + 4) !== 0) return null;
      const p = w.u32(w.cell);
      const n = w.u32(w.cell + 4);
      const out = w.u8.slice(p, p + n).buffer;
      x.zs_buffer_free(p, n);
      this.last = out.slice(0);
      return out;
    } finally {
      x.zs_view_free(view);
    }
  }

  // A copy of the bytes of the last scene (the last slice that went to the
  // page), or null.
  lastScene() {
    return this.last ? this.last.slice(0) : null;
  }

  // ---- a selected line (the Selected page) ----

  // What path `path` is, its numbers, why, and its settings, with their
  // values at its z (zs_app_inspect, zs_app_setting_get_at), or null.
  // seg: the selected segment (-1: none), for the support mark there.
  inspect(path, seg = -1) {
    const w = this.w;
    const size = 168; // zs_inspect on wasm32
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
      info.slowText = s(124);
      info.fan = w.f64(p + 128);
      info.layerTime = w.f64(p + 136);
      info.maxFlow = w.f64(p + 144);
      info.flowLimited = w.i32(p + 152) !== 0;
      const held = w.u32(p + 156);
      info.holds = held === 0xffffffff ? null : { layer: held, feature: w.i32(p + 160) };
      // The key of the line for an edit (zs_app_path_key), read now: the
      // edit then works while a new slice runs.
      info.key = String(w.x.zs_app_path_key(this.app, path));
      info.picks = this.picks(path, 8);
      info.measure = this.measure(path, seg < 0 ? 0 : seg);
      return info;
    } finally {
      w.free(p, size);
    }
  }

  // The settings that matter most for a line (zs_app_inspect_picks):
  // [{ name, why }], best first.
  picks(path, max) {
    const w = this.w;
    const size = 8 * max; // zs_pick on wasm32: two pointers
    const p = w.alloc(size + 8);
    try {
      if (w.x.zs_app_inspect_picks(this.app, path, p, max, p + size) !== 0) return [];
      const n = w.u32(p + size);
      const out = [];
      for (let k = 0; k < n; k++) out.push({ name: w.cstr(w.u32(p + 8 * k)), why: w.cstr(w.u32(p + 8 * k + 4)) });
      return out;
    } finally {
      w.free(p, size + 8);
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
        centerX: w.f64(p + 64),
        centerY: w.f64(p + 72),
        angle: w.f64(p + 80),
      };
    } finally {
      w.free(p, size);
    }
  }

  // ---- the undo list and the history (src/app/history.zig) ----
  //
  // The app keeps its undo list and notes each change. The worker keeps
  // the timer: it calls historyCommit 400 ms after the last change. The
  // time is ms since 1970 (Date.now()).

  // Ends the step of the changes so far. True if the list changed.
  historyCommit(nowMs) {
    return this.w.x.zs_app_history_commit(this.app, BigInt(Math.floor(nowMs))) === 1;
  }

  // The setting whose editor has the focus, or null. True if the commit
  // of the edit before changed the list.
  historyFocus(key, nowMs) {
    const w = this.w;
    const t = BigInt(Math.floor(nowMs));
    if (key == null) return w.x.zs_app_history_set_focus(this.app, 0, t) === 1;
    return w.withString(key, (k) => w.x.zs_app_history_set_focus(this.app, k, t)) === 1;
  }

  // Undo, redo, go to step i, and clear the history after step i. Each
  // returns the bits of enum zs_history_restored (0: no move).
  historyUndo(nowMs) { return this.w.x.zs_app_history_undo(this.app, BigInt(Math.floor(nowMs))); }
  historyRedo(nowMs) { return this.w.x.zs_app_history_redo(this.app, BigInt(Math.floor(nowMs))); }
  historyGoto(i, nowMs) { return this.w.x.zs_app_history_goto(this.app, i, BigInt(Math.floor(nowMs))); }
  historyTruncate(i, nowMs) { return this.w.x.zs_app_history_truncate(this.app, i, BigInt(Math.floor(nowMs))); }
  historyReset() { this.w.x.zs_app_history_reset(this.app); }
  historyCount() { return this.w.x.zs_app_history_count(this.app); }
  historyCurrent() { return this.w.x.zs_app_history_current(this.app); }
  // True if changes wait for a commit.
  historyPending() { return this.w.x.zs_app_history_pending(this.app) === 1; }

  // Step i: { time, kind, changes, text }. kind is "start" for step 0;
  // changes are lines of "scope\tkey\told\tnew" from step i - 1, and text
  // has them in words ("scope\tchange" lines), with the layer numbers of
  // the last slice.
  historyStep(i) {
    const w = this.w;
    const size = 32; // zs_history_step on wasm32
    const p = w.alloc(size);
    try {
      if (w.x.zs_app_history_step(this.app, i, p) !== 0) return null;
      const dv = w.dv;
      return {
        time: Number(dv.getBigInt64(p, true)),
        kind: w.cstr(w.u32(p + 8)),
        changes: w.text(w.u32(p + 12), w.u32(p + 16)),
        text: w.text(w.u32(p + 20), w.u32(p + 24)),
      };
    } finally {
      w.free(p, size);
    }
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

  // The issues of the check on the layer of path `path` that are about
  // it: its own issues, and the issues within `near` mm of it (a bridge or
  // an overhang next to the line). Reads the cached check of the slice
  // (zs_app_checks, after zs_app_checks_ready): a loop over the issues,
  // with no pick. [{ kind, severity, value, text }], the worst first.
  issuesOfPath(path, layer, near = 3) {
    const w = this.w;
    const p = w.alloc(12);
    const t = w.alloc(96);
    try {
      // Only a check that has run: the check of a whole slice can take a
      // second, too long for a click.
      if (!w.x.zs_app_checks_ready(this.app)) return [];
      if (w.x.zs_app_checks(this.app, p, p + 4, p + 8) !== 0) return [];
      if (w.x.zs_app_toolpaths(this.app, t) !== 0) return [];
      const ip = w.u32(p);
      const n = w.u32(p + 4);
      const tp = w.u32(p + 8);
      const ends = w.u32(t + 4);
      const a = path === 0 ? 0 : w.u32(ends + 4 * (path - 1));
      const b = w.u32(ends + 4 * path);
      const f = new Float32Array(w.x.memory.buffer, w.u32(t), 2 * b);
      const out = [];
      for (let i = 0; i < n; i++) {
        const q = ip + i * 48; // zs_issue on wasm32
        if (w.u32(q + 4) !== layer) continue;
        let hit = w.u32(q + 8) === path;
        if (!hit) {
          const x = w.f64(q + 16);
          const y = w.f64(q + 24);
          for (let k = a; k < b && !hit; k++) hit = Math.hypot(f[2 * k] - x, f[2 * k + 1] - y) <= near;
        }
        if (hit) out.push({ kind: w.u8[q], severity: w.u8[q + 1], value: w.f64(q + 32), text: w.text(tp + w.u32(q + 40), w.u32(q + 44)) });
      }
      return out;
    } finally {
      w.free(p, 12);
      w.free(t, 96);
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
    const file = `${(this.modelName || "part").replace(/.(stl|3mf|obj|step|stp)$/i, "")}.gcode (Export G-code saves it)`;
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

  // ---- support areas (the support editor, support.js) ----

  // The support areas: [{ kind, zLo, zHi, pts: [[x, y, z], ...] }].
  supportAreas() {
    const w = this.w;
    const n = w.x.zs_app_support_area_count(this.app);
    const out = [];
    const cap = 256;
    const buf = w.alloc(cap * 24);
    try {
      for (let i = 0; i < n; i++) {
        const c = w.cell;
        if (w.x.zs_app_support_area_get(this.app, i, c, buf, cap, c + 8, c + 16, c + 24) !== 0) continue;
        const k = Math.min(w.u32(c + 8), cap);
        const pts = [];
        for (let j = 0; j < k; j++) pts.push([w.f64(buf + 24 * j), w.f64(buf + 24 * j + 8), w.f64(buf + 24 * j + 16)]);
        out.push({ kind: w.i32(c), zLo: w.f64(c + 16), zHi: w.f64(c + 24), pts });
      }
    } finally {
      w.free(buf, cap * 24);
    }
    return out;
  }

  // Calls fn(ptr, n) with the points [[x, y, z], ...] in wasm memory.
  withPoints(pts, fn) {
    const a = new Float64Array(pts.length * 3);
    pts.forEach((p, i) => a.set(p, i * 3));
    return this.w.withBytes(new Uint8Array(a.buffer), (p) => fn(p, pts.length));
  }

  // A new area: its index, or -1. The z range comes from the points.
  supportAreaAdd(kind, pts, zLo = NaN, zHi = NaN) {
    const i = this.withPoints(pts, (p, n) => this.w.x.zs_app_support_area_add(this.app, kind, p, n, zLo, zHi));
    return i < 0 ? -1 : i;
  }

  // The overhang nearest to the bed point (x, y, z), within maxDist mm
  // (zs_app_support_pick): { part, pts, zLo, zHi }, or null.
  supportPick(x, y, z, maxDist) {
    const w = this.w;
    const cap = 256;
    const buf = w.alloc(cap * 24 + 24);
    try {
      const part = Number(w.x.zs_app_support_pick(this.app, x, y, z, maxDist, buf, cap, buf + cap * 24, buf + cap * 24 + 8, buf + cap * 24 + 16));
      if (part < 0) return null;
      const n = w.u32(buf + cap * 24);
      const pts = [];
      for (let i = 0; i < n; i++) pts.push([w.f64(buf + i * 24), w.f64(buf + i * 24 + 8), w.f64(buf + i * 24 + 16)]);
      return { part, pts, zLo: w.f64(buf + cap * 24 + 8), zHi: w.f64(buf + cap * 24 + 16) };
    } finally {
      w.free(buf, cap * 24 + 24);
    }
  }

  supportAreaSet(index, pts) {
    return this.withPoints(pts, (p, n) => this.w.x.zs_app_support_area_set(this.app, index, p, n, NaN, NaN)) === 0;
  }

  // ---- support trees (the support editor of tree support, support.js) ----

  // The nodes of the trees of part `part` (zs_app_support_tree_nodes): a
  // Float64Array of TREE_STRIDE values a node (x, y, z, r, rMin, down,
  // layer, branch, flags), and edited (the trees of the user); null with
  // no slice result.
  supportTrees(part) {
    const w = this.w;
    const n = Number(w.x.zs_app_support_tree_nodes(this.app, part, 0, 0));
    if (n < 0) return null;
    const out = new Float64Array(n * TREE_STRIDE);
    if (n > 0) {
      const size = n * 56;
      const buf = w.alloc(size);
      try {
        const got = Number(w.x.zs_app_support_tree_nodes(this.app, part, buf, n));
        if (got < 0) return null;
        const dv = w.dv;
        for (let i = 0; i < Math.min(n, got); i++) {
          const b = buf + 56 * i;
          const o = i * TREE_STRIDE;
          for (let k = 0; k < 5; k++) out[o + k] = dv.getFloat64(b + 8 * k, true);
          out[o + 5] = dv.getInt32(b + 40, true);
          out[o + 6] = dv.getUint32(b + 44, true);
          out[o + 7] = dv.getUint32(b + 48, true);
          out[o + 8] = dv.getUint32(b + 52, true);
        }
      } finally {
        w.free(buf, size);
      }
    }
    return { part, edited: w.x.zs_app_support_tree_edited(this.app, part) === 1, nodes: out };
  }

  // The trees of each part (supportTrees), and the note of a drop of the
  // trees of the user (zs_app_support_tree_note), or "".
  supportTreesAll() {
    const parts = [];
    const n = this.w.x.zs_app_part_count(this.app);
    for (let i = 0; i < n; i++) {
      const t = this.supportTrees(i);
      if (t) parts.push(t);
    }
    return { parts, note: this.supportTreeNote() };
  }

  supportTreeNote() {
    const w = this.w;
    const cap = 512;
    const buf = w.alloc(cap);
    try {
      const n = w.x.zs_app_support_tree_note(this.app, buf, cap);
      return n > 0 ? w.text(buf, Math.min(n, cap - 1)) : "";
    } finally {
      w.free(buf, cap);
    }
  }

  // An edit of the trees: fn(clampPtr) returns a status (0: done) or a
  // count; returns { rc, clamp }.
  treeEdit(fn) {
    const w = this.w;
    const c = w.cell + 32;
    w.dv.setUint32(c, 0, true);
    const rc = Number(fn(c));
    return { rc, clamp: w.u32(c) };
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

  // The changes for the layers from zmin up (zs_app_override_get): the
  // overrides that cover the first layer of the range, the last one of
  // each setting. [[name, value]].
  rangeChanges(zmin) {
    const w = this.w;
    const n = w.x.zs_app_override_count(this.app);
    const size = 32; // zs_override on wasm32
    const p = w.alloc(size);
    const out = new Map();
    try {
      for (let i = 0; i < n; i++) {
        if (w.x.zs_app_override_get(this.app, i, p) !== 0) continue;
        const lo = w.f64(p);
        const hi = w.f64(p + 8);
        if (lo > zmin + 1e-4 || hi < zmin - 1e-4) continue;
        out.set(w.text(w.u32(p + 16), w.u32(p + 20)), w.text(w.u32(p + 24), w.u32(p + 28)));
      }
    } finally {
      w.free(p, size);
    }
    return [...out];
  }

  // Part i (zs_app_part_get): its center on the bed, its turn, and its
  // size, or null.
  part(i) {
    const w = this.w;
    const size = 80; // zs_part on wasm32
    const p = w.alloc(size);
    try {
      if (w.x.zs_app_part_get(this.app, i, p) !== 0) return null;
      return {
        index: i,
        name: w.cstr(w.u32(p)),
        x: w.f64(p + 8),
        y: w.f64(p + 16),
        rotation: w.f64(p + 24),
        sizeX: w.f64(p + 32),
        sizeY: w.f64(p + 40),
        sizeZ: w.f64(p + 48),
        // Along the axes of the file, 1 = 100 %.
        scale: [w.f64(p + 56), w.f64(p + 64), w.f64(p + 72)],
      };
    } finally {
      w.free(p, size);
    }
  }

  // ---- one part ----

  // An action on part i: "duplicate", "split", "smart", "less-support",
  // "reset", or "remove". Returns the index of a new part (duplicate), the
  // count of new parts (split; 0 for one body), or 0, or a negative
  // status.
  partAction(i, action) {
    const x = this.w.x;
    switch (action) {
      case "duplicate": return x.zs_app_part_duplicate(this.app, i);
      case "split": return x.zs_app_part_split(this.app, i);
      case "smart": return -x.zs_app_part_place(this.app, i, 0, 0);
      case "less-support": return -x.zs_app_part_place(this.app, i, 1, 0);
      case "reset": return -x.zs_app_part_reset(this.app, i);
      case "mirror-x": return -x.zs_app_part_mirror(this.app, i, 0);
      case "mirror-y": return -x.zs_app_part_mirror(this.app, i, 1);
      case "remove": return -x.zs_app_part_remove(this.app, i);
      default: return -2;
    }
  }

  // The zslice settings of part i: [[name, value]] (its own values, not
  // the values of the plate).
  partSettings(i) {
    const w = this.w;
    const text = w.readText((b, c, l) => w.x.zs_app_part_settings(this.app, i, b, c, l)) ?? "";
    const out = [];
    for (const line of text.split("\n")) {
      const m = /^\s+([a-z]+\.[a-z0-9_]+) = (.*)$/.exec(line);
      if (m && !line.includes(": not used")) out.push([m[1], m[2]]);
    }
    return out;
  }

  // ---- the paint of a part (zs_app_part_mesh, zs_app_part_paint_*) ----

  // The mesh of part i at its place: { verts: Float32Array (x, y, z),
  // faces: Uint32Array }, copies out of wasm memory, or null.
  partMesh(i) {
    const w = this.w;
    const c = w.cell;
    if (w.x.zs_app_part_mesh(this.app, i, c, c + 4, c + 8, c + 12) !== 0) return null;
    const vp = w.u32(c);
    const nv = w.u32(c + 4);
    const fp = w.u32(c + 8);
    const nf = w.u32(c + 12);
    const buf = w.x.memory.buffer;
    return { verts: new Float32Array(buf.slice(vp, vp + 12 * nv)), faces: new Uint32Array(buf.slice(fp, fp + 12 * nf)) };
  }

  // The paint of part i as text (see zs_app_part_paint_get).
  partPaint(i) {
    const w = this.w;
    return w.readText((b, cap, l) => w.x.zs_app_part_paint_get(this.app, i, b, cap, l)) ?? "";
  }

  setPartPaint(i, text) {
    const w = this.w;
    const bytes = new TextEncoder().encode(text);
    return w.withBytes(bytes, (p, n) => w.x.zs_app_part_paint_set(this.app, i, p, n)) === 0;
  }

  // Paints the body of some layers with filament `filament` (from 1): the
  // beads of View.connectedBeads (zs_app_paint_body). Returns the count of
  // triangles whose paint changed, or -1.
  paintBody(beads, filament) {
    const w = this.w;
    const bytes = new Uint8Array(beads.buffer, beads.byteOffset, beads.byteLength);
    return w.withBytes(bytes, (p) => (w.x.zs_app_paint_body(this.app, p, beads.length, filament, w.cell) === 0 ? w.u32(w.cell) : -1));
  }

  // ---- the labels of a part (zs_app_part_labels_get, zs_app_label_*) ----

  // The labels of part i: an array of label objects (the JSON of
  // include/zslice-app.h), or [] for no part.
  partLabels(i) {
    const w = this.w;
    const text = w.readText((b, cap, l) => w.x.zs_app_part_labels_get(this.app, i, b, cap, l));
    try {
      return text ? JSON.parse(text) : [];
    } catch {
      return [];
    }
  }

  // Adds a label to part i: its id, or -1 for a bad label.
  labelAdd(i, label) {
    const w = this.w;
    const bytes = new TextEncoder().encode(JSON.stringify(label));
    const rc = w.withBytes(bytes, (p, n) => w.x.zs_app_label_add(this.app, i, p, n, w.cell));
    return rc === 0 ? w.u32(w.cell) : -1;
  }

  // Replaces label `id` of part i: true when the core accepts it.
  labelUpdate(i, id, label) {
    const w = this.w;
    const bytes = new TextEncoder().encode(JSON.stringify(label));
    return w.withBytes(bytes, (p, n) => w.x.zs_app_label_update(this.app, i, id, p, n)) === 0;
  }

  labelRemove(i, id) {
    return this.w.x.zs_app_label_remove(this.app, i, id) === 0;
  }

  // The facts of label `id` of part i for its card (zs_app_label_info),
  // or null.
  labelInfo(i, id) {
    const w = this.w;
    const text = w.readText((b, cap, l) => w.x.zs_app_label_info(this.app, i, id, b, cap, l));
    try {
      return text ? JSON.parse(text) : null;
    } catch {
      return null;
    }
  }

  // ---- the filaments of the plate (zs_app_filament_*) ----

  // The filaments: [{ index, name, material, color, nozzleTemp, nozzle,
  // fromPrinter, hand, tray, slot }]. Filament 0 is the filament of the
  // settings. fromPrinter: the values come from a spool of the printer
  // (its tray and its holder "A1"); hand: the user set a value.
  filaments() {
    const w = this.w;
    const n = w.x.zs_app_filament_count(this.app);
    const get = (i, name) => w.withString(name, (s) => w.readText((b, c, l) => w.x.zs_app_filament_get(this.app, i, s, b, c, l))) ?? "";
    const out = [];
    for (let i = 0; i < n; i++) {
      out.push({
        index: i,
        name: get(i, "filament.name"),
        material: get(i, "filament.material"),
        color: get(i, "filament.color"),
        nozzleTemp: Number(get(i, "filament.nozzle_temp")),
        nozzle: Number(get(i, "filament.nozzle")) || 0,
        fromPrinter: get(i, "source.printer") === "1",
        hand: get(i, "source.hand") === "1",
        tray: Number(get(i, "source.tray") || -1),
        slot: get(i, "source.slot"),
      });
    }
    return out;
  }

  // Adds a filament. Returns its index, or -1.
  filamentAdd() {
    const w = this.w;
    return w.x.zs_app_filament_add(this.app, w.cell) === 0 ? w.u32(w.cell) : -1;
  }

  filamentRemove(i) {
    return this.w.x.zs_app_filament_remove(this.app, i) === 0;
  }

  // Sets a value of filament i ("filament.color"). Returns "" or the
  // reason.
  filamentSet(i, name, value) {
    const w = this.w;
    const rc = w.withStrings([name, String(value)], (n, v) => w.x.zs_app_filament_set(this.app, i, n, v));
    if (rc === 0) return "";
    return `The value is not valid (${statusText(rc)}).`;
  }

  // Applies a filament profile text to filament i (i >= 1). "" or the
  // reason.
  filamentProfile(i, name, text) {
    const w = this.w;
    const rc = w.withStrings([name, text], (n, t) => w.x.zs_app_filament_profile(this.app, i, n, t));
    return rc === 0 ? "" : `The profile did not apply (${statusText(rc)}).`;
  }

  // Makes the filaments of the plate the spools of a printer
  // (zs_app_filaments_from_printer). json: the reply of a printdeck, or
  // { filaments: [...] }. flags 1: the filaments set by hand follow too.
  // Returns { ok, changed, message }.
  filamentsFromPrinter(name, json, flags) {
    const w = this.w;
    const cap = 1024;
    const msg = w.alloc(cap);
    const changed = w.alloc(4);
    w.u8[msg] = 0;
    w.dv.setInt32(changed, 0, true);
    try {
      const bytes = new TextEncoder().encode(json);
      const rc = w.withString(name, (n) => w.withBytes(bytes, (b, len) => w.x.zs_app_filaments_from_printer(this.app, n, b, len, flags | 0, changed, msg, cap)));
      return { ok: rc === 0, changed: w.i32(changed) !== 0, message: w.cstr(msg) };
    } finally {
      w.free(msg, cap);
      w.free(changed, 4);
    }
  }

  // The filament of the last slice: { grams: [g of each filament],
  // changes, flushG }, or null.
  filamentStats() {
    const w = this.w;
    const n = w.x.zs_app_filament_count(this.app);
    // The scratch cell has room for 16 values and the two counts.
    const c = w.cell;
    if (w.x.zs_app_filament_stats(this.app, c, 16, c + 128, c + 136) !== 0) return null;
    const grams = [];
    for (let i = 0; i < Math.min(n, 16); i++) grams.push(w.f64(c + 8 * i));
    return { grams, changes: w.u32(c + 128), flushG: w.f64(c + 136) };
  }

  // The value of a setting of part i, or null (the value of the plate).
  partSetting(i, name) {
    const w = this.w;
    return w.withString(name, (n) => w.readText((b, c, l) => w.x.zs_app_part_setting_get(this.app, i, n, b, c, l)));
  }

  // Sets a setting of part i (value null: the value of the plate again).
  // Returns "" or the reason.
  setPartSetting(i, name, value) {
    const w = this.w;
    const rc = value === null
      ? w.withString(name, (n) => w.x.zs_app_part_setting_set(this.app, i, n, 0))
      : w.withStrings([name, String(value)], (n, v) => w.x.zs_app_part_setting_set(this.app, i, n, v));
    if (rc === 0) return "";
    if (rc === 14) return "The value is out of the limits.";
    return `The value is not valid (${statusText(rc)}).`;
  }

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

  // The .gcode.3mf file of the slice for a Bambu Lab printer
  // (zs_app_bambu_file), as bytes, or null.
  bambuFile(title) {
    const w = this.w;
    const c = w.cell;
    const rc = w.withString(title || "zslice", (t) => w.x.zs_app_bambu_file(this.app, t, c, c + 4));
    if (rc !== 0) return null;
    const p = w.u32(c);
    const n = w.u32(c + 4);
    const bytes = w.u8.slice(p, p + n);
    w.x.zs_buffer_free(p, n);
    return bytes;
  }
}
