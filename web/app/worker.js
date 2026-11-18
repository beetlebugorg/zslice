// worker.js: the Web Worker that owns the app core (core.js). A slice runs
// here, on the thread of the worker, so the page stays responsive.
//
// Messages from the page: { id, op, ...args }. The worker answers each
// with { id, result } or { id, error }. A change of a setting or the model
// asks for a slice; the worker slices when no other message waits, so a
// fast series of changes gives one slice. Events to the page: { event:
// "progress", progress }, { event: "sliced", ... }, { event: "failed" }.
//
// The plate set is in the core (zs_set, src/app/plate_set.zig): one app
// for each plate, the active plate, the status of each, and the order of
// the slices. The worker keeps the timers and the messages. The ops of
// the page work on the active plate; after a change, the worker tells the
// set (zs_set_changed), and slices with zs_set_step when no message waits.
// Events of the set: { event: "plates" } (the list, the active plate, the
// status of each, and the changes for the view of the page as bytes,
// zs_set_sync_write), and { event: "stale", scene } (the old slice of a
// new active plate that slices again).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { Wasm, statusText } from "./wasm.js";
import { Core, STATE } from "./core.js";

let wasm = null;
let set = 0; // the zs_set
let infos = null; // the setting infos, shared by the Cores
const cores = new Map(); // a Core for each app of the set
let mode = 0; // the color mode of the scene (enum zs_view_mode)
let sliceTimer = 0;
let lastProgress = 0;
let slicing = -1; // the plate that slices now
let failStatus = 0; // the status of the last ZS_EVENT_FAILED
let warming = false; // a warm-up slice runs: its events do not go to the page
let platesDirty = false; // the list changed: a "plates" event waits

function post(msg, transfer = []) {
  self.postMessage(msg, transfer);
}

// The events of the apps of the set (env.zs_web_set_event).
function onSetEvent(plate, event, progress, status) {
  if (warming) return;
  if (event === 5) {
    // ZS_EVENT_PLATES: the worker sends the list when the op ends.
    platesDirty = true;
    return;
  }
  if (event === 3) failStatus = status;
  // ZS_EVENT_PROGRESS: at most each 2 %, so the page gets few messages.
  if (event === 1 && (progress - lastProgress >= 0.02 || progress < lastProgress)) {
    lastProgress = progress;
    post({ event: "progress", progress, plate });
  }
}

// The index of the active plate, and the Core of a plate.
function activeIndex() { return wasm.x.zs_set_active(set); }
function coreAt(i) {
  const app = wasm.x.zs_set_app(set, i);
  if (!app) return null;
  let c = cores.get(app);
  if (!c) {
    c = new Core(wasm, infos, app);
    cores.set(app, c);
  }
  return c;
}
// The Core of the active plate.
let core = null;
function syncCore() {
  core = coreAt(activeIndex());
  // The Cores of the apps that are not in the set now.
  const live = new Set();
  const n = wasm.x.zs_set_count(set);
  for (let i = 0; i < n; i++) live.add(wasm.x.zs_set_app(set, i));
  for (const app of cores.keys()) if (!live.has(app)) cores.delete(app);
}

// ---- the warm-up slice ----
//
// The browser first runs each wasm function with code from a fast, simple
// compiler. It makes optimized code for a function only after the function
// has run for a time. So the first slice of a visit takes about twice the
// time of the later ones. A slice of a small part, made here in code, runs
// the hot functions before the user opens a model: the first slice of the
// user then starts with optimized code. (On a later visit, the browser can
// load the optimized code from its cache: see README.md.)

// A binary STL of a sphere of 24 mm on the bed.
function warmStl() {
  const radius = 12;
  const seg = 48;
  const at = (u, v) => {
    const a = (u / seg) * 2 * Math.PI;
    const b = (v / (seg / 2)) * Math.PI;
    return [radius * Math.sin(b) * Math.cos(a), radius * Math.sin(b) * Math.sin(a), radius + radius * Math.cos(b)];
  };
  const tris = [];
  for (let v = 0; v < seg / 2; v++) {
    for (let u = 0; u < seg; u++) {
      const a = at(u, v);
      const c = at(u + 1, v + 1);
      if (v > 0) tris.push([a, c, at(u + 1, v)]);
      if (v < seg / 2 - 1) tris.push([a, at(u, v + 1), c]);
    }
  }
  const buf = new ArrayBuffer(84 + 50 * tris.length);
  const dv = new DataView(buf);
  dv.setUint32(80, tris.length, true);
  let o = 84;
  for (const t of tris) {
    o += 12; // the normal: zslice does not read it
    for (const p of t) for (const x of p) { dv.setFloat32(o, x, true); o += 4; }
    o += 2;
  }
  return new Uint8Array(buf);
}

// Slices the warm-up part in an app of its own, so the app of the page
// does not change. It takes about 0.3 s. A message of the page waits for
// that time.
function warmUp() {
  if (!core || core.state() !== STATE.empty) return;
  const w = core.w;
  const x = w.x;
  if (x.zs_app_new_web(w.cell) !== 0) return;
  const app = w.u32(w.cell);
  warming = true;
  try {
    const rc = w.withString("warm.stl", (n) => w.withBytes(warmStl(), (p, len) => x.zs_app_load_stl(app, n, p, len)));
    if (rc === 0) x.zs_app_request_slice(app);
  } finally {
    warming = false;
    x.zs_app_free(app);
  }
}

