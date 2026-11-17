// worker.js: the Web Worker that owns the app core (core.js). A slice runs
// here, on the thread of the worker, so the page stays responsive.
//
// Messages from the page: { id, op, ...args }. The worker answers each
// with { id, result } or { id, error }. A change of a setting or the model
// asks for a slice; the worker slices when no other message waits, so a
// fast series of changes gives one slice. Events to the page: { event:
// "progress", progress }, { event: "sliced", ... }, { event: "failed" }.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { Wasm } from "./wasm.js";
import { Core, STATE } from "./core.js";

let core = null;
let mode = 0; // the color mode of the scene (enum zs_view_mode)
let sliceWanted = false;
let sliceTimer = 0;
let lastProgress = 0;

function post(msg, transfer = []) {
  self.postMessage(msg, transfer);
}

function onEvent(event, progress) {
  // ZS_EVENT_PROGRESS: at most each 2 %, so the page gets few messages.
  if (event === 1 && (progress - lastProgress >= 0.02 || progress < lastProgress)) {
    lastProgress = progress;
    post({ event: "progress", progress });
  }
}

// The result of a slice for the page.
function sendResult(ms) {
  const state = core.state();
  if (state !== STATE.done) {
    post({ event: "failed", state });
    return;
  }
  const scene = core.scene(mode);
  const layers = core.layers();
  const msg = {
    event: "sliced",
    ms,
    stats: core.stats(),
    featureStats: core.featureStats(),
    layers,
    scene,
    mode,
    marks: core.markCount(),
    parts: core.w.x.zs_app_part_count(core.app),
  };
  post(msg, scene ? [scene, layers.z.buffer, layers.height.buffer, layers.endTime.buffer, layers.slowed.buffer] : []);
}

function wantSlice() {
  sliceWanted = true;
  clearTimeout(sliceTimer);
  // A timer, so that the messages that wait now come first.
  sliceTimer = setTimeout(runSlice, 0);
}

function runSlice() {
  if (!sliceWanted || core.state() === STATE.empty) return;
  sliceWanted = false;
  post({ event: "slicing" });
  lastProgress = 0;
  const t0 = performance.now();
  const r = core.slice();
  const ms = performance.now() - t0;
  if (r.error) post({ event: "failed", state: core.state(), error: r.error });
  else sendResult(ms);
}

// The settings, the quality, and the saved state, after a change.
function settingsState() {
  return { ...core.snapshot(), saved: core.savedState() };
}

