// worker.js: the Web Worker that owns the app core (core.js). A slice runs
// here, on the thread of the worker, so the page stays responsive.
//
// Messages from the page: { id, op, ...args }. The worker answers each
// with { id, result } or { id, error }. A change of a setting or the model
// asks for a slice; the worker slices when no other message waits, so a
// fast series of changes gives one slice. Events to the page: { event:
// "progress", progress }, { event: "sliced", ... }, { event: "failed" }.
//
// The plate set. The worker keeps one Core (one app) for each plate, and
// the active plate. The ops of the page work on the active plate. After a
// change, the active plate slices first; then each other plate that is not
// up to date slices, one at a time. A plate keeps its old slice until its
// new one is done. Events of the set: { event: "plates" } (the list, the
// active plate, and the status of each), { event: "plateScene", plate,
// scene } (the beads of another plate), and { event: "stale", scene } (the
// old slice of a new active plate that slices again).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { Wasm } from "./wasm.js";
import { Core, STATE } from "./core.js";

// The plates: { id, core, name, status, wanted }. The core of each plate
// keeps its own undo list. status: "empty",
// "stale" (an old slice, or none yet), "slicing", "done", "failed", or
// "resin" (a plate that zslice cannot slice). wanted: it waits for a
// slice.
let plates = [];
let active = 0;
let core = null; // the Core of the active plate
let wasm = null;
let mode = 0; // the color mode of the scene (enum zs_view_mode)
let sliceTimer = 0;
let lastProgress = 0;
let slicing = -1; // the plate that slices now
let warming = false; // a warm-up slice runs: its events do not go to the page

function post(msg, transfer = []) {
  self.postMessage(msg, transfer);
}

function onEvent(event, progress) {
  if (warming) return;
  // ZS_EVENT_PROGRESS: at most each 2 %, so the page gets few messages.
  if (event === 1 && (progress - lastProgress >= 0.02 || progress < lastProgress)) {
    lastProgress = progress;
    post({ event: "progress", progress, plate: slicing });
  }
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

// The result of a slice of plate i for the page.
function sendResult(i, ms) {
  const p = plates[i];
  const c = p.core;
  const state = c.state();
  // A canceled slice: the change that canceled it waits, and its slice
  // comes next.
  if (state === STATE.ready && ms > 0) {
    p.wanted = true;
    p.status = "stale";
    if (i === active) post({ event: "canceled" });
    return;
  }
  if (state !== STATE.done) {
    p.status = state === STATE.empty ? "empty" : "failed";
    if (i === active) post({ event: "failed", state });
    return;
  }
  p.status = "done";
  if (i !== active) {
    const scene = c.scene(mode);
    if (scene) post({ event: "plateScene", plate: i, scene }, [scene]);
    // A plate that waits keeps its result, and not the memory for a
    // faster next slice.
    c.trim();
    return;
  }
  const scene = c.scene(mode);
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
    parts: c.w.x.zs_app_part_count(c.app),
  };
  post(msg, scene ? [scene, layers.z.buffer, layers.height.buffer, layers.endTime.buffer, layers.slowed.buffer] : []);
}

// The active plate waits for a slice.
function wantSlice() {
  markStale(active);
}

// A change of a part while a drag or keys go on: the slice waits until
// sliceHeld (the end of the drag, or a pause of the keys).
let held = false;
function sliceOrHold(hold) {
  if (hold) held = true;
  else {
    held = false;
    wantSlice();
  }
}

// Plate i waits for a slice. Its old slice stays until the new one.
function markStale(i) {
  const p = plates[i];
  if (!p || p.status === "resin") return;
  p.wanted = true;
  if (p.status !== "slicing") p.status = "stale";
  schedule();
}

function schedule() {
  clearTimeout(sliceTimer);
  // A timer, so that the messages that wait now come first.
  sliceTimer = setTimeout(runSlice, 0);
}

// Slices one plate: the active plate first, then the other plates in
// order. Then the next, after the messages that wait.
function runSlice() {
  const i = plates[active]?.wanted ? active : plates.findIndex((p) => p.wanted);
  if (i < 0) return;
  const p = plates[i];
  p.wanted = false;
  if (p.core.state() === STATE.empty) {
    p.status = "empty";
    postPlates();
    schedule();
    return;
  }
  p.status = "slicing";
  postPlates();
  post({ event: "slicing", plate: i });
  // The page stops this slice with the cancel flag of its app.
  if (wasm.shared) post({ event: "cancel-flag", memory: wasm.x.memory, address: wasm.x.zs_app_cancel_address(p.core.app) });
  lastProgress = 0;
  slicing = i;
  const t0 = performance.now();
  const r = p.core.slice();
  const ms = performance.now() - t0;
  slicing = -1;
  if (r.error) {
    p.status = "failed";
    if (i === active) post({ event: "failed", state: p.core.state(), error: r.error });
  } else sendResult(i, ms);
  postPlates();
  if (plates.some((q) => q.wanted)) schedule();
}