// The result of a slice of plate i for the page. Only the active plate
// sends its slice: the beads of the other plates go in the "plates" event.
function sendResult(i, ms, turn) {
  if (i !== activeIndex()) return;
  const c = coreAt(i);
  const state = c.state();
  // A canceled slice: the change that canceled it waits, and its slice
  // comes next.
  if (state === STATE.ready && ms > 0) {
    post({ event: "canceled" });
    return;
  }
  if (state !== STATE.done) {
    if (state === STATE.failed) post({ event: "failed", state, error: failStatus ? statusText(failStatus) : "" });
    return;
  }
  const scene = sceneOf(i);
  const layers = c.layers();
  const msg = {
    event: "sliced",
    plate: i,
    ms,
    stats: c.stats(),
    featureStats: c.featureStats(),
    layers,
    scene,
    mode,
    marks: c.markCount(),
    areas: c.supportAreas(),
    parts: c.w.x.zs_app_part_count(c.app),
    // Each part on the bed, with no part on another (zs_app_plate_fits).
    fits: c.w.x.zs_app_plate_fits(c.app) === 1,
    tiny: tinyParts(c),
    turn,
  };
  post(msg, scene ? [scene, layers.z.buffer, layers.height.buffer, layers.endTime.buffer, layers.slowed.buffer] : []);
}

// The scene bytes of plate i (zs_set_plate_scene): of its last slice, or
// its old beads while it slices again. An ArrayBuffer, or null.
function sceneOf(i) {
  const w = wasm;
  if (w.x.zs_set_plate_scene(set, i, w.cell, w.cell + 4) !== 0) return null;
  const p = w.u32(w.cell);
  const n = w.u32(w.cell + 4);
  return w.u8.slice(p, p + n).buffer;
}

// The active plate with no parts left (the last part removed, or moved to
// another plate): no slice, and no beads. The page gets an empty scene.
// Returns true if the plate is empty.
function clearIfEmpty() {
  if (core.w.x.zs_app_part_count(core.app) > 0) return false;
  core.modelName = "";
  wasm.x.zs_set_changed(set, activeIndex());
  wasm.x.zs_set_name(set, activeIndex(), 0);
  postPlates();
  const scene = core.scene(mode);
  post({ event: "cleared", scene, plate: activeIndex() }, scene ? [scene] : []);
  return true;
}

// A live turn (partTurn with total): its app and the turn so far.
let coarse = null;
// The most parts on a plate for a live turn.
const LIVE_PARTS = 2;

// The active plate waits for a slice.
function wantSlice() {
  wasm.x.zs_set_changed(set, activeIndex());
  schedule();
}

// A change of a part while a drag or keys go on: the slice waits until
// sliceHeld (the end of the drag, or a pause of the keys).
function sliceOrHold(hold) {
  if (hold) wasm.x.zs_set_changed_held(set, activeIndex());
  else wantSlice();
}

function schedule() {
  clearTimeout(sliceTimer);
  // A timer, so that the messages that wait now come first.
  sliceTimer = setTimeout(runSlice, 0);
}

// Slices one plate (zs_set_step): the active plate first, then the other
// plates in order. Then the next, after the messages that wait.
function runSlice() {
  const i = wasm.x.zs_set_next(set);
  if (i < 0) {
    if (platesDirty) postPlates();
    return;
  }
  const c = coreAt(i);
  if (c.state() !== STATE.empty) {
    postPlates(i);
    if (i === activeIndex()) post({ event: "slicing", plate: i });
    // The page stops this slice with the cancel flag of its app.
    if (wasm.shared) post({ event: "cancel-flag", memory: wasm.x.memory, address: wasm.x.zs_app_cancel_address(c.app) });
  }
  lastProgress = 0;
  failStatus = 0;
  slicing = i;
  // The turn of a live turn that this slice shows.
  const turn = coarse ? coarse.total : undefined;
  const t0 = performance.now();
  wasm.x.zs_set_step(set);
  const ms = performance.now() - t0;
  slicing = -1;
  sendResult(i, ms, turn);
  postPlates();
  if (wasm.x.zs_set_next(set) >= 0) schedule();
}

// ---- the plate set ----

const STATUS = ["empty", "stale", "slicing", "done", "failed", "resin"];

// The facts of plate i (zs_set_plate_info).
function plateInfo(i) {
  const w = wasm;
  const at = w.cell;
  if (w.x.zs_set_plate_info(set, i, at) !== 0) return null;
  const dv = w.dv;
  const key = w.cstr(w.u32(at + 36)).split("\n");
  return {
    id: Number(dv.getBigUint64(at, true)),
    status: STATUS[dv.getInt32(at + 8, true)] ?? "stale",
    bed: [dv.getFloat64(at + 16, true), dv.getFloat64(at + 24, true)],
    name: w.cstr(w.u32(at + 32)),
    model: key[0] ?? "",
    printer: key[1] ?? "",
    parts: w.u32(at + 40),
    message: w.cstr(w.u32(at + 44)),
  };
}

// The list of the plates for the page: the name, the status, the bed size,
// and the printer of each, the active plate, and the changes for the view
// of the page (zs_set_sync_write). `slicingPlate`: a plate that starts its
// slice now.
function postPlates(slicingPlate = -1) {
  platesDirty = false;
  syncCore();
  const n = wasm.x.zs_set_count(set);
  const plates = [];
  for (let i = 0; i < n; i++) {
    const p = plateInfo(i);
    if (i === slicingPlate) p.status = "slicing";
    plates.push(p);
  }
  const w = wasm;
  let sync = null;
  if (w.x.zs_set_sync_write(set, w.cell, w.cell + 4) === 0) {
    const ptr = w.u32(w.cell);
    const len = w.u32(w.cell + 4);
    sync = w.u8.slice(ptr, ptr + len).buffer;
    w.x.zs_buffer_free(ptr, len);
  }
  post({ event: "plates", active: activeIndex(), plates, sync }, sync ? [sync] : []);
}