const ops = {
  async init({ module, saved, mode: m }) {
    mode = m ?? 0;
    const wasm = await Wasm.create(module, onEvent);
    core = new Core(wasm);
    const errors = core.restore(saved);
    return { errors, ...settingsState() };
  },

  load({ name, bytes }) {
    core.loadStl(name, new Uint8Array(bytes));
    wantSlice();
    return { info: core.modelInfo() };
  },

  set({ name, value }) {
    const error = core.set(name, value);
    if (!error) wantSlice();
    return { error, ...settingsState() };
  },

  reset({ name }) {
    const error = core.reset(name);
    if (!error) wantSlice();
    return { error, ...settingsState() };
  },

  quality({ name }) {
    const error = core.setQuality(name, true);
    if (!error) wantSlice();
    return { error, ...settingsState() };
  },

  profile({ group, text }) {
    const error = core.loadProfile(group, text);
    if (!error) wantSlice();
    return { error, ...settingsState() };
  },

  // A new color mode: the scene again, with no new slice.
  mode({ value }) {
    mode = value;
    if (core.state() === STATE.done) sendResult(0);
    return {};
  },

  slice() {
    wantSlice();
    return {};
  },

  // ---- a selected line ----

  // The Selected page of a path. With `refind` ({ layer, feature, x, y }
  // of the line before a new slice): the same line in the new slice.
  inspect({ path, seg, refind }) {
    if (core.state() !== STATE.done) return { info: null };
    let p = path;
    if (refind) p = core.refind(refind.layer, refind.feature, refind.x, refind.y);
    return { info: p >= 0 ? core.inspect(p, seg ?? -1) : null };
  },

  report({ path }) {
    return { text: core.lineReport(path) };
  },

  setScoped({ name, value, zmin, zmax, perLayer }) {
    const error = core.setScoped(name, value, zmin, zmax, perLayer);
    if (!error) wantSlice();
    return { error, ...settingsState() };
  },

  resetScoped({ name, zmin, zmax, z }) {
    const error = core.resetScoped(name, zmin, zmax, z);
    if (!error) wantSlice();
    return { error, ...settingsState() };
  },

  // ---- the context menu ----

  // Support marks at the selected segment (view3d.c: mark_place).
  markAdd({ path, seg, kind }) {
    const pt = core.pathPoint(path, seg);
    if (!pt) return {};
    core.w.x.zs_app_mark_add(core.app, pt[0], pt[1], pt[2], 3, kind);
    wantSlice();
    return {};
  },

  markRemoveNear({ path, seg }) {
    const pt = core.pathPoint(path, seg);
    if (!pt) return {};
    if (core.w.x.zs_app_mark_remove_near(core.app, pt[0], pt[1], pt[2], 3) > 0) wantSlice();
    return {};
  },

  markSet({ index, kind, r }) {
    core.w.x.zs_app_mark_set(core.app, index, kind, r);
    wantSlice();
    return {};
  },

  markRemove({ index }) {
    core.w.x.zs_app_mark_remove(core.app, index);
    wantSlice();
    return {};
  },

  marksClear() {
    core.w.x.zs_app_marks_clear(core.app);
    wantSlice();
    return {};
  },

  // The part of a path: "Put this side on the bed", and its placement.
  putDown({ path, seg }) {
    const part = core.partOfPath(path);
    const pt = core.pathPoint(path, seg);
    if (part < 0 || !pt) return {};
    if (core.w.x.zs_app_part_put_down_at(core.app, part, pt[0], pt[1], pt[2]) === 0) wantSlice();
    return {};
  },

  place({ path, code }) {
    const part = core.partOfPath(path);
    if (part < 0) return {};
    // 0 smart, 1 less support, 10 + axis: strong along that axis.
    const rc = code >= 10 ? core.w.x.zs_app_part_place(core.app, part, 2, code - 10) : core.w.x.zs_app_part_place(core.app, part, code, 0);
    if (rc === 0) wantSlice();
    return {};
  },

  add({ name, bytes }) {
    core.addStl(name, new Uint8Array(bytes));
    wantSlice();
    return { info: core.modelInfo(), parts: core.w.x.zs_app_part_count(core.app) };
  },

  plate({ action }) {
    const x = core.w.x;
    if (action === "smart") x.zs_app_plate_smart_place(core.app);
    else if (action === "arrange") x.zs_app_plate_arrange(core.app);
    else if (action === "clear") {
      x.zs_app_plate_clear(core.app);
      core.modelName = "";
      // An empty plate: an empty scene for the page.
      const scene = core.scene(mode);
      post({ event: "cleared", scene }, scene ? [scene] : []);
      return {};
    }
    wantSlice();
    return {};
  },

  // The plate as a 3MF file, for keep.js.
  plate3mf() {
    const bytes = core.plate3mf();
    return { bytes: bytes ? bytes.buffer : null, name: core.modelName };
  },

  gcode() {
    const bytes = core.gcode();
    return { bytes: bytes ? bytes.buffer : null, name: core.modelName };
  },
};

self.onmessage = async (e) => {
  const { id, op, ...args } = e.data;
  try {
    const result = await ops[op](args);
    const transfer = result?.bytes ? [result.bytes] : [];
    post({ id, result }, transfer);
  } catch (err) {
    post({ id, error: String(err?.message ?? err) });
  }
};