// ---- the plate set ----

// Each plate has an id, new for each plate: the page clears the old scene
// of a place in the view when another plate comes there (a new project).
let plateIds = 0;
function newPlate(c, name = "") {
  return { id: ++plateIds, core: c, name, status: c.state() === STATE.empty ? "empty" : "stale", wanted: false };
}

// The list of the plates for the page: the name, the status, the bed size,
// and the printer of each, and the active plate.
function postPlates() {
  const num = (c, k) => Number(c.get(k)) || 0;
  post({
    event: "plates",
    active,
    plates: plates.map((p) => ({
      id: p.id,
      name: p.name || p.core.modelName,
      status: p.status,
      bed: [num(p.core, "machine.bed_size_x"), num(p.core, "machine.bed_size_y")],
      model: p.core.get("machine.model"),
      printer: p.core.get("machine.name"),
      // A plate that cannot slice: the footprints of its parts.
      outline: p.status === "resin" || p.status === "failed" ? footprints(p.core) : null,
    })),
  });
}

// The box (x0, y0, x1, y1) of each part of an app on its bed.
function footprints(c) {
  const out = [];
  const n = c.w.x.zs_app_part_count(c.app);
  for (let i = 0; i < n; i++) {
    const q = c.part(i);
    if (q) out.push([q.x - q.sizeX / 2, q.y - q.sizeY / 2, q.x + q.sizeX / 2, q.y + q.sizeY / 2]);
  }
  return out;
}

// Makes plate i the active plate. The page gets the list, then the slice
// of the new active plate (or its old slice while it slices again), then
// the beads of the plate that was active.
function activate(i) {
  if (i < 0 || i >= plates.length) return false;
  const before = active;
  if (i !== before) {
    // The changes so far are a step of the plate that was active.
    if (histTimer) historyCommit();
    plates[before].core.trim();
  }
  active = i;
  core = plates[i].core;
  showActive(before);
  return true;
}

// Sends the list, and the slice of the active plate (or its old slice
// while it slices again), then the beads of plate `before` (the plate that
// was active, or -1).
function showActive(before) {
  const i = active;
  postPlates();
  const p = plates[i];
  if (p.status === "done") sendResult(i, 0);
  else if (core.state() === STATE.empty) {
    const scene = core.scene(mode);
    post({ event: "cleared", scene, plate: i }, scene ? [scene] : []);
  } else {
    // Its last slice, or an empty scene (no slice yet).
    const scene = core.lastScene() ?? core.scene(mode);
    post({ event: "stale", scene, plate: i }, scene ? [scene] : []);
    // A plate that cannot slice (a resin plate) waits for no slice.
    if (p.status !== "resin") {
      p.wanted = true;
      schedule();
    }
  }
  if (i !== before && before >= 0 && before < plates.length) {
    const scene = plates[before].core.lastScene();
    if (scene) post({ event: "plateScene", plate: before, scene }, [scene]);
  }
}

// Drops all plates but the active plate: a set of one plate.
function onePlate() {
  for (let i = 0; i < plates.length; i++) if (i !== active) plates[i].core.free();
  plates = [plates[active]];
  active = 0;
}

// The settings, the quality, and the saved state, after a change.
function settingsState() {
  return { ...core.snapshot(), saved: core.savedState() };
}

// ---- undo and the history (src/app/history.zig) ----
//
// The core of each plate keeps its undo list, and notes each change. The
// worker keeps the timer: a step ends 400 ms after the last change.

let histTimer = 0;

// Ends the step of the changes so far.
function historyCommit() {
  clearTimeout(histTimer);
  histTimer = 0;
  if (core && core.historyCommit(Date.now())) post({ event: "history" });
}

function historySchedule() {
  clearTimeout(histTimer);
  histTimer = setTimeout(historyCommit, 400);
}