// Sends the list, then the slice of the active plate (or its old slice
// while it slices again). The beads of the plate that was active go in
// the list.
function showActive() {
  postPlates();
  const i = activeIndex();
  const p = plateInfo(i);
  if (p.status === "done") sendResult(i, 0);
  else if (core.state() === STATE.empty) {
    const scene = core.scene(mode);
    post({ event: "cleared", scene, plate: i }, scene ? [scene] : []);
  } else {
    // Its last slice, or an empty scene (no slice yet).
    const scene = sceneOf(i) ?? core.scene(mode);
    post({ event: "stale", scene, plate: i }, scene ? [scene] : []);
  }
  schedule();
}

// The settings, the quality, and the saved state, after a change.
function settingsState() {
  return { ...core.snapshot(), saved: core.savedState() };
}

// ---- undo and the history (src/app/history.zig) ----
//
// The core of each plate keeps its undo list, and notes each change. A
// step ends when the user ends the change, with no timer:
// - an edit of the setting whose editor has the focus: when the focus
//   moves (historyFocus), so a drag of its slider is one step;
// - a drag (ops with hold): at its end (sliceHeld);
// - each other change (a button, a menu, a choice): at once.

// A drag goes on (an op with hold): its changes are one step, which ends
// after sliceHeld.
let histHolding = false;
// The setting whose editor has the focus (historyFocus), or null.
let histFocus = null;

// Ends the step of the changes so far.
function historyCommit() {
  if (core && core.historyCommit(Date.now())) post({ event: "history" });
}

// Ends the step of the changes that wait, if any.
function commitPending() {
  if (core && core.historyPending()) historyCommit();
}

// After an undo, a redo, or a jump (the bits of enum zs_history_restored):
// the name of the plate, the scene of an empty plate, and a new slice.
function historyRestored(bits) {
  if (!(bits & 1)) return;
  const parts = core.w.x.zs_app_part_count(core.app);
  if (bits & 2) {
    if (parts > 0) core.modelName = "plate.3mf";
    else {
      core.modelName = "";
      const scene = core.scene(mode);
      post({ event: "cleared", scene, plate: activeIndex() }, scene ? [scene] : []);
    }
  }
  // A plate with no parts: the set drops its beads.
  if (parts > 0) wantSlice();
  else wasm.x.zs_set_changed(set, activeIndex());
}

// The steps, the oldest first: their time, kind, and changes in words.
function historyList() {
  const steps = [];
  const n = core.historyCount();
  for (let i = 0; i < n; i++) {
    const s = core.historyStep(i);
    steps.push(i === 0 ? { ...s, text: "The start" } : s);
  }
  return { current: core.historyCurrent(), steps };
}

// The ops that change the settings, and the ops that change the plate:
// each starts or extends a step.
const SETTING_OPS = new Set(["refineApply", "set", "reset", "quality", "profile", "setScoped", "resetScoped"]);
// The parts whose largest side is under 3 mm: a file in inches or in
// meters loads that small. The print card offers a scale.
function tinyParts(c) {
  const out = [];
  const n = c.w.x.zs_app_part_count(c.app);
  for (let i = 0; i < n && out.length < 8; i++) {
    const p = c.part(i);
    if (p && Math.max(p.sizeX, p.sizeY, p.sizeZ) < 3) out.push({ index: i, name: p.name, size: Math.max(p.sizeX, p.sizeY, p.sizeZ), scale: p.scale[0] });
  }
  return out;
}

const PLATE_OPS = new Set(["load", "add", "plate", "projectLoad", "partAction", "partCut", "partMove", "partFill", "partToPlate", "editAdd", "editDot", "editRemove", "partSettingSet", "partPutDown", "partTurn", "putDown", "place", "partMove", "partRotate", "partScale", "partSettle", "markAdd", "markRemoveNear", "markSet", "markRemove", "marksClear", "supportAreaAdd", "supportAreaSet", "supportAreaKind", "supportAreaRemove"]);

