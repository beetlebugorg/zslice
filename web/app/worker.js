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