// After an undo, a redo, or a jump (the bits of enum zs_history_restored):
// the name of the plate, the scene of an empty plate, and a new slice.
function historyRestored(bits) {
  clearTimeout(histTimer);
  histTimer = 0;
  if (!(bits & 1)) return;
  const parts = core.w.x.zs_app_part_count(core.app);
  if (bits & 2) {
    if (parts > 0) core.modelName = "plate.3mf";
    else {
      core.modelName = "";
      const scene = core.scene(mode);
      post({ event: "cleared", scene, plate: active }, scene ? [scene] : []);
    }
  }
  if (parts > 0) wantSlice();
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
const SETTING_OPS = new Set(["set", "reset", "quality", "profile", "setScoped", "resetScoped"]);
const PLATE_OPS = new Set(["load", "add", "plate", "projectLoad", "partAction", "partSettingSet", "partPutDown", "partTurn", "putDown", "place", "partMove", "partRotate", "markAdd", "markRemoveNear", "markSet", "markRemove", "marksClear"]);

const ops = {
  async init({ module, saved, mode: m }) {
    mode = m ?? 0;
    wasm = await Wasm.create(module, onEvent);
    // The threads of a slice: this worker is one, and one CPU stays free
    // for the page, as in the GTK app.
    const threads = wasm.startThreads(Math.max((navigator.hardwareConcurrency ?? 1) - 2, 0), (data) => {
      new Worker(new URL("./thread.js", import.meta.url), { type: "module" }).postMessage(data);
    });
    core = new Core(wasm);
    core.threads = threads + 1;
    plates = [newPlate(core)];
    active = 0;
    // With a shared memory (the module with threads), the page can stop a
    // slice that runs: it sets the cancel flag of the app (client.js).
    if (wasm.shared) post({ event: "cancel-flag", memory: wasm.x.memory, address: wasm.x.zs_app_cancel_address(core.app) });
    const errors = core.restore(saved);
    // After the threads start, and only if the plate is still empty then.
    setTimeout(warmUp, 300);
    postPlates();
    return { errors, ...settingsState() };
  },

  // A file opens on the active plate: a set of one plate.
  // keepSet: the file goes on the active plate, and the other plates stay
  // (plates that the user made); else the set becomes this one plate.
  load({ name, bytes, keepSet }) {
    if (plates.length > 1 && !keepSet) onePlate();
    core.loadStl(name, new Uint8Array(bytes));
    plates[active].name = name;
    wantSlice();
    postPlates();
    return { info: core.modelInfo() };
  },

  // ---- the plate set ----

  // A new empty plate after the others, with the settings of the active
  // plate. It becomes the active plate.
  plateAdd() {
    const c = new Core(wasm, core.infos);
    c.threads = core.threads;
    const st = core.savedState();
    c.restore(st);
    plates.push(newPlate(c, `Plate ${plates.length + 1}`));
    activate(plates.length - 1);
    return { index: active, count: plates.length, ...settingsState() };
  },

  // Plate i becomes the active plate.
  plateActivate({ index }) {
    const ok = activate(index);
    return { ok, index: active, info: core.modelInfo(), parts: core.w.x.zs_app_part_count(core.app), ...settingsState() };
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

  // A new color mode: the scenes again, with no new slice.
  mode({ value }) {
    mode = value;
    plates.forEach((p, i) => {
      if (p.status === "done") sendResult(i, 0);
    });
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

  // ---- undo and the history ----

  history() {
    historyCommit();
    return historyList();
  },

  // The setting whose editor has the focus now, or null. A move of the
  // focus ends the edit: its changes so far are a step.
  historyFocus({ key }) {
    if (core.historyFocus(key ?? null, Date.now())) post({ event: "history" });
    if (!core.historyPending()) {
      clearTimeout(histTimer);
      histTimer = 0;
    }
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
      historySchedule();
      wantSlice();
    }
    return { error: rc === 0 ? "" : (rc === 15 ? "A move of a part cannot be undone alone: go to the step before it." : `The change was not undone (${rc}).`), ...settingsState() };
  },

  // ---- the tools: move a part, and measure ----

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
    if (core.w.x.zs_app_part_move(core.app, index, x, y) === 0) sliceOrHold(hold);
    return { part: core.part(index) };
  },

  partRotate({ index, step }) {
    const p = core.part(index);
    if (!p) return { part: null };
    if (core.w.x.zs_app_part_rotate(core.app, index, p.rotation + step) === 0) sliceOrHold(false);
    return { part: core.part(index) };
  },

  // The measurements of a line at its segment (for a circle or an arc
  // under the measure tape).
  measureAt({ path, seg }) {
    if (core.state() !== STATE.done) return { m: null };
    return { m: core.measure(path, seg) };
  },

  // ---- the printability check ----

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
      plates[active].status = "empty";
      plates[active].wanted = false;
      // An empty plate: an empty scene for the page.
      const scene = core.scene(mode);
      post({ event: "cleared", scene, plate: active }, scene ? [scene] : []);
      postPlates();
      return {};
    }
    wantSlice();
    return {};
  },

  // ---- one part (partcard.js) ----

  partAction({ index, action }) {
    const r = core.partAction(index, action);
    if (r >= 0) wantSlice();
    const n = core.w.x.zs_app_part_count(core.app);
    const at = action === "duplicate" && r >= 0 ? r : index;
    return { ok: r >= 0, part: action === "remove" || at >= n ? null : core.part(at) };
  },

  // The part `dir` steps from part `index` (Tab and Shift+Tab), around
  // the plate. index -1: the first part (or the last, for dir < 0).
  partStep({ index, dir }) {
    const n = core.w.x.zs_app_part_count(core.app);
    if (n === 0) return { part: null };
    const j = index < 0 ? (dir > 0 ? 0 : n - 1) : (((index + dir) % n) + n) % n;
    return { part: core.part(j) };
  },

  // Turns part `index` about X (axis 0) or Y (axis 1) by `degrees`, or
  // about Z (axis 2): the Turn tool.
  partTurn({ index, axis, degrees, hold }) {
    const x = core.w.x;
    let rc;
    if (axis === 2) {
      const p = core.part(index);
      if (!p) return { part: null };
      rc = x.zs_app_part_rotate(core.app, index, p.rotation + degrees);
    } else {
      rc = x.zs_app_part_turn(core.app, index, axis, degrees);
    }
    if (rc === 0) sliceOrHold(hold);
    return { part: core.part(index) };
  },

  // Lays part `index` down on the side nearest to the point x, y, z (mm)
  // of its surface (a double click on a side).
  partPutDown({ index, x, y, z }) {
    if (core.w.x.zs_app_part_put_down_at(core.app, index, x, y, z) === 0) wantSlice();
    return { part: core.part(index) };
  },

  // The end of a drag or of the keys of a part: the slice that waited.
  sliceHeld() {
    if (held) sliceOrHold(false);
    return {};
  },

  partSettings({ index }) {
    return { list: core.partSettings(index) };
  },

  partSettingSet({ index, name, value }) {
    const error = core.setPartSetting(index, name, value);
    if (!error) wantSlice();
    return { error, value: core.partSetting(index, name), list: core.partSettings(index) };
  },

  // ---- printdeck.yml projects (project.js) ----  // ---- printdeck.yml projects (project.js) ----

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

  // All plates of a project, each in its own app. list: one item for each
  // plate: { index, name, files } ({ path: bytes }), or { index, name,
  // resin: true } for a plate that zslice cannot slice. The plates slice
  // in the background, the active plate (`active`) first.
  projectSet({ text, counts, plates: list, active: want }) {
    if (histTimer) historyCommit();
    const threads = core.threads;
    const infos = core.infos;
    for (const p of plates) p.core.free();
    plates = [];
    const results = [];
    for (const item of list) {
      const c = new Core(wasm, infos);
      c.threads = threads;
      const p = newPlate(c, item.name);
      plates.push(p);
      if (item.resin) {
        // Its parts, with no slice: the page shows their footprints.
        p.status = "resin";
        try {
          for (const part of item.parts ?? []) {
            for (const [path, bytes] of Object.entries(part.files)) {
              for (let k = 0; k < part.count; k++) c.addStl(path.split("/").pop(), bytes);
            }
          }
          if (c.w.x.zs_app_part_count(c.app) > 1) c.w.x.zs_app_plate_arrange(c.app);
        } catch {
          // A part that does not open: the plate shows no footprint for it.
        }
        results.push({ error: "" });
        continue;
      }
      const f = c.filesNew(item.files);
      try {
        const r = c.projectLoad(f, text, counts ?? [], item.index);
        results.push({ error: r.error, fits: r.fits, message: r.message });
        if (r.error) p.status = "failed";
        else {
          p.status = "stale";
          p.wanted = true;
        }
      } finally {
        c.filesFree(f);
      }
    }
    active = Math.max(0, Math.min(want ?? 0, plates.length - 1));
    core = plates[active].core;
    showActive(-1);
    schedule();
    return { results, index: active, info: core.modelInfo(), parts: core.w.x.zs_app_part_count(core.app), ...settingsState() };
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
    // The first step of a plate: its state at the start. The core notes
    // each change; a change starts or extends a step.
    if (op === "init" || op === "projectSet" || (core && core.historyCount() === 0)) historyCommit();
    else if (SETTING_OPS.has(op) || PLATE_OPS.has(op)) historySchedule();
    const transfer = result?.bytes ? [result.bytes] : [];
    post({ id, result }, transfer);
  } catch (err) {
    post({ id, error: String(err?.message ?? err) });
  }
};