const ops = {
  // ---- the model and the plate: open, add, and arrange ----

  async init({ module, saved, mode: m }) {
    mode = m ?? 0;
    wasm = await Wasm.create(module, () => {}, onSetEvent);
    // The threads of a slice: this worker is one, and one CPU stays free
    // for the page, as in the GTK app.
    wasm.startThreads(Math.max((navigator.hardwareConcurrency ?? 1) - 2, 0), (data) => {
      new Worker(new URL("./thread.js", import.meta.url), { type: "module" }).postMessage(data);
    });
    infos = wasm.settingInfos();
    if (wasm.x.zs_set_new_web(wasm.cell) !== 0) throw new Error("zslice: no plate set");
    set = wasm.u32(wasm.cell);
    wasm.x.zs_set_view_mode(set, mode);
    syncCore();
    // With a shared memory (the module with threads), the page can stop a
    // slice that runs: it sets the cancel flag of the app (client.js).
    if (wasm.shared) post({ event: "cancel-flag", memory: wasm.x.memory, address: wasm.x.zs_app_cancel_address(core.app) });
    const errors = core.restore(saved);
    // After the threads start, and only if the plate is still empty then.
    setTimeout(warmUp, 300);
    postPlates();
    return { errors, ...settingsState() };
  },

  // A file opens on the active plate. keepSet: the other plates stay
  // (plates that the user made); else the set becomes this one plate.
  load({ name, bytes, keepSet }) {
    if (wasm.x.zs_set_count(set) > 1 && !keepSet) {
      wasm.x.zs_set_keep_active(set);
      syncCore();
    }
    core.loadStl(name, new Uint8Array(bytes));
    wasm.withString(name, (n) => wasm.x.zs_set_name(set, activeIndex(), n));
    wantSlice();
    return { info: core.modelInfo() };
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
      clearIfEmpty();
      return {};
    }
    wantSlice();
    return {};
  },

  // ---- the settings ----

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

  // A new color mode: the scenes again, with no new slice.
  mode({ value }) {
    mode = value;
    wasm.x.zs_set_view_mode(set, mode);
    const i = activeIndex();
    if (plateInfo(i)?.status === "done") sendResult(i, 0);
    postPlates();
    return {};
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

  slice() {
    wantSlice();
    return {};
  },

  // ---- the plate set ----

  // A new empty plate after the others, with the settings of the active
  // plate. It becomes the active plate.
  plateAdd() {
    commitPending();
    wasm.x.zs_set_add(set);
    syncCore();
    showActive();
    return { index: activeIndex(), count: wasm.x.zs_set_count(set), ...settingsState() };
  },

  // Removes plate i (zs_set_remove). The plate on its left becomes the
  // active plate if plate i was active. The last plate stays, empty.
  plateRemove({ index }) {
    commitPending();
    const rc = wasm.x.zs_set_remove(set, index);
    syncCore();
    showActive();
    return { ok: rc === 0, index: activeIndex(), info: core.modelInfo(), parts: core.w.x.zs_app_part_count(core.app), ...settingsState() };
  },

  // Plate i becomes the active plate.
  plateActivate({ index }) {
    let ok = index >= 0 && index < wasm.x.zs_set_count(set);
    if (ok && index !== activeIndex()) {
      // The changes so far are a step of the plate that was active.
      commitPending();
      ok = wasm.x.zs_set_select(set, index) === 0;
      syncCore();
    }
    if (ok) showActive();
    return { ok, index: activeIndex(), info: core.modelInfo(), parts: core.w.x.zs_app_part_count(core.app), ...settingsState() };
  },

  // The sums of the plates (zs_set_totals).
  totals() {
    const w = wasm;
    const p = w.alloc(80);
    try {
      if (w.x.zs_set_totals(set, p) !== 0) return null;
      // zs_totals on wasm32: 4 sizes of 4 bytes, then 6 doubles at 16.
      return {
        plates: w.u32(p), sliced: w.u32(p + 4), missing: w.u32(p + 8), parts: w.u32(p + 12),
        timeS: w.f64(p + 16), filamentG: w.f64(p + 24), filamentMm: w.f64(p + 32),
        costFilament: w.f64(p + 40), costMachine: w.f64(p + 48), cost: w.f64(p + 56),
      };
    } finally {
      w.free(p, 80);
    }
  },

  // The time and the filament of each plate with a slice (zs_set_plate_totals).
  plateTotals() {
    const w = wasm;
    const out = [];
    const p = w.alloc(80);
    try {
      for (let i = 0; i < w.x.zs_set_count(set); i++) {
        out.push(w.x.zs_set_plate_totals(set, i, p) === 0 && w.u32(p + 4) > 0 ? { timeS: w.f64(p + 16), filamentG: w.f64(p + 24) } : null);
      }
    } finally {
      w.free(p, 80);
    }
    return { totals: out };
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

  // ---- the edits of the user (the line card) ----

  // An edit of the user on line `path` (zs_app_edit_add), then a slice.
  // With a key (read when the line was selected), it works while a slice
  // runs.
  editAdd({ path, key, layer, kind, value }) {
    const rc = key && key !== "0"
      ? core.w.x.zs_app_edit_add_key(core.app, BigInt(key), layer ?? 0, kind, value)
      : core.w.x.zs_app_edit_add(core.app, path, kind, value);
    if (rc !== 0) return { ok: false, rc };
    wantSlice();
    return { ok: true, count: core.w.x.zs_app_edit_count(core.app) };
  },

  // A drop of plastic on layer `layer` at (x, y), d mm wide
  // (zs_app_edit_add_dot), then a slice.
  editDot({ layer, z, x, y, d }) {
    const rc = z != null
      ? core.w.x.zs_app_edit_add_dot_z(core.app, layer, z, x, y, d)
      : core.w.x.zs_app_edit_add_dot(core.app, layer, x, y, d);
    if (rc !== 0) return { ok: false };
    wantSlice();
    return { ok: true };
  },

  // The edits of the user: [{ kind, value, layer, applied }].
  edits() {
    const w = core.w;
    const n = w.x.zs_app_edit_count(core.app);
    const out = [];
    const p = w.alloc(32);
    try {
      for (let i = 0; i < n; i++) {
        if (w.x.zs_app_edit_get(core.app, i, p, p + 8, p + 16, p + 20) !== 0) continue;
        out.push({ kind: w.i32(p), value: w.f64(p + 8), layer: w.u32(p + 16), applied: w.i32(p + 20) === 1 });
      }
    } finally {
      w.free(p, 32);
    }
    return out;
  },

  // Removes edit i, then a slice.
  editRemove({ index }) {
    const rc = core.w.x.zs_app_edit_remove(core.app, index);
    if (rc === 0) wantSlice();
    return { ok: rc === 0 };
  },

  // ---- undo and the history ----

  // The list does not end an edit that goes on.
  history() {
    return historyList();
  },

  // The refinements of the plate (its changes from the first slice) go in
  // the store of the app, in place of the last records of `project`. The
  // reply has the new store and the suggestions for the plate: each with
  // its line (for refineApply), its text, and the count of projects.
  refine({ store, project }) {
    const w = wasm;
    const a = core?.app;
    if (!a) return { store, suggestions: [] };
    const records = w.readText((b, c, l) => w.x.zs_app_refine_records(a, b, c, l)) ?? "";
    const merged = w.withString(store, (sp, sn) => w.withString(project, (pp) => w.withString(records, (rp, rn) =>
      w.readText((b, c, l) => w.x.zs_refine_merge(sp, sn, pp, rp, rn, b, c, l))))) ?? store;
    const text = w.withString(merged, (sp, sn) => w.withString(project, (pp) =>
      w.readText((b, c, l) => w.x.zs_app_refine_suggest(a, sp, sn, pp, b, c, l)))) ?? "";
    const suggestions = [];
    for (const line of text.split("\n")) {
      const f = line.split("\t");
      if (f.length < 7) continue;
      const [kind, , key, value, count, lo, hi] = f;
      // The words of the change, as the history writes them.
      const scope = kind === "layers" ? `layers:${lo}:${hi}` : kind === "part" ? "part:each part" : "print";
      const change = `${scope}\t${key}\t\t${value}\n`;
      const words = w.withString(change, (cp, cn) => w.readText((b, c, l) => w.x.zs_app_history_describe(a, cp, cn, b, c, l))) ?? "";
      const [where, what] = words.trim().split("\t");
      suggestions.push({ line, where: where ?? "", what: what ?? key, count: Number(count) });
    }
    return { store: merged, suggestions };
  },

  // Applies one suggestion of `refine`: one history step, then a slice.
  refineApply({ line }) {
    const w = wasm;
    const rc = w.withString(line, (p, n) => w.x.zs_app_refine_apply(core.app, p, n));
    if (rc !== 0) return { error: statusText(rc), ...settingsState() };
    wantSlice();
    return { ...settingsState() };
  },

  // The setting whose editor has the focus now, or null. A move of the
  // focus ends the edit: its changes so far are a step.
  historyFocus({ key }) {
    histFocus = key ?? null;
    if (core.historyFocus(histFocus, Date.now())) post({ event: "history" });
    return {};
  },

  undo() {
    const bits = core.historyUndo(Date.now());
    historyRestored(bits);
    return { ok: bits !== 0, ...settingsState() };
  },

  redo() {
    const bits = core.historyRedo(Date.now());
    historyRestored(bits);
    return { ok: bits !== 0, ...settingsState() };
  },

  // Clears the history after step `index`: goes to it first if it is not
  // the step now, then drops the later steps (they cannot be redone).
  historyTruncate({ index }) {
    historyRestored(core.historyTruncate(index, Date.now()));
    return { ...settingsState() };
  },

  historyGoto({ index }) {
    const bits = core.historyGoto(index, Date.now());
    historyRestored(bits);
    return { ok: bits !== 0, ...settingsState() };
  },

  // Undoes one change line of a step and keeps the others: a new step.
  historyRevert({ line }) {
    const rc = core.historyRevert(line);
    if (rc === 0) {
      historyCommit();
      wantSlice();
    }
    return { error: rc === 0 ? "" : (rc === 15 ? "A move of a part cannot be undone alone: go to the step before it." : `The change was not undone (${rc}).`), ...settingsState() };
  },

  // ---- the parts: move, turn, and the card (tools.js, turn.js, partcard.js) ----

  // The part of a line (path >= 0), or else the part at x, y on the bed
  // (bed: false for no bed point), or null.
  partAt({ path, bed, x, y }) {
    let i = path >= 0 ? core.partOfPath(path) : -1;
    if (i < 0 && bed) i = core.w.x.zs_app_part_at(core.app, x, y);
    return { part: i >= 0 ? core.part(i) : null };
  },

  // hold: a drag or a key goes on, so the slice waits (sliceHeld starts
  // it at the end): a turn or a move of a part slices once, when it ends.
  partMove({ index, x, y, hold }) {
    if (!Number.isFinite(x) || !Number.isFinite(y)) return { part: core.part(index) };
    if (core.w.x.zs_app_part_move(core.app, index, x, y) === 0) sliceOrHold(hold);
    return { part: core.part(index) };
  },

  // Scales part i to s times the size of its file (1 = 100 %), the same
  // along each axis.
  partScale({ index, s }) {
    if (!(s > 1e-3 && s < 1e3)) return { part: core.part(index) };
    if (core.w.x.zs_app_part_scale(core.app, index, s, s, s) === 0) sliceOrHold(false);
    return { part: core.part(index) };
  },

  partRotate({ index, step }) {
    const p = core.part(index);
    if (!p) return { part: null };
    if (core.w.x.zs_app_part_rotate(core.app, index, p.rotation + step) === 0) sliceOrHold(false);
    return { part: core.part(index) };
  },

  // Turns part `index` about X (axis 0) or Y (axis 1) by `degrees`, or
  // about Z (axis 2): the Turn tool.
  // total: the turn of the drag so far (degrees). During a drag (hold),
  // the part slices coarse at once, and the other parts keep their work:
  // the slice follows the ring. Its result names the turn that it shows.
  partTurn({ index, axis, degrees, hold, total }) {
    const x = core.w.x;
    let rc;
    if (axis === 2) {
      const p = core.part(index);
      if (!p) return { part: null };
      rc = x.zs_app_part_rotate(core.app, index, p.rotation + degrees);
    } else {
      rc = x.zs_app_part_turn(core.app, index, axis, degrees);
    }
    // A plate of many parts holds the slice to the release, as before: the
    // work of the whole plate after each slice (the G-code, the scene) is
    // slower than the turn now.
    if (rc === 0 && hold && total !== undefined && x.zs_app_part_count(core.app) <= LIVE_PARTS) {
      x.zs_app_set_coarse_part(core.app, index);
      coarse = { app: core.app, total };
      wantSlice();
    } else if (rc === 0) sliceOrHold(hold);
    return { part: core.part(index) };
  },

  // Physics after a turn: the part falls over if it cannot stand, and
  // rolls until it rests (with support on, it stays). degrees: the fall.
  partSettle({ index }) {
    const deg = core.w.x.zs_app_part_settle(core.app, index);
    // held: support keeps a part in place that would fall over.
    const held = deg === 0 && core.w.x.zs_app_part_stands(core.app, index) === 0;
    return { part: core.part(index), degrees: deg > 0 ? deg : 0, held };
  },

  // The end of a drag or of the keys of a part: the slice that waited.
  sliceHeld() {
    wasm.x.zs_set_release(set);
    // The end of a live turn: the full slice of the part.
    if (coarse) {
      wasm.x.zs_app_set_coarse_part(coarse.app, -1);
      coarse = null;
      wantSlice();
    }
    schedule();
    return {};
  },

  // Lays part `index` down on the side nearest to the point x, y, z (mm)
  // of its surface (a double click on a side).
  partPutDown({ index, x, y, z }) {
    if (core.w.x.zs_app_part_put_down_at(core.app, index, x, y, z) === 0) wantSlice();
    return { part: core.part(index) };
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

  partAction({ index, action }) {
    const r = core.partAction(index, action);
    // A split of one body changes nothing.
    if (action === "split" && r === 0) return { ok: false, part: core.part(index), message: "The part has one body: nothing to split." };
    if (r >= 0 && !clearIfEmpty()) wantSlice();
    const n = core.w.x.zs_app_part_count(core.app);
    const at = action === "duplicate" && r >= 0 ? r : index;
    return { ok: r >= 0, count: action === "split" ? r : 0, part: action === "remove" || at >= n ? null : core.part(at) };
  },

  // Cuts part `index` at height z (mm above the bed): two parts, at index
  // and index + 1 (zs_app_part_cut). flip: the top goes onto its cut face.
  // pegs: the most pegs (0: none), pegD: their diameter (mm).
  partCut({ index, z, flip, pegs, pegD }) {
    const r = core.w.x.zs_app_part_cut(core.app, index, z, flip ? 1 : 0, pegs ?? 0, pegD ?? 5);
    if (r <= 0) return { ok: false, message: r === 0 ? "The plane does not cut the part." : "The cut failed." };
    wantSlice();
    return { ok: true, pegs: r - 2, fits: core.w.x.zs_app_plate_fits(core.app) === 1, part: core.part(index) };
  },

  // The part `dir` steps from part `index` (Tab and Shift+Tab), around
  // the plate. index -1: the first part (or the last, for dir < 0).
  partStep({ index, dir }) {
    const n = core.w.x.zs_app_part_count(core.app);
    if (n === 0) return { part: null };
    const j = index < 0 ? (dir > 0 ? 0 : n - 1) : (((index + dir) % n) + n) % n;
    return { part: core.part(j) };
  },

  partSettings({ index }) {
    return { list: core.partSettings(index) };
  },

  partSettingSet({ index, name, value }) {
    const error = core.setPartSetting(index, name, value);
    if (!error) wantSlice();
    return { error, value: core.partSetting(index, name), list: core.partSettings(index) };
  },

  // Copies of part `index` until there are n in all, over new plates when
  // the bed is full (zs_set_fill). Returns { ok, copies, plates }.
  partFill({ index, n }) {
    commitPending();
    const w = wasm;
    const r = w.x.zs_set_fill(set, activeIndex(), index, n, w.cell);
    if (r < 0) return { ok: false };
    const plates = w.u32(w.cell);
    syncCore();
    postPlates();
    wantSlice();
    return { ok: true, copies: r, plates };
  },

  // Moves part `index` of the active plate to plate `to` (-1: a new
  // plate). Returns { ok, to }.
  partToPlate({ index, to }) {
    commitPending();
    const r = wasm.x.zs_set_part_move(set, activeIndex(), index, to);
    if (r < 0) return { ok: false };
    syncCore();
    postPlates();
    // The plate that gets the part slices in the background.
    if (clearIfEmpty()) schedule();
    else wantSlice();
    return { ok: true, to: r };
  },

  // ---- the measure tape and the printability check ----

  // The measurements of a line at its segment (for a circle or an arc
  // under the measure tape).
  measureAt({ path, seg }) {
    if (core.state() !== STATE.done) return { m: null };
    return { m: core.measure(path, seg) };
  },

  // The issues of the slice. It runs when the list opens, so a slice
  // stays fast.
  checks() {
    if (core.state() !== STATE.done) return { issues: null, empty: "Slice the plate first." };
    const issues = core.checks();
    if (!issues) return { issues: null, empty: "The check failed." };
    return { issues, empty: issues.length === 0 ? "No issues found." : "" };
  },

  // ---- gaps ----

  // The gaps of a layer, for the views and the count (null: no slice).
  gaps({ layer }) {
    if (core.state() !== STATE.done) return { gaps: null };
    const r = core.gaps(layer);
    return r ?? { gaps: null };
  },

  // The gap at x, y (mm) on a layer: its index, its facts, and the
  // settings that can close it; or index -1.
  gapAt({ layer, x, y }) {
    if (core.state() !== STATE.done) return { index: -1 };
    const index = core.gapAt(layer, x, y);
    if (index < 0) return { index };
    const r = core.gaps(layer);
    const gap = r?.gaps[index];
    if (!gap) return { index: -1 };
    return { index, gap, steps: core.gapAdvice(layer, index) };
  },

  // ---- the support marks (the context menu) ----

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

  // ---- the support areas (support.js) ----

  supportAreas() {
    return { areas: core.supportAreas() };
  },

  // A new area of kind `kind` with points pts ([[x, y, z], ...]).
  supportAreaAdd({ kind, pts, zLo, zHi }) {
    const index = core.supportAreaAdd(kind, pts, zLo ?? NaN, zHi ?? NaN);
    if (index >= 0) wantSlice();
    return { index, areas: core.supportAreas() };
  },

  // The overhang under the pointer of the support tool: { part, pts, zLo,
  // zHi }, or null.
  supportPick({ x, y, z }) {
    if (!core?.app) return { hot: null };
    return { hot: core.supportPick(x, y, z, 4) };
  },

  // New points for area `index`. hold: a drag goes on, so the slice waits
  // for sliceHeld.
  supportAreaSet({ index, pts, hold }) {
    if (core.supportAreaSet(index, pts)) sliceOrHold(hold);
    return {};
  },

  supportAreaKind({ index, kind }) {
    if (core.w.x.zs_app_support_area_set_kind(core.app, index, kind) === 0) wantSlice();
    return { areas: core.supportAreas() };
  },

  supportAreaRemove({ index }) {
    if (core.w.x.zs_app_support_area_remove(core.app, index) === 0) wantSlice();
    return { areas: core.supportAreas() };
  },

  // ---- printdeck.yml projects (project.js), and the project file ----

  projectPlan({ text, counts }) {
    return core.projectPlan(text, counts ?? []);
  },

  // Plate i of a project: its profiles, settings, and parts. files:
  // { path: bytes } of the files that the plate needs.
  projectLoad({ text, counts, plate, files }) {
    const f = core.filesNew(files);
    try {
      const r = core.projectLoad(f, text, counts ?? [], plate);
      if (!r.error) {
        core.modelName = "";
        wantSlice();
      }
      return { ...r, profiles: undefined, info: core.modelInfo(), parts: core.w.x.zs_app_part_count(core.app), ...settingsState() };
    } finally {
      core.filesFree(f);
    }
  },

  // All plates of a project, each in its own app (zs_set_project_load).
  // files: { path: bytes } of all plates. The plates slice in the
  // background, the active plate (`active`) first. results: for each
  // plate, the reason it did not load, or the message that its parts do
  // not all fit.
  projectSet({ text, counts, files, active: want }) {
    commitPending();
    const f = core.filesNew(files);
    const w = wasm;
    const cap = 1024;
    const msg = w.alloc(cap);
    try {
      const c = (counts ?? []).map((n) => (n == null ? "-" : String(n))).join(",");
      const rc = w.withStrings([text, c], (t, cs) => w.x.zs_set_project_load(set, f, t, cs, want ?? 0, msg, cap));
      if (rc !== 0) throw new Error(w.cstr(msg) || statusText(rc));
    } finally {
      w.free(msg, cap);
      core.filesFree(f);
    }
    syncCore();
    const results = [];
    const n = w.x.zs_set_count(set);
    for (let i = 0; i < n; i++) {
      const p = plateInfo(i);
      const failed = p.status === "failed";
      results.push({ error: failed ? p.message || "The plate did not load." : "", fits: failed || !p.message, message: failed ? "" : p.message });
    }
    showActive();
    return { results, index: activeIndex(), info: core.modelInfo(), parts: core.w.x.zs_app_part_count(core.app), ...settingsState() };
  },

  // All plates as one project file: { bytes, name }.
  projectSave({ name }) {
    commitPending();
    const w = wasm;
    const rc = w.withString(name ?? "", (n) => w.x.zs_set_project_save(set, n, w.cell, w.cell + 4));
    if (rc !== 0) throw new Error(statusText(rc));
    const ptr = w.u32(w.cell);
    const len = w.u32(w.cell + 4);
    const bytes = w.u8.slice(ptr, ptr + len).buffer;
    w.x.zs_buffer_free(ptr, len);
    return { bytes };
  },

  // True if the bytes are a project file of zslice.
  projectFileIs({ bytes }) {
    return wasm.withBytes(new Uint8Array(bytes), (p, n) => wasm.x.zs_project_file_is(p, n)) === 1;
  },

  // Opens a project file: its plates replace the plates.
  // The session of the set (zs_session_write): the plates, their last
  // scenes, and the camera (8 floats, or null).
  sessionWrite({ camera }) {
    const w = wasm;
    const cam = camera ? w.alloc(32) : 0;
    try {
      if (cam) new Float32Array(w.x.memory.buffer, cam, 8).set(camera);
      const out = w.alloc(8);
      try {
        const rc = w.x.zs_session_write(set, cam, 0, out, out + 4);
        if (rc !== 0) throw new Error(statusText(rc));
        const p = w.u32(out);
        const n = w.u32(out + 4);
        const bytes = w.u8.slice(p, p + n).buffer;
        w.x.zs_buffer_free(p, n);
        return { bytes };
      } finally {
        w.free(out, 8);
      }
    } finally {
      if (cam) w.free(cam, 32);
    }
  },

  // Puts a session back: the plates, with their last scenes at once, and
  // the camera. The plates slice in the background.
  sessionRead({ bytes }) {
    commitPending();
    const w = wasm;
    const cap = 512;
    const msg = w.alloc(cap);
    const cam = w.alloc(32);
    const has = w.alloc(4);
    let camera = null;
    try {
      const rc = w.withBytes(new Uint8Array(bytes), (p, n) => w.x.zs_session_read(set, p, n, cam, has, 0, 0, msg, cap));
      if (rc !== 0) throw new Error(w.cstr(msg) || statusText(rc));
      if (w.u32(has)) camera = Array.from(new Float32Array(w.x.memory.buffer, cam, 8));
    } finally {
      w.free(msg, cap);
      w.free(cam, 32);
      w.free(has, 4);
    }
    syncCore();
    const n = w.x.zs_set_count(set);
    for (let i = 0; i < n; i++) w.x.zs_set_changed(set, i);
    showActive();
    wantSlice();
    return { camera, index: activeIndex(), info: core.modelInfo(), ...settingsState() };
  },

  projectFileOpen({ bytes }) {
    commitPending();
    const w = wasm;
    const cap = 512;
    const msg = w.alloc(cap);
    let note = "";
    try {
      const rc = w.withBytes(new Uint8Array(bytes), (p, n) => w.x.zs_set_project_open(set, p, n, msg, cap));
      note = w.cstr(msg);
      if (rc !== 0) throw new Error(note || statusText(rc));
    } finally {
      w.free(msg, cap);
    }
    syncCore();
    const n = w.x.zs_set_count(set);
    for (let i = 0; i < n; i++) w.x.zs_set_changed(set, i);
    showActive();
    wantSlice();
    return { note, index: activeIndex(), info: core.modelInfo(), ...settingsState() };
  },

  // ---- the files: G-code and 3MF ----

  // The plate as a 3MF file, for keep.js.
  plate3mf() {
    const bytes = core.plate3mf();
    return { bytes: bytes ? bytes.buffer : null, name: core.modelName };
  },

  // The G-code of plate `index` (each plate keeps the G-code of its last
  // slice), with its name, or { bytes: null }.
  plateGcode({ index }) {
    const w = wasm;
    const a = w.x.zs_set_app(set, index);
    if (!a || w.x.zs_app_gcode(a, w.cell, w.cell + 4) !== 0) return { bytes: null };
    const p = w.u32(w.cell);
    const n = w.u32(w.cell + 4);
    const info = plateInfo(index);
    // The name of the core, from the first part of the plate.
    let model = info?.name || "plate";
    const pp = w.alloc(80);
    try {
      if (w.x.zs_app_part_count(a) > 0 && w.x.zs_app_part_get(a, 0, pp) === 0) model = w.cstr(w.u32(pp)) || model;
    } finally {
      w.free(pp, 80);
    }
    const count = w.x.zs_set_count(set);
    const fileName = w.withString(model, (m) => w.readText((b, c, l) => w.x.zs_app_gcode_name(a, m, count > 1 ? index + 1 : 0, b, c, l)));
    return { bytes: w.u8.slice(p, p + n).buffer, name: info?.name ?? "", fileName };
  },

  // The start or the end G-code of the last slice, with the values of the
  // variables: the text before the first layer, or the lines before the
  // filament totals at the end.
  gcodeHead({ name }) {
    const bytes = core.gcode();
    if (!bytes) return "";
    const dec = new TextDecoder();
    if (/end_gcode$/.test(name)) {
      const tail = dec.decode(bytes.slice(Math.max(0, bytes.length - 16384)));
      const k = tail.lastIndexOf(";Filament used:");
      const lines = (k >= 0 ? tail.slice(0, k) : tail).split("\n");
      return lines.slice(-40).join("\n").trim();
    }
    const head = dec.decode(bytes.slice(0, Math.min(bytes.length, 65536)));
    const k = head.indexOf(";LAYER:0");
    return (k >= 0 ? head.slice(0, k) : head.slice(0, 4000)).replace(/; thumbnail begin[\s\S]*?; thumbnail end\n;?\n?/g, "; (thumbnails)\n").trim();
  },

  // A test print of the layers lo to hi - 1 (zs_app_debug_gcode).
  debugGcode({ lo, hi }) {
    const w = core.w;
    if (w.x.zs_app_debug_gcode(core.app, lo, hi, w.cell, w.cell + 4) !== 0) return { bytes: null };
    const ptr = w.u32(w.cell);
    const len = w.u32(w.cell + 4);
    const bytes = w.u8.slice(ptr, ptr + len).buffer;
    w.x.zs_buffer_free(ptr, len);
    return { bytes, name: core.modelName };
  },

  // plates: the count of plates, so a name has the plate of more than one.
  gcode({ plate, plates } = {}) {
    const bytes = core.gcode();
    const w = core.w;
    const fileName = w.withString(core.modelName || "part", (m) => w.readText((b, c, l) => w.x.zs_app_gcode_name(core.app, m, plates > 1 ? plate + 1 : 0, b, c, l)));
    return { bytes: bytes ? bytes.buffer : null, name: core.modelName, fileName: fileName || "part" };
  },
};

self.onmessage = async (e) => {
  const { id, op, ...args } = e.data;
  try {
    // The first op of a drag ends the step of the changes before it.
    if (args.hold && !histHolding) commitPending();
    const result = await ops[op](args);
    // The first step of a plate: its state at the start. The core notes
    // each change; a change starts or extends a step. During a drag, the
    // step waits for its end.
    if (op === "init" || op === "projectSet" || (core && core.historyCount() === 0)) historyCommit();
    else if (args.hold) histHolding = true;
    else if (op === "sliceHeld") {
      if (histHolding) historyCommit();
      histHolding = false;
    } else if ((op === "set" || op === "setScoped" || op === "partSettingSet") && args.name === histFocus) {
      // The edit of the setting with the focus goes on: its step ends
      // when the focus moves.
    } else if (SETTING_OPS.has(op) || PLATE_OPS.has(op)) {
      historyCommit();
      histHolding = false;
    }
    if (platesDirty) postPlates();
    const transfer = result?.bytes ? [result.bytes] : [];
    post({ id, result }, transfer);
  } catch (err) {
    post({ id, error: String(err?.message ?? err) });
  }
};
