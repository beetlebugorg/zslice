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
import { saveSession } from "./keep.js";

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
// The app preferences (engine.threads, engine.draft_slices: APP_PREFS in
// core.js) are the same for all plates. A plate that becomes active gets
// the values of the plate before it.
let engineValues = null;

function syncCore() {
  // The Cores of the apps that are not in the set now.
  const live = new Set();
  const n = wasm.x.zs_set_count(set);
  for (let i = 0; i < n; i++) live.add(wasm.x.zs_set_app(set, i));
  if (core && live.has(core.app)) engineValues = core.engineValues();
  core = coreAt(activeIndex());
  if (engineValues) {
    for (const [name, value] of Object.entries(engineValues)) {
      if (core.get(name) !== value) core.set(name, value);
    }
  }
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
    // A draft (zs_app_set_draft): the exact slice follows.
    draft: c.w.x.zs_app_is_draft(c.app) === 1,
    stats: c.stats(),
    filaments: c.filaments(),
    filamentStats: c.filamentStats(),
    featureStats: c.featureStats(),
    layers,
    scene,
    mode,
    marks: c.markCount(),
    areas: c.supportAreas(),
    // The note of support trees that the slice planned again.
    treeNote: c.supportTreeNote(),
    parts: c.w.x.zs_app_part_count(c.app),
    // Each part on the bed, with no part on another (zs_app_plate_fits).
    fits: c.w.x.zs_app_plate_fits(c.app) === 1,
    tiny: tinyParts(c),
    turn,
    // The simulated print of this slice, if it ran (a plate that became
    // active again).
    sim: ms > 0 ? null : c.simStats(),
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

// The draft slices (zs_app_set_draft). A change of a plate that has a
// slice gives a draft first: an outline tolerance of 0.05 mm and no gap
// fill, in about a third of the time. The exact slice follows SETTLE_MS
// after the last change, or at the end of a drag (sliceHeld). A plate
// with no slice yet (a new model) slices exact at once. A draft has no
// G-code: the page keeps the export and the numbers of the print until
// the exact slice.
const SETTLE_MS = 300;
let settleMs = SETTLE_MS; // a test can change it (settleMs)
let draftApp = 0; // the app whose next slices are drafts, or 0
let exactTimer = 0;

// The index of the plate of an app, or -1.
function plateOf(app) {
  const n = wasm.x.zs_set_count(set);
  for (let i = 0; i < n; i++) if (coreAt(i).app === app) return i;
  return -1;
}

// The exact slice of the plate that has a draft.
function settle() {
  clearTimeout(exactTimer);
  exactTimer = 0;
  if (!draftApp) return;
  const app = draftApp;
  draftApp = 0;
  const i = plateOf(app);
  if (i < 0) return;
  wasm.x.zs_app_set_draft(app, 0);
  wasm.x.zs_set_changed(set, i);
  schedule();
}

// A change of the active plate: its next slice is a draft, if the plate
// has a slice.
function liveChange() {
  clearTimeout(exactTimer);
  exactTimer = 0;
  const c = coreAt(activeIndex());
  if (draftApp && draftApp !== c.app) settle();
  // Draft slices off (the Speed settings): each change slices exact.
  if (!draftApp && c.state() === STATE.done && c.get("engine.draft_slices") === "true") {
    draftApp = c.app;
    wasm.x.zs_app_set_draft(c.app, 1);
  }
}

// The active plate waits for a slice.
function wantSlice() {
  liveChange();
  wasm.x.zs_set_changed(set, activeIndex());
  schedule();
}

// A change of a part while a drag or keys go on: the slice waits until
// sliceHeld (the end of the drag, or a pause of the keys).
function sliceOrHold(hold) {
  if (hold) wasm.x.zs_set_changed_held(set, activeIndex());
  else wantSlice();
}

// The view of the active plate after a change of the simulated print: a
// "sliced" event with no slice time, so the page keeps its state.
function postSimScene(c, on) {
  const scene = c.scene(mode);
  const layers = c.layers();
  post({ event: "sliced", plate: activeIndex(), ms: 0, draft: c.w.x.zs_app_is_draft(c.app) === 1, stats: c.stats(), featureStats: c.featureStats(), layers, scene, mode, marks: c.markCount(), areas: c.supportAreas(), parts: c.w.x.zs_app_part_count(c.app), fits: c.w.x.zs_app_plate_fits(c.app) === 1, tiny: [], simulated: on, sim: c.simStats() }, scene ? [scene] : []);
}

// The simulated print after each slice of the active plate
// (zs_app_sim_begin): it runs in pieces of about 8 ms between the
// messages, so it holds up no call. A change slices again, and the new
// slice drops it; the simulation of the new slice starts after it.
let simTimer = 0;
// The time of the last change of a live drag (a call with hold). While a
// drag goes on, a finished simulation waits: else the view flips between
// the plan and the plastic under the pointer. It shows after a pause of
// SIM_HOLD_MS, or with the slice after the release.
let lastHold = -1e9;
const SIM_HOLD_MS = 400;

// The progress of the simulation for the page, at most each 2 %.
let simProgress = 0;

function startSim(i) {
  clearTimeout(simTimer);
  if (wasm.x.zs_app_sim_begin(coreAt(i).app) !== 0) return;
  simProgress = 0;
  post({ event: "sim", progress: 0 });
  simTimer = setTimeout(() => simPiece(i), 0);
}

function simPiece(i) {
  // A slice waits: it goes first, and drops this simulation.
  if (i !== activeIndex() || wasm.x.zs_set_next(set) >= 0) return;
  const c = coreAt(i);
  const w = wasm;
  const t0 = performance.now();
  do {
    if (w.x.zs_app_sim_advance(c.app, 16, w.cell) !== 0) return;
    if (w.i32(w.cell) === 1) {
      post({ event: "sim", progress: 1 });
      showSimWhenStill(c, i);
      return;
    }
  } while (performance.now() - t0 < 8);
  const f = w.x.zs_app_sim_progress(c.app);
  if (f - simProgress >= 0.02) {
    simProgress = f;
    post({ event: "sim", progress: f });
  }
  simTimer = setTimeout(() => simPiece(i), 0);
}

function showSimWhenStill(c, i) {
  const wait = lastHold + SIM_HOLD_MS - performance.now();
  if (wait > 0) {
    simTimer = setTimeout(() => {
      // A new slice of the plate drops this simulation.
      if (i === activeIndex() && wasm.x.zs_set_next(set) < 0) showSimWhenStill(c, i);
    }, wait);
    return;
  }
  postSimScene(c, true);
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
    if (i === activeIndex()) post({ event: "slicing", plate: i, draft: draftApp === c.app });
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
  const draft = wasm.x.zs_app_is_draft(c.app) === 1;
  // The simulation is for the exact slice.
  if (i === activeIndex() && c.state() === STATE.done && !draft) startSim(i);
  if (wasm.x.zs_set_next(set) >= 0) schedule();
  // No change waits: the exact slice follows the draft after a pause.
  else if (draftApp) {
    clearTimeout(exactTimer);
    exactTimer = setTimeout(settle, settleMs);
  }
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
  if (p.status === "done") {
    sendResult(i, 0);
    // A plate switch stops the simulation of the plate before: it runs
    // again when that plate becomes active.
    if (!coreAt(i).simStats()) startSim(i);
  } else if (core.state() === STATE.empty) {
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
// The ops after which a part can lose what held it (see the fall check).
// An op with hold (a drag) checks at its end.
const FALL_CHECK_OPS = new Set(["partSettingSet", "supportAreaKind", "supportAreaRemove", "projectLoad", "plateActivate", "treeMoveNode", "treeMoveBranch", "treeDelete", "treeReset"]);
const SETTING_OPS = new Set(["refineApply", "importProfile", "set", "speed", "reset", "quality", "profile", "setScoped", "resetScoped", "rangePaste", "rangeReset"]);
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

const PLATE_OPS = new Set(["fallStep", "load", "add", "plate", "projectLoad", "partAction", "partsAction", "partsMove", "partsSettingSet", "partsToPlate", "partsPaste", "partsCut", "platePaste", "plateDuplicate", "partCut", "partMove", "partFill", "partToPlate", "editAdd", "editDot", "editRemove", "partSettingSet", "paintSet", "paintBody", "regionSet", "labelAdd", "labelUpdate", "labelRemove", "filamentAdd", "filamentRemove", "filamentSet", "filamentsFromPrinter", "partPutDown", "partTurn", "putDown", "place", "partMove", "partRotate", "partScale", "partSettle", "markAdd", "supportRemoveAt", "supportKindAt", "markRemoveNear", "markSet", "markRemove", "marksClear", "supportAreaAdd", "supportAreaSet", "supportAreaKind", "supportAreaRemove", "treeMoveNode", "treeRadius", "treeMoveBranch", "treeDelete", "treeAdd", "treeReset"]);

// The values of settings at z (core.valueAt): { name: entry }.
function valuesAt({ z, names }) {
  const out = {};
  for (const n of names) out[n] = core.valueAt(z, n);
  return out;
}

// The overhang over a point of a support line: up from the point, a half
// millimeter a step, to the first surface that faces down. Or null.
function overhangOver(pt) {
  const top = core.layers()?.z?.at(-1) ?? pt[2];
  let hot = null;
  for (let z = pt[2]; z <= top + 0.5 && !hot; z += 0.5) hot = core.supportPick(pt[0], pt[1], z, 2);
  return hot;
}

// An edit of the support trees of part `part` (support.js): fn(clampPtr)
// calls the core. count: the result is a count or a node (else a status).
function treeEdit(part, hold, fn, count = false) {
  const r = core.treeEdit(fn);
  const done = count ? r.rc >= 0 : r.rc === 0;
  if (done) sliceOrHold(hold);
  return { rc: count ? r.rc : -r.rc, clamp: r.clamp, tree: core.supportTrees(part) };
}

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
    // The saved texts of an older version have the accelerations of the
    // features in the project settings. They load into the printer now,
    // and the answer below saves both groups in their new form.
    const moved = saved?.project ? wasm.withString(saved.project, (t, len) => wasm.x.zs_profile_moved(2, t, len)) : 0;
    if (moved > 0) console.info(`zslice: the accelerations and the travel retraction are printer settings now; ${moved} saved values moved to the printer`);
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

  // The Faster slicing switch of the Speed settings (zs_app_speed_set).
  speed({ on }) {
    const error = core.setSpeed(on);
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

  // A profile of another slicer: its values become changes of the
  // settings now, and the answer has the report.
  importProfile({ name, bytes }) {
    const r = core.importProfile(name, new Uint8Array(bytes));
    if (!r.error) wantSlice();
    return { ...r, ...settingsState() };
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

  // at: { z, names } for the values of these settings at z after the
  // change too (the card of a layer range, rangecard.js).
  setScoped({ name, value, zmin, zmax, perLayer, at }) {
    const error = core.setScoped(name, value, zmin, zmax, perLayer);
    if (!error) wantSlice();
    return { error, ...settingsState(), at: at ? valuesAt(at) : undefined };
  },

  resetScoped({ name, zmin, zmax, z, at }) {
    const error = core.resetScoped(name, zmin, zmax, z);
    if (!error) wantSlice();
    return { error, ...settingsState(), at: at ? valuesAt(at) : undefined };
  },

  // The values of some settings at z: { at: { name: entry } }.
  valuesAt({ z, names }) {
    return { at: core?.app ? valuesAt({ z, names }) : {} };
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
    settle();
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
    const info = p >= 0 ? core.inspect(p, seg ?? -1) : null;
    // The warnings of the check at this line, for the line card.
    if (info) info.issues = core.issuesOfPath(p, info.layer);
    // The filament of the line (from 1), for the Filament row of the card.
    if (info) info.filament = core.w.x.zs_app_path_filament(core.app, p);
    return { info };
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
  // The fall of a part, step by step (zs_app_fall_*): started, or held
  // (it cannot stand, and support holds it).
  fallStart({ index }) {
    const x = core.w.x;
    const rc = x.zs_app_fall_start(core.app, index);
    const held = rc === 0 && x.zs_app_part_stands(core.app, index) === 0;
    return { started: rc === 1, held };
  },

  // The print as it forms (zs_app_simulate_print): on, the plastic of the
  // last slice is simulated, and the view gets a scene of it; off, the
  // view gets the slice again. Returns the numbers of the simulation.
  simulate({ on }) {
    let stats = null;
    if (on) {
      // The simulation after the slice, if it is done; else a new one.
      if (core.showSimulated(true)) stats = core.simStats();
      else {
        clearTimeout(simTimer);
        stats = core.simulatePrint();
        if (!stats) return { error: "Slice first: the simulation needs a slice." };
        core.showSimulated(true);
      }
    } else core.showSimulated(false);
    postSimScene(core, on);
    return { stats };
  },

  // The hand (zs_app_grab_*): take part `index` at the bed point (x, y, z),
  // move the hand, and let go. The frames are those of the fall.
  grabStart({ index, x, y, z }) {
    return { ok: core.w.x.zs_app_grab_start(core.app, index, x, y, z) === 1 };
  },

  grabMove({ x, y, z }) {
    core.w.x.zs_app_grab_move(core.app, x, y, z);
    return {};
  },

  grabTurn({ axis, degrees }) {
    core.w.x.zs_app_grab_turn(core.app, axis[0], axis[1], axis[2], degrees);
    return {};
  },

  grabEnd() {
    core.w.x.zs_app_grab_end(core.app);
    return {};
  },

  // One frame of the fall: the turn, the pivot, and the move for the view,
  // and done when the part rests (then a slice of its new place).
  fallStep({ dt }) {
    const w = wasm;
    const buf = w.alloc(80);
    try {
      const rc = w.x.zs_app_fall_step(core.app, dt, buf);
      if (rc < 0) return { none: true };
      const v = [];
      for (let i = 0; i < 10; i++) v.push(w.f64(buf + 8 * i));
      if (rc === 0) {
        platesDirty = true;
        wantSlice();
      }
      return { done: rc === 0, q: v.slice(0, 4), pivot: v.slice(4, 7), move: v.slice(7, 10) };
    } finally {
      w.free(buf, 80);
    }
  },

  partSettle({ index }) {
    const deg = core.w.x.zs_app_part_settle(core.app, index);
    // held: support keeps a part in place that would fall over.
    const held = deg === 0 && core.w.x.zs_app_part_stands(core.app, index) === 0;
    return { part: core.part(index), degrees: deg > 0 ? deg : 0, held };
  },

  // The end of a drag or of the keys of a part: the slice that waited.
  // A slice during a drag (the support follows a tree edit live): the held
  // change slices now, and the step of the history stays open until
  // sliceHeld.
  // For tests: the pause between a draft and its exact slice (ms).
  settleMs({ ms }) {
    settleMs = ms;
    return {};
  },

  sliceNow() {
    liveChange();
    wasm.x.zs_set_release(set);
    schedule();
    return {};
  },

  sliceHeld() {
    wasm.x.zs_set_release(set);
    // The end of a live turn: the full slice of the part.
    const live = coarse;
    if (coarse) {
      wasm.x.zs_app_set_coarse_part(coarse.app, -1);
      coarse = null;
    }
    // The end of a drag: the exact slice, with no draft before it.
    if (draftApp) settle();
    else if (live) {
      wasm.x.zs_set_changed(set, activeIndex());
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

  // The place of part `index` in the print order, and if the plate prints
  // one part at a time (project.print_sequence = by_object).
  partOrder({ index }) {
    return { index, count: core.w.x.zs_app_part_count(core.app), sequential: core.get("project.print_sequence") === "by_object" };
  },

  partAction({ index, action }) {
    const r = core.partAction(index, action);
    // A split of one body changes nothing.
    if (action === "split" && r === 0) return { ok: false, part: core.part(index), message: "The part has one body: nothing to split." };
    if (r >= 0 && !clearIfEmpty()) wantSlice();
    const n = core.w.x.zs_app_part_count(core.app);
    const at = (action === "duplicate" || action === "earlier" || action === "later") && r >= 0 ? r : index;
    return { ok: r >= 0, count: action === "split" ? r : 0, part: action === "remove" || at >= n ? null : core.part(at) };
  },

  // An action on several parts in one step of the history (the card of a
  // selection of parts): "remove", "duplicate", "arrange" (the plate),
  // and the actions of partAction for each part. Returns { ok, parts }:
  // the selection after it (the copies, for "duplicate").
  partsAction({ indices, action }) {
    const x = core.w.x;
    const list = [...new Set(indices)].filter((i) => i >= 0 && i < x.zs_app_part_count(core.app));
    let ok = false;
    let keep = list;
    if (action === "arrange") {
      ok = x.zs_app_plate_arrange(core.app) !== 0;
    } else if (action === "remove") {
      // The highest index first: a remove moves the parts after it.
      for (const i of [...list].sort((a, b) => b - a)) if (core.partAction(i, "remove") >= 0) ok = true;
      keep = [];
    } else if (action === "duplicate") {
      keep = [];
      for (const i of list) {
        const r = core.partAction(i, "duplicate");
        if (r >= 0) {
          ok = true;
          keep.push(r);
        }
      }
    } else {
      for (const i of list) if (core.partAction(i, action) >= 0) ok = true;
    }
    if (ok && !clearIfEmpty()) wantSlice();
    const n = x.zs_app_part_count(core.app);
    return { ok, parts: keep.filter((i) => i < n).map((i) => core.part(i)) };
  },

  // ---- the clipboard of parts (clipboard.js, zs_app_parts_copy) ----

  // Copies parts `indices` of the active plate to the clipboard of the
  // core; whole: the whole plate. Returns { ok, count }.
  partsCopy({ indices, whole }) {
    const x = core.w.x;
    const n = x.zs_app_part_count(core.app);
    const list = [...new Set(indices ?? [])].filter((i) => i >= 0 && i < n);
    if (!whole && list.length === 0) return { ok: false, count: 0 };
    const p = core.w.alloc(4 * Math.max(1, list.length));
    try {
      new Uint32Array(core.w.x.memory.buffer, p, list.length).set(list);
      const rc = x.zs_app_parts_copy(core.app, p, list.length, whole ? 1 : 0);
      return { ok: rc === 0, count: x.zs_clipboard_parts() };
    } finally {
      core.w.free(p, 4 * Math.max(1, list.length));
    }
  },

  // Cut: a copy, then the parts go, in one step. Returns { ok, count }.
  partsCut({ indices }) {
    const r = this.partsCopy({ indices });
    if (!r.ok) return r;
    for (const i of [...new Set(indices)].sort((a, b) => b - a)) core.partAction(i, "remove");
    if (!clearIfEmpty()) wantSlice();
    return r;
  },

  // Pastes the clipboard on the active plate: at [x, y] mm on the bed
  // (the center of the group), or null (free places; on an empty plate,
  // the places of the copy). Returns { ok, parts } (the new parts).
  partsPaste({ at }) {
    const x = core.w.x;
    if (x.zs_clipboard_parts() === 0) return { ok: false, empty: true, parts: [] };
    const point = Array.isArray(at) && at.every(Number.isFinite);
    const first = Number(x.zs_app_parts_paste(core.app, point ? 1 : 0, point ? at[0] : 0, point ? at[1] : 0));
    if (first < 0) return { ok: false, parts: [] };
    const n = x.zs_app_part_count(core.app);
    const parts = [];
    for (let i = first; i < n; i++) parts.push(core.part(i));
    core.modelName = core.modelName || parts[0]?.name || "";
    wantSlice();
    postPlates();
    return { ok: true, parts, fits: x.zs_app_plate_fits(core.app) === 1, info: core.modelInfo() };
  },

  // A new plate after the others (the settings of the active plate) with
  // the clipboard on it at the places of the copy. It becomes the active
  // plate. Returns { ok, index, parts }.
  platePaste() {
    commitPending();
    if (wasm.x.zs_clipboard_parts() === 0) return { ok: false, empty: true };
    wasm.x.zs_set_add(set);
    syncCore();
    const r = this.partsPaste({ at: null });
    historyCommit();
    showActive();
    return { ...r, index: activeIndex(), count: wasm.x.zs_set_count(set), ...settingsState() };
  },

  // A new plate after the others with a copy of the active plate (its
  // settings, parts, support, and layer changes), with no change of the
  // clipboard. It becomes the active plate.
  plateDuplicate() {
    commitPending();
    const from = core.app;
    if (core.w.x.zs_app_part_count(from) === 0) return { ok: false };
    wasm.x.zs_set_add(set);
    syncCore();
    const first = Number(wasm.x.zs_app_plate_copy_to(from, core.app));
    if (first < 0) return { ok: false };
    core.modelName = core.part(0)?.name ?? "";
    wantSlice();
    historyCommit();
    showActive();
    return { ok: true, index: activeIndex(), count: wasm.x.zs_set_count(set), ...settingsState() };
  },

  // A calibration print on a new plate (src/app/calibrate.zig): kind 0
  // temperature, 1 retraction, 2 flow, 3 pressure advance. The new plate
  // has the settings of the active plate, and becomes the active plate.
  calibrate({ kind }) {
    commitPending();
    const from = activeIndex();
    wasm.x.zs_set_add(set);
    syncCore();
    const error = core.calibrationAdd(kind);
    if (error) {
      settle();
      wasm.x.zs_set_remove(set, activeIndex());
      wasm.x.zs_set_select(set, from);
      syncCore();
      showActive();
      return { ok: false, error };
    }
    const cal = core.calibration();
    core.modelName = cal?.name ?? "";
    if (cal?.name) wasm.withString(cal.name, (n) => wasm.x.zs_set_name(set, activeIndex(), n));
    wantSlice();
    historyCommit();
    showActive();
    return { ok: true, calibration: cal, index: activeIndex(), count: wasm.x.zs_set_count(set), ...settingsState() };
  },

  // The calibration of the active plate, or null.
  calibration() {
    return { calibration: core.calibration() };
  },

  // "Use this value" of a calibration: the setting gets the value on each
  // plate, so the filament of each plate has it.
  calibrationUse({ setting, value }) {
    commitPending();
    const n = wasm.x.zs_set_count(set);
    let error = "";
    for (let i = 0; i < n; i++) {
      const c = coreAt(i);
      const e = c.set(setting, value);
      if (e) error = e;
      else wasm.x.zs_set_changed(set, i);
    }
    historyCommit();
    wantSlice();
    return { error, ...settingsState() };
  },

  // The clipboard: { parts, plate } (the count of parts, and 1 for a
  // copy of a whole plate).
  clipboardInfo() {
    return { parts: wasm.x.zs_clipboard_parts(), plate: wasm.x.zs_clipboard_is_plate() === 1 };
  },

  // The changes for a range of layers (the overrides that cover the
  // range zmin to zmax): [[name, value]].
  rangeChanges({ zmin, zmax }) {
    return { list: core?.app ? core.rangeChanges(zmin, zmax) : [] };
  },

  // Sets several changes for a range of layers in one step of the
  // history: list [[name, value]].
  rangePaste({ list, zmin, zmax, at }) {
    let error = "";
    let ok = 0;
    for (const [name, value] of list ?? []) {
      const e = core.setScoped(name, value, zmin, zmax, true);
      if (e) error = e;
      else ok++;
    }
    if (ok > 0) wantSlice();
    return { error, ok, ...settingsState(), at: at ? valuesAt(at) : undefined };
  },

  // Removes the changes of settings `names` for a range of layers in one
  // step of the history (a cut of the range card).
  rangeReset({ names, zmin, zmax, at }) {
    let ok = 0;
    const w = core.w;
    for (const name of names ?? []) {
      // Only the changes of the layers: the value of the print stays.
      if (w.withString(name, (n) => w.x.zs_app_override_remove(core.app, zmin, zmax, n)) === 1 || w.withString(name, (n) => w.x.zs_app_override_clear_at(core.app, zmin, n)) > 0) ok++;
    }
    if (ok > 0) wantSlice();
    return { ok, ...settingsState(), at: at ? valuesAt(at) : undefined };
  },

  // Moves several parts at once (a drag of a selection): moves is
  // [{ index, x, y }]. hold: as in partMove.
  partsMove({ moves, hold }) {
    let ok = false;
    for (const m of moves) {
      if (!Number.isFinite(m.x) || !Number.isFinite(m.y)) continue;
      if (core.w.x.zs_app_part_move(core.app, m.index, m.x, m.y) === 0) ok = true;
    }
    if (ok) sliceOrHold(hold);
    return { parts: moves.map((m) => core.part(m.index)) };
  },

  // A setting for each of several parts (null: the value of the plate).
  partsSettingSet({ indices, name, value }) {
    let error = "";
    for (const i of indices) {
      const e = core.setPartSetting(i, name, value);
      if (e) error = e;
    }
    if (!error) wantSlice();
    return { error, value: indices.length > 0 ? core.partSetting(indices[0], name) : null };
  },

  // Moves several parts to one new plate. Returns { ok, to }.
  partsToPlate({ indices }) {
    commitPending();
    let to = -1;
    for (const i of [...new Set(indices)].sort((a, b) => b - a)) {
      const r = wasm.x.zs_set_part_move(set, activeIndex(), i, to);
      if (r < 0) break;
      to = r;
    }
    if (to < 0) return { ok: false };
    syncCore();
    postPlates();
    if (clearIfEmpty()) schedule();
    else wantSlice();
    return { ok: true, to };
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

  // ---- the paint of a part (paint.js) ----

  // The mesh of part `index` at its place, and its paint as text.
  paintOpen({ index }) {
    const m = core.partMesh(index);
    if (!m) return { error: "No part." };
    return { verts: m.verts, faces: m.faces, text: core.partPaint(index) };
  },

  // The paint of part `index` from the paint tool: slices again.
  paintSet({ index, text }) {
    if (!core.setPartPaint(index, text)) return { error: "No part." };
    wantSlice();
    return {};
  },

  // The filament of a body of some layers (rangecard.js): the beads of
  // the body from the view, and the filament (from 1). Slices again.
  paintBody({ beads, filament }) {
    const n = core.paintBody(beads, filament);
    if (n > 0) wantSlice();
    return { changed: n };
  },

  // A setting of the region of a lit body of some layers (rangecard.js):
  // the beads of the body, the id of its region (`region`, 0: find or
  // make it; "id" is the id of the call), and the setting. Slices again.
  // Returns { id, values } or { error }.
  regionSet({ beads, region, name, value }) {
    const r = core.regionSet(beads, region ?? 0, name, value ?? null);
    if (r.error) return r;
    wantSlice();
    return { id: r.id, values: r.id ? core.regionSettings(r.id) : {} };
  },

  // The region of a lit body: { id, values } (id 0: none yet).
  regionOf({ beads }) {
    const id = beads ? core.regionFind(beads) : 0;
    return { id, values: id ? core.regionSettings(id) : {} };
  },

  // ---- the labels of a part (label.js) ----

  // The labels of part `index`, and the filament of the part (from 1).
  labelsGet({ index }) {
    const p = core.part(index);
    if (!p) return { labels: [], filament: 1 };
    const own = core.partSettings(index).find(([n]) => n === "project.filament");
    // The place, turn, size, and scale of the part: the pick mesh of the
    // Label tool stays while they stay (label.js load).
    const pose = [p.x, p.y, p.rotation, p.sizeX, p.sizeY, p.sizeZ, ...p.scale].map((v) => v.toFixed(4)).join(",");
    return { labels: core.partLabels(index), filament: Number(own ? own[1] : core.get("project.filament")) || 1, pose };
  },

  // A new label on part `index`: its id (-1: the core did not take it).
  labelAdd({ index, label }) {
    const id = core.labelAdd(index, label);
    if (id >= 0) wantSlice();
    return { id, labels: core.partLabels(index) };
  },

  // labelId: a message has its own `id`.
  labelUpdate({ index, labelId, label }) {
    const ok = core.labelUpdate(index, labelId, label);
    if (ok) wantSlice();
    return { ok };
  },

  labelRemove({ index, labelId }) {
    const ok = core.labelRemove(index, labelId);
    if (ok) wantSlice();
    return { ok, labels: core.partLabels(index) };
  },

  // The facts of a label for its card (zs_app_label_info).
  labelInfo({ index, labelId }) {
    return { info: core.labelInfo(index, labelId) };
  },

  // ---- the filaments of the plate ----

  filaments() {
    return { list: core.filaments(), stats: core.filamentStats() };
  },

  filamentAdd() {
    const index = core.filamentAdd();
    if (index >= 0) wantSlice();
    return { index, list: core.filaments() };
  },

  filamentRemove({ index }) {
    if (core.filamentRemove(index)) wantSlice();
    return { list: core.filaments() };
  },

  // A value of filament `index` ("filament.color"). Filament 0 is the
  // filament of the settings: the settings change too.
  filamentSet({ index, name, value }) {
    const error = core.filamentSet(index, name, value);
    if (!error) wantSlice();
    return { error, list: core.filaments(), ...(index === 0 ? settingsState() : {}) };
  },

  // The spools of a printer for the filaments of the plate (flags 1: the
  // filaments set by hand follow too). Slices again on a change.
  filamentsFromPrinter({ name, json, flags }) {
    const r = core.filamentsFromPrinter(name, json, flags);
    if (r.changed) wantSlice();
    return { ...r, list: core.filaments(), ...(r.changed ? settingsState() : {}) };
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

  // "Remove this support": the support line at the segment holds up an
  // overhang; a block area over that overhang takes the support away.
  // The support marks of the user near the line go too.
  // The feature of line `path` (0 outer wall … 6 support, 7 support
  // interface; see gaps.js), or -1.
  // The run of a path: the first and the last path of its extrusion, from
  // one retraction to the next (zs_app_path_run), or null.
  pathRun({ path }) {
    const w = core.w;
    const c = w.cell;
    if (w.x.zs_app_path_run(core.app, path, c, c + 4) !== 0) return { run: null };
    return { run: [w.u32(c), w.u32(c + 4)] };
  },

  lineFeature({ path }) {
    const info = core.inspect(path);
    return { feature: info ? info.feature : -1 };
  },

  supportRemoveAt({ path, seg }) {
    const pt = core.pathPoint(path, seg);
    const info = core.inspect(path);
    if (!pt || !info) return { error: "No line there." };
    if (info.feature !== 6 && info.feature !== 7) return { error: "That line is not support." };
    let changed = core.w.x.zs_app_mark_remove_near(core.app, pt[0], pt[1], pt[2], 3) > 0;
    const hot = overhangOver(pt);
    if (hot && hot.pts.length >= 3) {
      if (core.supportAreaAdd(3, hot.pts, hot.zLo, hot.zHi) >= 0) changed = true;
    }
    if (!changed) return { error: "zslice found no overhang over this support." };
    wantSlice();
    return { areas: core.supportAreas() };
  },

  // Another kind of support for the overhang over a support line: an area
  // of that kind (0 grid, 1 tree, 2 bridge pad) over the overhang, as
  // the Support tool makes. The marks of the user near the line go.
  supportKindAt({ path, seg, kind }) {
    const pt = core.pathPoint(path, seg);
    const info = core.inspect(path);
    if (!pt || !info) return { error: "No line there." };
    if (info.feature !== 6 && info.feature !== 7) return { error: "That line is not support." };
    const hot = overhangOver(pt);
    if (!hot || hot.pts.length < 3) return { error: "zslice found no overhang over this support." };
    core.w.x.zs_app_mark_remove_near(core.app, pt[0], pt[1], pt[2], 3);
    if (core.supportAreaAdd(kind, hot.pts, hot.zLo, hot.zHi) < 0) return { error: "The support did not change." };
    wantSlice();
    return { areas: core.supportAreas() };
  },

  // The support of a support line (a click of the Select tool): the
  // point of the line, the overhang over it (the area that "Remove this
  // support" blocks), and tree: true for tree support. Or { error }.
  supportAt({ path, seg }) {
    const pt = core.pathPoint(path, seg);
    const info = core.inspect(path);
    if (!pt || !info) return { error: "No line there." };
    if (info.feature !== 6 && info.feature !== 7) return { error: "That line is not support." };
    return { pt, tree: core.get("project.support_style") === "tree", hot: overhangOver(pt) };
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

  // ---- the support trees (support.js) ----
  //
  // Each edit returns { rc, clamp, tree }: rc 0 (or a count, or the tip
  // of a new branch) when it is done, else -status; clamp: the rules that
  // limited it (enum zs_tree_clamp); tree: the trees of the part again.
  // hold: a drag goes on, so the slice waits for its end.

  supportTrees() {
    if (!core?.app) return { parts: [], note: "" };
    const t = core.supportTreesAll();
    return { ...t, transfer: t.parts.map((p) => p.nodes.buffer) };
  },

  treeMoveNode({ part, node, x, y, hold }) {
    return treeEdit(part, hold, (c) => core.w.x.zs_app_support_tree_move_node(core.app, part, node, x, y, c));
  },

  treeRadius({ part, node, r, hold }) {
    return treeEdit(part, hold, (c) => core.w.x.zs_app_support_tree_set_radius(core.app, part, node, r, c));
  },

  treeMoveBranch({ part, node, dx, dy, hold }) {
    return treeEdit(part, hold, (c) => core.w.x.zs_app_support_tree_move_branch(core.app, part, node, dx, dy, c));
  },

  treeDelete({ part, node }) {
    return treeEdit(part, false, () => core.w.x.zs_app_support_tree_delete_branch(core.app, part, node), true);
  },

  // part -1: the part under the tip.
  treeAdd({ part, fx, fy, tx, ty, tz }) {
    const i = part >= 0 ? part : Number(core.w.x.zs_app_part_at(core.app, tx, ty));
    if (i < 0) return { rc: -2, clamp: 0, tree: null };
    return treeEdit(i, false, (c) => core.w.x.zs_app_support_tree_add_branch(core.app, i, fx, fy, tx, ty, tz, c), true);
  },

  treeReset({ part }) {
    const done = core.w.x.zs_app_support_tree_reset(core.app, part) === 1;
    if (done) wantSlice();
    return { rc: done ? 0 : -1, clamp: 0, tree: core.supportTrees(part) };
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

  // Writes the session (sessionWrite) and keeps it in IndexedDB (keep.js),
  // with the tag and the map of the page. The put copies the bytes on the
  // thread that calls it: in a profile of nine Benchies on the page,
  // the put held the main thread for 0.5 s after each slice.
  async sessionKeep({ camera, tag, map }) {
    const { bytes } = ops.sessionWrite({ camera });
    await saveSession(bytes, tag, map);
    return {};
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
  // The .gcode.3mf file of a Bambu Lab printer (zs_app_bambu_file): the
  // G-code and the filaments it uses. Only a file; nothing is sent.
  bambuFile({ title }) {
    const w = core.w;
    const c = w.cell;
    const rc = w.withString(title || "zslice", (t) => w.x.zs_app_bambu_file(core.app, t, c, c + 4));
    if (rc !== 0) return { bytes: null };
    const p = w.u32(c);
    const n = w.u32(c + 4);
    // A copy in a plain ArrayBuffer: the memory of the threaded build is a
    // SharedArrayBuffer, whose slice is shared too, and a shared buffer
    // cannot go in the transfer list of the reply.
    const bytes = new Uint8Array(w.x.memory.buffer, p, n).slice().buffer;
    w.x.zs_buffer_free(p, n);
    return { bytes };
  },

  // The .gcode.3mf file around G-code that the page signed
  // (zs_app_bambu_file_gcode): a send to a Bambu Lab printer.
  bambuFileGcode({ gcode, title }) {
    const w = core.w;
    const c = w.cell;
    const g = new Uint8Array(gcode);
    const rc = w.withBytes(g, (gp, gn) => w.withString(title || "zslice", (t) => w.x.zs_app_bambu_file_gcode(core.app, gp, gn, t, c, c + 4)));
    if (rc !== 0) return { bytes: null };
    const p = w.u32(c);
    const n = w.u32(c + 4);
    // A copy in a plain ArrayBuffer: the memory of the threaded build is a
    // SharedArrayBuffer, whose slice is shared too, and a shared buffer
    // cannot go in the transfer list of the reply.
    const bytes = new Uint8Array(w.x.memory.buffer, p, n).slice().buffer;
    w.x.zs_buffer_free(p, n);
    return { bytes };
  },

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
    if (args.hold) lastHold = performance.now();
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
    // A change that takes away what held a part (support turned off): the
    // page starts its fall. The turns run their own fall at the end.
    if ((SETTING_OPS.has(op) || FALL_CHECK_OPS.has(op)) && op !== "refineApply" && !args.hold && core?.app) {
      const k = Number(core.w.x.zs_app_fall_pending(core.app));
      if (k >= 0) post({ event: "fall", index: k });
    }
    if (platesDirty) postPlates();
    let transfer = result?.bytes ? [result.bytes] : [];
    if (result?.transfer) {
      transfer = result.transfer;
      delete result.transfer;
    }
    post({ id, result }, transfer);
  } catch (err) {
    post({ id, error: String(err?.message ?? err) });
  }
};
