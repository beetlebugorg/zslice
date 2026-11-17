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
let warming = false; // a warm-up slice runs: its events do not go to the page

function post(msg, transfer = []) {
  self.postMessage(msg, transfer);
}

function onEvent(event, progress) {
  if (warming) return;
  // ZS_EVENT_PROGRESS: at most each 2 %, so the page gets few messages.
  if (event === 1 && (progress - lastProgress >= 0.02 || progress < lastProgress)) {
    lastProgress = progress;
    post({ event: "progress", progress });
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

// The result of a slice for the page.
function sendResult(ms) {
  const state = core.state();
  // A canceled slice: the change that canceled it waits, and its slice
  // comes next.
  if (state === STATE.ready && ms > 0) {
    post({ event: "canceled" });
    return;
  }
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

// ---- undo and the history (linux/src/model/app-model.c: undo_*) ----
//
// The history is a list of steps: the undo list, the step now, and the
// redo list. A step has the texts of the three groups of settings, the
// plate (a 3MF file, null for an empty plate; steps with the same plate
// share its bytes), the facts of the state (for the history in words),
// and its time. A step ends 400 ms after the last change.

const UNDO_MAX = 100;
const hist = { undo: [], now: null, redo: [], timer: 0, plateDirty: true, restoring: false,
  // An edit of one setting is one step while its editor keeps the focus:
  // the setting of the changes since the last step ("*" for more than one,
  // or the plate), the setting of the last step while its edit is open,
  // and the setting whose editor has the focus (op "historyFocus").
  pendingKey: null, editKey: null, focusKey: null };

function snapshot() {
  const settings = [0, 1, 2].map((g) => core.stateText(g));
  let plate = null;
  if (!hist.plateDirty && hist.now) plate = hist.now.plate;
  else plate = core.plate3mf();
  hist.plateDirty = false;
  return { settings, quality: core.qualityName(), plate, facts: core.historyFacts(), time: Date.now() };
}

function samePlate(a, b) {
  if (a === b) return true;
  if (!a || !b || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function sameSettings(a, b) {
  return a.quality === b.quality && a.settings.every((t, g) => t === b.settings[g]);
}

// Ends the step of the changes so far.
function undoCommit() {
  clearTimeout(hist.timer);
  hist.timer = 0;
  const now = snapshot();
  const before = hist.now;
  const differs = before && (!sameSettings(now, before) || !samePlate(now.plate, before.plate));
  const key = hist.pendingKey;
  hist.pendingKey = null;
  const single = key && key !== "*";
  if (differs && single && hist.undo.length > 0 && key === hist.editKey && key === hist.focusKey) {
    // More changes of the setting of the last step: they change that step.
    hist.now = now;
    hist.redo = [];
    const prev = hist.undo[hist.undo.length - 1];
    if (sameSettings(prev, now) && samePlate(prev.plate, now.plate)) {
      // Back at the value before the edit: the step goes.
      hist.now = hist.undo.pop();
      hist.editKey = null;
    }
    post({ event: "history" });
    return;
  }
  // A commit with no change keeps the edit open.
  if (differs) hist.editKey = single ? key : null;
  if (differs) {
    hist.undo.push(before);
    if (hist.undo.length > UNDO_MAX) hist.undo.shift();
    hist.redo = [];
    hist.now = now;
    post({ event: "history" });
  } else {
    hist.now = now;
  }
}

function undoSchedule(plate, key) {
  if (hist.restoring || !core) return;
  const k = plate || !key ? "*" : key;
  hist.pendingKey = hist.pendingKey === null || hist.pendingKey === k ? k : "*";
  if (plate) hist.plateDirty = true;
  clearTimeout(hist.timer);
  hist.timer = setTimeout(undoCommit, 400);
}

// Loads a step: the plate if it differs, then each group of settings
// whose text differs, then the quality.
function undoRestore(snap, before) {
  hist.restoring = true;
  try {
    if (!samePlate(snap.plate, before?.plate ?? null)) {
      if (snap.plate) {
        core.loadStl("plate.3mf", snap.plate);
      } else {
        core.w.x.zs_app_plate_clear(core.app);
        core.modelName = "";
        const scene = core.scene(mode);
        post({ event: "cleared", scene }, scene ? [scene] : []);
      }
    }
    for (let g = 0; g < 3; g++) {
      if (core.stateText(g) !== snap.settings[g]) core.loadProfile(g, snap.settings[g]);
    }
    if (snap.quality !== core.qualityName() && snap.quality !== "custom") core.setQuality(snap.quality, true);
  } finally {
    hist.restoring = false;
    hist.plateDirty = false;
  }
  if (core.w.x.zs_app_part_count(core.app) > 0) wantSlice();
}

// The steps, the oldest first: their time, kind, and changes in words.
function historyList() {
  const steps = [...hist.undo, ...(hist.now ? [hist.now] : []), ...[...hist.redo].reverse()];
  return {
    current: hist.undo.length,
    steps: steps.map((s, i) => {
      if (i === 0) return { time: s.time, kind: "start", changes: "", text: "The start" };
      const changes = core.historyDiff(steps[i - 1].facts, s.facts);
      return { time: s.time, kind: core.historyKind(changes), changes, text: core.historyDescribe(changes) };
    }),
  };
}

// Goes to step i of the list.
function historyGoto(i) {
  undoCommit();
  const cur = hist.undo.length;
  const count = hist.undo.length + 1 + hist.redo.length;
  if (!hist.now || i === cur || i < 0 || i >= count) return false;
  const before = hist.now;
  if (i < cur) {
    hist.redo.push(hist.now);
    while (hist.undo.length > i + 1) hist.redo.push(hist.undo.pop());
    hist.now = hist.undo.pop();
  } else {
    hist.undo.push(hist.now);
    while (hist.undo.length < i) hist.undo.push(hist.redo.pop());
    hist.now = hist.redo.pop();
  }
  undoRestore(hist.now, before);
  hist.editKey = null;
  return true;
}

// The ops that change the settings, and the ops that change the plate:
// each starts or extends a step.
const SETTING_OPS = new Set(["set", "reset", "quality", "profile", "setScoped", "resetScoped"]);
const PLATE_OPS = new Set(["load", "add", "plate", "projectLoad", "partAction", "partSettingSet", "putDown", "place", "partMove", "partRotate", "markAdd", "markRemoveNear", "markSet", "markRemove", "marksClear"]);

const ops = {
  async init({ module, saved, mode: m }) {
    mode = m ?? 0;
    const wasm = await Wasm.create(module, onEvent);
    // The threads of a slice: this worker is one, and one CPU stays free
    // for the page, as in the GTK app.
    const threads = wasm.startThreads(Math.max((navigator.hardwareConcurrency ?? 1) - 2, 0), (data) => {
      new Worker(new URL("./thread.js", import.meta.url), { type: "module" }).postMessage(data);
    });
    core = new Core(wasm);
    core.threads = threads + 1;
    // With a shared memory (the module with threads), the page can stop a
    // slice that runs: it sets the cancel flag of the app (client.js).
    if (wasm.shared) post({ event: "cancel-flag", memory: wasm.x.memory, address: wasm.x.zs_app_cancel_address(core.app) });
    const errors = core.restore(saved);
    // After the threads start, and only if the plate is still empty then.
    setTimeout(warmUp, 300);
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

  // ---- undo and the history ----

  history() {
    undoCommit();
    return historyList();
  },

  // The setting whose editor has the focus now, or null. A move of the
  // focus ends the edit: its changes so far are a step.
  historyFocus({ key }) {
    if (key === hist.focusKey) return {};
    if (hist.timer) undoCommit();
    hist.editKey = null;
    hist.focusKey = key;
    return {};
  },

  undo() {
    undoCommit();
    const ok = historyGoto(hist.undo.length - 1);
    return { ok, ...settingsState() };
  },

  redo() {
    undoCommit();
    const ok = historyGoto(hist.undo.length + 1);
    return { ok, ...settingsState() };
  },

  // Clears the history after step `index`: goes to it first if it is not
  // the step now, then drops the later steps (they cannot be redone).
  historyTruncate({ index }) {
    undoCommit();
    if (index !== hist.undo.length) historyGoto(index);
    if (index === hist.undo.length) {
      hist.redo = [];
      hist.editKey = null;
    }
    return { ...settingsState() };
  },

  historyGoto({ index }) {
    const ok = historyGoto(index);
    return { ok, ...settingsState() };
  },

  // Undoes one change line of a step and keeps the others: a new step.
  historyRevert({ line }) {
    const rc = core.historyRevert(line);
    if (rc === 0) {
      undoSchedule(line.startsWith("part:"));
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

  partMove({ index, x, y }) {
    if (core.w.x.zs_app_part_move(core.app, index, x, y) === 0) wantSlice();
    return { part: core.part(index) };
  },

  partRotate({ index, step }) {
    const p = core.part(index);
    if (!p) return { part: null };
    if (core.w.x.zs_app_part_rotate(core.app, index, p.rotation + step) === 0) wantSlice();
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
      // An empty plate: an empty scene for the page.
      const scene = core.scene(mode);
      post({ event: "cleared", scene }, scene ? [scene] : []);
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

  // The plate as a 3MF file, for keep.js.  // The plate as a 3MF file, for keep.js.
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
    if (op === "init") undoCommit();
    else if (SETTING_OPS.has(op)) undoSchedule(false, op === "quality" || op === "profile" ? null : args.name);
    else if (PLATE_OPS.has(op)) undoSchedule(true);
    const transfer = result?.bytes ? [result.bytes] : [];
    post({ id, result }, transfer);
  } catch (err) {
    post({ id, error: String(err?.message ?? err) });
  }
};
