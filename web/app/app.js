// app.js: the main thread of the zslice web app. It builds the window of
// the GTK shell (linux/src/ui/window.c): the header bar with the profile
// menus, the 3D preview with its toolbar and layer slider, and the panel
// with the settings and the print card.
//
// The app core runs in a Web Worker (worker.js, through client.js), so a
// slice does not block the page. The 3D view runs here, in a second wasm
// instance (view.js), and draws with WebGL2 (gl.js). The settings persist in
// localStorage, as the texts of zs_app_state_write.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { Wasm } from "./wasm.js";
import { savePlate, loadPlate, clearPlate } from "./keep.js";
import { Client } from "./client.js";
import { View3D, MODES } from "./view.js";
import { GlRenderer } from "./gl.js";
import { View2D } from "./view2d.js";
import { LayerRange } from "./layers.js";
import { SettingsBrowser, el } from "./settings.js";
import { Inspector } from "./inspector.js";
import { Gaps } from "./gaps.js";
import { HistoryPage } from "./history.js";
import { ProjectPage } from "./project.js";
import { SearchOverlay } from "./search.js";
import { ShortcutSheet } from "./shortcuts.js";
import { LineCard } from "./linecard.js";
import { PartCard } from "./partcard.js";
import { TurnRings } from "./turn.js";
import { FarmPage } from "./farm.js";
import { Tools } from "./tools.js";
import { SupportTool } from "./support.js";
import { KINDS, send as sendToPrinter, test as testPrinter, requestKey, trustText } from "./link.js";
import { signGcode, supported as canSign, UNSUPPORTED as NO_SIGNATURES } from "./signing.js";
import { contextItems } from "./context-menu.js";
import { openMenu, openMenuAt, menuOpen, openPopover, closeMenu } from "./menus.js";
import { formatClock, formatTime, useCore } from "./format.js";
import { openPrinterPicker, bedFiles } from "./printers.js";

const $ = (id) => document.getElementById(id);
const STORE_KEY = "zslice.web.v1";
const SPEEDS = [1, 2, 5, 10, 20, 50, 100];

// ---- the saved state ----

function loadStore() {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY)) ?? {};
  } catch {
    return {};
  }
}

const store = loadStore();

function saveStore() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(store));
  } catch {
    // A private window can refuse storage: the settings then last for this
    // page only.
  }
}

// ---- small helpers ----

let toastTimer = 0;
function toast(text, ms = 5000) {
  const t = $("toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}

function download(bytes, name, type) {
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

// ---- start ----

async function compileModule(name) {
  const url = new URL(name, import.meta.url);
  try {
    return await WebAssembly.compileStreaming(fetch(url));
  } catch {
    // A server with another MIME type for .wasm.
    const r = await fetch(url);
    if (!r.ok) throw new Error(`${name}: HTTP ${r.status}`);
    return WebAssembly.compile(await r.arrayBuffer());
  }
}

// The module with threads needs a shared memory, and a browser gives one
// only to a page that is cross-origin isolated (COOP and COEP headers).
// ?threads=0 takes the module with no threads.
const wantThreads = globalThis.crossOriginIsolated && new URLSearchParams(location.search).get("threads") !== "0";
const module = wantThreads
  ? await compileModule("zslice-mt.wasm").catch(() => compileModule("zslice.wasm"))
  : await compileModule("zslice.wasm");
const wasm = await Wasm.create(module);
// The text of setting values comes from the core (format.js).
useCore(wasm);
const infos = wasm.settingInfos();

const app = {
  snapshot: null,
  state: "empty",
  stats: null,
  layers: null,
  modelName: "",
  mode: store.mode ?? 0,
  speed: store.speed ?? 10,
  slicing: false,
  focusMask: 0,
  focusFirst: false,
  focus2d: 0,
  // The page of the preview: "3d" or "2d".
  page: store.view === "2d" ? "2d" : "3d",
  // The selected line: its path and segment (-1: none), and its info
  // from the worker (the Selected page).
  sel: -1,
  seg: -1,
  info: null,
  isolate: store.isolate ?? false,
  marks: 0,
  parts: 0,
  // The print time that the 3D view shows (a replay, a scrub, or a step
  // of h and l), or 0 for whole layers.
  time: 0,
  // The plate set (zs_set in the worker): the list from the worker ({ id,
  // name, status, bed, model, printer, parts, message }), the active
  // plate, the plate that the page asked to make active (-1: none), and
  // the plate that the camera goes to when it is active (-1: none).
  plates: [],
  activePlate: 0,
  wantPlate: -1,
  framePlate: -1,
};

const client = new Client(onWorkerEvent);

// ---- the 3D view ----

const canvas = $("gl");
const gl = new GlRenderer(canvas);
const view = new View3D(wasm, 16, 16);

// The view follows the dark mode of the system: the background, the grid,
// and the bed of the 3D view (zs_view_set_dark) and of the 2D view.
{
  const dark = window.matchMedia?.("(prefers-color-scheme: dark)");
  const apply = () => {
    const on = !!dark?.matches;
    view.x.zs_view_set_dark(view.v, on ? 1 : 0);
    gl.dark = on;
  };
  apply();
  // A change later draws a frame (the first frame comes after the start).
  dark?.addEventListener?.("change", () => {
    apply();
    requestFrame();
  });
}
const view2d = new View2D(view, gl);
let frameQueued = false;
let lastFrameTime = 0;

function requestFrame() {
  if (frameQueued) return;
  frameQueued = true;
  requestAnimationFrame(drawFrame);
}

// The time of each frame (ms), for tests: the last 240 frames.
const frameTimes = new Float64Array(240);
let frameCount = 0;

function drawFrame(now) {
  frameQueued = false;
  const t0 = performance.now();
  const dt = lastFrameTime ? Math.min(0.1, (now - lastFrameTime) / 1000) : 1 / 60;
  lastFrameTime = now;
  let more = app.page === "3d" && view.animate(dt);
  if (replay.playing) {
    stepReplay(dt);
    more = more || replay.playing;
  }
  if (step.active) more = animateStep(now) || more;
  // The gaps follow the top layer.
  if (gaps.on && gaps.wanted !== layers.hi && app.state === "done") gaps.refresh(layers.hi);
  // The rings of the Turn tool go in this frame (the core draws them).
  turnRings?.place();
  const f = view.frame();
  if (app.page === "2d") {
    view2d.state.gaps = gaps.on && gaps.layer === layers.hi;
    gl.sync(f);
    const dim = (app.isolate && app.sel >= 0) || (app.focus2d && app.focusFirst && layers.hi !== 0) ? 1 : 0;
    view2d.draw(f.width, f.height, layers.hi, app.sel, app.seg, app.focus2d, dim);
  } else {
    gl.draw(f);
  }
  tools?.placeTape();
  partCard?.place();
  supportTool?.place();
  placePlateLabels();
  frameTimes[frameCount++ % frameTimes.length] = performance.now() - t0;
  if (more) requestFrame();
  else lastFrameTime = 0;
}



// ---- the panel: a drawer (docs/internals/one-view.md) ----
//
// "hidden": the view has the whole window. "overlay": the panel slides
// over the right of the view. "pinned": the panel is beside the view, as
// a column with the splitter. N shows and hides it; Pin switches between
// over and beside. The choice stays in the store.

function panelMode() {
  return store.panelMode === "pinned" || store.panelMode === "overlay" ? store.panelMode : "hidden";
}

function setPanelMode(mode) {
  const w = document.querySelector(".window");
  w.classList.toggle("panel-hidden", mode === "hidden");
  w.classList.toggle("panel-overlay", mode === "overlay");
  $("panel-toggle").setAttribute("aria-pressed", String(mode !== "hidden"));
  $("panel-pin").setAttribute("aria-pressed", String(mode === "pinned"));
  if (mode !== "hidden") store.panelPinned = mode === "pinned";
  store.panelMode = mode;
  saveStore();
  // A hidden panel leaves the view of the whole print; a panel that
  // shows again brings back the focus of its page.
  if (typeof browser === "undefined") return;
  if (mode === "hidden") clearFocus();
  else browser.sendFocus();
}

// Shows the panel (over the view, or pinned if the user pinned it last).
function showPanel() {
  if (panelMode() === "hidden") setPanelMode(store.panelPinned ? "pinned" : "overlay");
}

function togglePanel() {
  if (panelMode() === "hidden") showPanel();
  else setPanelMode("hidden");
}

setPanelMode(panelMode());
$("panel-toggle").onclick = () => togglePanel();
$("panel-close").onclick = () => setPanelMode("hidden");
$("panel-pin").onclick = () => setPanelMode(panelMode() === "pinned" ? "overlay" : "pinned");
// Esc in the panel over the view hides it (an entry keeps its own Esc).
$("panel").addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || panelMode() !== "overlay") return;
  if (e.target.closest?.("input, textarea, select")) return;
  setPanelMode("hidden");
  canvas.focus();
});

// ---- the splitter: the width of the panel, kept in the store ----

{
  const panel = $("panel");
  const splitter = $("splitter");
  const DEFAULT = 560;
  const clampWidth = (w) => Math.max(300, Math.min(w, window.innerWidth * 0.75));
  if (store.panelWidth) panel.style.width = `${clampWidth(store.panelWidth)}px`;
  let drag = null;
  splitter.addEventListener("pointerdown", (e) => {
    splitter.setPointerCapture(e.pointerId);
    drag = { x: e.clientX, w: panel.getBoundingClientRect().width };
    splitter.classList.add("dragging");
  });
  splitter.addEventListener("pointermove", (e) => {
    if (!drag) return;
    panel.style.width = `${clampWidth(drag.w - (e.clientX - drag.x))}px`;
  });
  const end = () => {
    if (!drag) return;
    drag = null;
    splitter.classList.remove("dragging");
    store.panelWidth = Math.round(panel.getBoundingClientRect().width);
    saveStore();
  };
  splitter.addEventListener("pointerup", end);
  splitter.addEventListener("pointercancel", end);
  splitter.addEventListener("dblclick", () => {
    panel.style.width = `${DEFAULT}px`;
    delete store.panelWidth;
    saveStore();
  });
}

function resize() {
  const dpr = window.devicePixelRatio || 1;
  const r = canvas.getBoundingClientRect();
  const w = Math.max(1, Math.round(r.width * dpr));
  const h = Math.max(1, Math.round(r.height * dpr));
  const changed = canvas.width !== w || canvas.height !== h;
  if (changed) {
    canvas.width = w;
    canvas.height = h;
  }
  view.resize(w, h);
  // A new size clears the canvas: draw at once, before the browser shows
  // it, or a drag of the splitter shows an empty (black) view.
  if (changed && typeof drawFrame === "function") drawFrame(performance.now());
  else requestFrame();
}
new ResizeObserver(resize).observe(canvas);

// The mouse. In 3D: a left drag orbits, a middle or a right drag (or Shift
// and a drag) pans, and the wheel zooms toward the pointer
// (linux/src/ui/view3d.c). On a trackpad: two fingers pressed down and
// dragged pan, and a light two-finger swipe or a pinch zooms.
// In 2D: a drag pans, and the wheel zooms (preview.c). In both: a click (a
// release within 4 pixels of the press) selects the line under the
// pointer, and a right click opens the context menu there.
let drag = null;
const dpr = () => window.devicePixelRatio || 1;

// Two fingers on a touch screen: a pinch zooms about the point between
// them, and a move of that point pans. These listeners run first (the
// capture phase) and stop the one-pointer handlers while two fingers are
// down. One finger orbits, as a left drag does.
const touches = new Map();
let pinch = null;
const touchPair = () => {
  const [a, b] = [...touches.values()];
  return { dist: Math.hypot(a.x - b.x, a.y - b.y), mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
};
canvas.addEventListener("pointerdown", (e) => {
  if (e.pointerType !== "touch") return;
  touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (touches.size === 2) {
    canvas.setPointerCapture(e.pointerId);
    // The first finger's drag ends: no orbit, and no click at the end.
    drag = null;
    pinch = touchPair();
    e.stopImmediatePropagation();
  }
}, { capture: true });
canvas.addEventListener("pointermove", (e) => {
  if (e.pointerType !== "touch" || !touches.has(e.pointerId)) return;
  touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (!pinch || touches.size !== 2) return;
  e.stopImmediatePropagation();
  const now = touchPair();
  const r = canvas.getBoundingClientRect();
  const px = (now.mx - r.left) * dpr();
  const py = (now.my - r.top) * dpr();
  const k = pinch.dist > 0 && now.dist > 0 ? now.dist / pinch.dist : 1;
  if (app.page === "2d") {
    view2d.pan((now.mx - pinch.mx) * dpr(), (now.my - pinch.my) * dpr());
    if (k !== 1) view2d.zoomAt(k, px, py, canvas.height);
  } else {
    view.pan((now.mx - pinch.mx) * dpr(), (now.my - pinch.my) * dpr());
    if (k !== 1) view.zoomAt(1 / k, px, py);
  }
  pinch = now;
  requestFrame();
}, { capture: true });
const touchUp = (e) => {
  if (e.pointerType !== "touch") return;
  touches.delete(e.pointerId);
  if (pinch) {
    // The end of a pinch is no click, also for the last finger.
    e.stopImmediatePropagation();
    if (touches.size === 0) pinch = null;
    drag = null;
    canvas.style.cursor = "";
  }
};
canvas.addEventListener("pointerup", touchUp, { capture: true });
canvas.addEventListener("pointercancel", touchUp, { capture: true });

canvas.addEventListener("pointerdown", (e) => {
  if (pinch) return;
  canvas.setPointerCapture(e.pointerId);
  drag = { button: e.button, x: e.clientX, y: e.clientY, x0: e.clientX, y0: e.clientY, moved: false, part: null };
  canvas.style.cursor = "grabbing";
  canvas.focus({ preventScroll: true });
  // The measure tape: a left drag on an end of it moves that end.
  if (e.button === 0 && tools.tool === "measure" && tools.pts.length > 0) {
    const r = canvas.getBoundingClientRect();
    const end = tools.endAt((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr(), dpr());
    if (end >= 0) {
      drag.tape = end;
      canvas.style.cursor = "grabbing";
      return;
    }
  }
  // The move tool, or Ctrl, in 3D: a left drag on a part moves it.
  if (e.button === 0 && app.page === "3d" && view.loaded && (tools.tool === "move" || e.ctrlKey)) {
    const d = drag;
    d.part = "pending";
    const r = canvas.getBoundingClientRect();
    tools.moveStart((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr()).then((ok) => {
      if (drag === d) d.part = ok ? "moving" : null;
    });
  }
});
canvas.addEventListener("pointermove", (e) => {
  if (!drag) return;
  const dx = e.clientX - drag.x;
  const dy = e.clientY - drag.y;
  drag.x = e.clientX;
  drag.y = e.clientY;
  if (dx === 0 && dy === 0) return;
  if (Math.abs(e.clientX - drag.x0) > 4 || Math.abs(e.clientY - drag.y0) > 4) drag.moved = true;
  if (drag.tape !== undefined) {
    const r = canvas.getBoundingClientRect();
    tools.dragEnd(drag.tape, (e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr(), e.shiftKey);
    return;
  }
  if (drag.part === "moving") {
    const r = canvas.getBoundingClientRect();
    tools.moveTo((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr());
    return;
  }
  if (drag.part === "pending") return;
  // A left drag orbits. A right drag (two fingers pressed down on a
  // touchpad) and a middle drag pan, as Shift with a left drag does.
  if (app.page === "2d") view2d.pan(dx * dpr(), dy * dpr());
  else if (drag.button === 1 || drag.button === 2 || e.shiftKey) view.pan(dx * dpr(), dy * dpr());
  else view.orbit(dx, dy);
  requestFrame();
});
canvas.addEventListener("pointerup", (e) => {
  const d = drag;
  endDrag();
  if (d?.part === "moving") {
    tools.moveEnd();
    return;
  }
  // A press on an end of the tape: a drag moved it; a click leaves it.
  if (d?.tape !== undefined) return;
  if (!d || d.moved || !view.loaded) return;
  const r = canvas.getBoundingClientRect();
  const px = (e.clientX - r.left) * dpr();
  const py = (e.clientY - r.top) * dpr();
  // A click on another plate (its bed or its beads) makes it active.
  if (d.button === 0 && app.page === "3d" && app.plates.length > 1) {
    const i = view.plateAt(px, py);
    if (i >= 0 && i !== app.activePlate) {
      activatePlate(i, false);
      return;
    }
  }
  if (d.button === 0 && tools.tool === "support" && app.page === "3d") supportTool.click(px, py, e.shiftKey);
  else if (d.button === 0 && tools.tool === "measure") tools.measureClick(px, py, e.shiftKey);
  else if (d.button === 0 && app.page === "3d" && (tools.tool === "move" || tools.tool === "turn" || e.ctrlKey)) tools.pickPart(px, py);
  else if (d.button === 0) pickAt(px, py, true);
  else if (d.button === 2) {
    // A right click: the line there, then the menu.
    if (hitAt(px, py)) select(view.hit[0], view.hit[1], false);
    showContextMenu(e.clientX, e.clientY);
  }
});
const endDrag = () => {
  drag = null;
  canvas.style.cursor = "";
};
canvas.addEventListener("pointercancel", endDrag);
canvas.addEventListener("contextmenu", (e) => e.preventDefault());
// A double click: on another plate (with more than one), the camera goes
// to it and it becomes the active plate; on a side of a part (3D), the view
// turns to face that side and zooms to it; elsewhere, the view resets.
canvas.addEventListener("dblclick", async (e) => {
  if (app.page === "2d") {
    view2d.fit(canvas.width, canvas.height);
    requestFrame();
    return;
  }
  if (app.plates.length > 1) {
    const r = canvas.getBoundingClientRect();
    const i = view.plateAt((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr());
    if (i >= 0 && i !== app.activePlate) {
      activatePlate(i, true);
      return;
    }
  }
  const px = e.offsetX * dpr();
  const py = e.offsetY * dpr();
  // The side of the print under the pointer (zs_view_look_at_side), from
  // the size of its part.
  const part = app.state !== "empty" ? await tools.partAt(px, py) : null;
  const size = part ? Math.max(part.sizeX, part.sizeY, part.sizeZ) : 0;
  if (app.state !== "empty" && view.x.zs_view_look_at_side(view.v, px, py, size)) {
    // The first click of the double click picked a line: not wanted.
    select(-1, -1, false);
    requestFrame();
    return;
  }
  view.resetSmooth();
  requestFrame();
});
// A wheel event from a trackpad: two fingers that move (pixels, small
// steps, or a sideways part) pan the view, as in Fusion and Tinkercad. A
// mouse wheel gives steps of 100 pixels or more, or lines, and zooms. A
// pinch has Ctrl, and zooms. Shift and a mouse wheel: zoom too.
let trackpadUntil = 0;
function fromTrackpad(e) {
  if (e.ctrlKey || e.deltaMode !== 0) return false;
  const now = performance.now();
  // A sideways part, or a small step: a trackpad. Its next events in the
  // same gesture count as the trackpad too (a fast swipe has big steps).
  if (e.deltaX !== 0 || Math.abs(e.deltaY) < 50 || !Number.isInteger(e.deltaY)) {
    trackpadUntil = now + 300;
    return true;
  }
  return now < trackpadUntil;
}

canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  const r = canvas.getBoundingClientRect();
  // The move tool and a mouse wheel: turn the selected part 15° a step.
  if (tools.tool === "move" && tools.part && !e.ctrlKey && !fromTrackpad(e)) {
    tools.turn(e.deltaY);
    return;
  }
  if (fromTrackpad(e)) {
    // A two-finger swipe zooms toward the pointer, as a pinch does: 40
    // pixels of the swipe are one wheel step.
    const steps = e.deltaY / 40;
    const px = (e.clientX - r.left) * dpr();
    const py = (e.clientY - r.top) * dpr();
    if (app.page === "2d") view2d.zoomAt(Math.pow(1.2, -steps), px, py, canvas.height);
    else view.zoomAt(Math.pow(1.15, steps), px, py);
    requestFrame();
    return;
  }
  // One wheel step is about 100 pixels (deltaMode 0) or 3 lines.
  // A pinch on a trackpad comes as a wheel event with Ctrl and small
  // steps, so it counts more for each pixel.
  const per = e.ctrlKey ? 25 : 100;
  const steps = e.deltaMode === 1 ? e.deltaY / 3 : e.deltaMode === 2 ? e.deltaY : e.deltaY / per;
  const px = (e.clientX - r.left) * dpr();
  const py = (e.clientY - r.top) * dpr();
  if (app.page === "2d") view2d.zoomAt(Math.pow(1.2, -steps), px, py, canvas.height);
  else view.zoomAt(Math.pow(1.15, steps), px, py);
  requestFrame();
}, { passive: false });

// The line under a device pixel of the view that shows: sets view.hit.
// The time of the last pick (ms), for tests.
let pickMs = 0;
function hitAt(px, py) {
  const t0 = performance.now();
  const hit = app.page === "2d" ? view2d.pick(layers.hi, px, py, canvas.height) : view.pickSegment(px, py);
  pickMs = performance.now() - t0;
  return hit;
}

// A click: with Gaps on, the gap there; else the line there (its
// segment too), or no selection.
async function pickAt(px, py, picked) {
  if (picked && gaps.on) {
    const pt = topLayerPoint(px, py);
    if (pt && (await gaps.pick(pt[0], pt[1]))) return;
  }
  gaps.forget();
  app.pickPoint = [px / dpr(), py / dpr()];
  if (hitAt(px, py)) select(view.hit[0], view.hit[1], picked);
  else select(-1, -1, false);
}

// The point (mm) under a device pixel on the top of the top shown layer,
// or null.
function topLayerPoint(px, py) {
  if (app.page === "2d") return [(px - view2d.ox) / view2d.scale, (canvas.height - py - view2d.oy) / view2d.scale];
  const z = app.layers?.z[layers.hi];
  if (z === undefined) return null;
  const c = wasm.cell;
  if (!view.x.zs_view_layer_point(view.v, px, py, z, c, c + 8)) return null;
  return [wasm.f64(c), wasm.f64(c + 8)];
}

// ---- the layer slider and the replay ----

const layers = new LayerRange($("layers"), (lo, hi) => {
  // A move of the slider stops the replay and a step of h and l, and
  // shows whole layers. The 2D view shows the top layer.
  stopReplay();
  stopStep();
  app.time = 0;
  view.setLayerRange(lo, hi);
  showScrub(hi, null);
  updateFocus();
  gaps.refresh(hi);
  requestFrame();
});

const replay = { playing: false, t: 0 };

function layerTimes(l) {
  const end = app.layers?.endTime;
  if (!end || l >= end.length) return [0, 0];
  return [l > 0 ? end[l - 1] : 0, end[l]];
}

// The scrub bar: the time in the top layer.
function showScrub(layer, t) {
  if (!app.layers) return;
  const [t0, t1] = layerTimes(layer);
  const time = t ?? t1;
  const f = t1 > t0 ? Math.min(1, Math.max(0, (time - t0) / (t1 - t0))) : 1;
  $("scrub-range").value = String(f);
  const inLayer = Math.min(Math.max(time - t0, 0), t1 - t0);
  $("scrub-label").textContent = `Layer ${layer + 1} · ${formatClock(inLayer)} / ${formatClock(t1 - t0)}`;
}

$("scrub-range").addEventListener("input", () => {
  if (!app.layers) return;
  stopReplay();
  const layer = layers.hi;
  const [t0, t1] = layerTimes(layer);
  const f = Number($("scrub-range").value);
  stopStep();
  showPage("3d");
  app.time = f >= 1 ? 0 : t0 + f * (t1 - t0);
  if (f >= 1) view.setLayerRange(layers.lo, layer);
  else view.setTime(app.time);
  showScrub(layer, t0 + f * (t1 - t0));
  requestFrame();
});

function setPlayIcon(playing) {
  $("play-icon").setAttribute("d", playing ? "M4 2.5h3v11H4z M9 2.5h3v11H9z" : "M4 2.5v11l9-5.5z");
}

function startReplay() {
  if (!view.loaded) return;
  stopStep();
  showPage("3d");
  const d = view.duration();
  if (replay.t <= 0 || replay.t >= d) replay.t = 0;
  // After a move of the slider: from the start of the top layer.
  if (replay.t <= 0 && layers.hi + 1 < layers.count) replay.t = layerTimes(layers.hi)[0];
  replay.playing = true;
  setPlayIcon(true);
  requestFrame();
}

function stopReplay() {
  if (!replay.playing) return;
  replay.playing = false;
  setPlayIcon(false);
}

function stepReplay(dt) {
  const d = view.duration();
  replay.t += dt * app.speed;
  if (replay.t >= d) {
    replay.t = d;
    stopReplay();
    view.setLayerRange(layers.lo, Math.max(0, layers.count - 1));
    layers.set(layers.lo, layers.count - 1, true);
    showScrub(layers.hi, null);
    return;
  }
  view.setTime(replay.t);
  app.time = replay.t;
  const layer = view.layerAtTime(replay.t);
  layers.set(Math.min(layers.lo, layer), layer, true);
  showScrub(layer, replay.t);
}

$("play").onclick = () => (replay.playing ? stopReplay() : startReplay());
$("speed").textContent = `${app.speed}×`;
$("speed").onclick = () => openMenu($("speed"), SPEEDS.map((s) => ({
  label: `${s}×`,
  checked: s === app.speed,
  action: () => {
    app.speed = s;
    store.speed = s;
    saveStore();
    $("speed").textContent = `${s}×`;
  },
})));

// ---- the colors ----

const LEGEND_UNITS = ["", "", "mm/s", "mm³/s", "s", "mm"];

function showLegend() {
  const lg = view.loaded && app.mode >= 2 ? view.legend() : null;
  const box = $("legend");
  if (!lg) {
    box.hidden = true;
    return;
  }
  const [lo, hi] = lg;
  const u = LEGEND_UNITS[app.mode];
  box.textContent = app.mode === 4 ? `${lo.toFixed(0)}–${hi.toFixed(0)} ${u} (red: short)`
    : app.mode === 5 ? `${lo.toFixed(2)}–${hi.toFixed(2)} ${u}` : `${lo.toFixed(0)}–${hi.toFixed(0)} ${u}`;
  box.hidden = false;
}

$("colors").textContent = MODES[app.mode];
$("colors").onclick = () => openMenu($("colors"), MODES.map((m, i) => ({
  label: m,
  checked: i === app.mode,
  action: () => {
    app.mode = i;
    store.mode = i;
    saveStore();
    $("colors").textContent = m;
    // A color mode is for the 3D view.
    showPage("3d");
    client.call("mode", { value: i });
  },
})));

// ---- the settings ----

function updateFocus() {
  const settingsVisible = !$("page-settings").hidden;
  let mask = settingsVisible ? app.focusMask : 0;
  // The Support tool: a focus on all features but the support, so the
  // support lines are faint and the areas show through them.
  const ghost = !mask && supportTool?.seeThrough();
  if (ghost) mask = ((1 << 11) - 1) & ~((1 << 6) | (1 << 7));
  const zmax = app.focusFirst && app.layers?.z?.length ? app.layers.z[0] : -1;
  const shows = view.focus(mask, zmax);
  if (ghost) {
    app.focus2d = 0;
    requestFrame();
    return;
  }
  // A setting whose lines are not on this plate: the whole print shows,
  // and a note says why (once for each new focus).
  if (!shows && app.state === "done" && mask !== app.noLinesMask) toast("No lines of this setting on this plate: the view shows the whole print.");
  app.noLinesMask = shows ? 0 : mask;
  app.focus2d = shows ? mask : 0;
  requestFrame();
}

// The area that hangs in the air (mm²) over which the print card says to
// turn on support. The check of the print measures it (overhangs and
// islands, as warnings or problems; a bridge does not count), so a Benchy
// has none.
const OVERHANG_HINT_MM2 = 20;

// With support off: the check of the print after each slice, for the hint
// on the print card. It runs after the slice, so the slice stays fast.
async function checkOverhang() {
  if ((value("project.support") || "off") !== "off") return;
  const plate = app.activePlate;
  try {
    const r = await client.call("checks", {});
    if (app.activePlate !== plate || app.state !== "done") return;
    // Kinds of checks.zig: 2 overhang, 3 island.
    app.overhang = (r.issues ?? []).filter((i) => (i.kind === 2 || i.kind === 3) && i.severity >= 1).reduce((s, i) => s + (i.value || 0), 0);
    updateSummary();
  } catch {
    // No hint.
  }
}

async function setSetting(name, value) {
  // The focus first, so the worker knows if this change goes on an edit.
  sendFocus();
  try {
    const r = await client.call("set", { name, value });
    applySettings(r);
    return r.error;
  } catch (e) {
    return e.message;
  }
}

var browser = new SettingsBrowser({ // var: setPanelMode runs before this line
  infos,
  // The start or the end G-code with its values, from the last slice.
  gcodeHead: (name) => client.call("gcodeHead", { name }),
  effect: (name) => wasm.settingEffect(name),
  set: setSetting,
  reset: async (name) => applySettings(await client.call("reset", { name })),
  // The focus of a section or a setting of the panel: only while the
  // panel shows. A hidden panel shows the whole print.
  focus: (mask, first) => {
    if (panelMode() === "hidden") {
      clearFocus();
      return;
    }
    app.focusMask = mask;
    app.focusFirst = first;
    updateFocus();
  },
});

// The whole print again, with no focus on a feature.
function clearFocus() {
  app.focusMask = 0;
  app.focusFirst = false;
  updateFocus();
}

// The rings of the Turn tool around the selected part (turn.js).
var turnRings = new TurnRings({
  host: $("preview"),
  view,
  frame: () => requestFrame(),
  part: () => (app.page === "3d" ? tools.part : null),
  active: () => tools.tool === "turn",
  turn: async (axis, degrees) => {
    const part = tools.part;
    if (!part) return;
    const r = await client.call("partTurn", { index: part.index, axis, degrees, hold: true });
    if (r.part) tools.selectPart(r.part);
    requestFrame();
  },
  done: async () => {
    await settleSelected();
    client.call("sliceHeld");
  },
});

// Physics after a turn: a part that cannot stand falls onto a face, unless
// support holds it. The toast says so.
async function settleSelected() {
  const part = tools.part;
  if (!part) return;
  const r = await client.call("partSettle", { index: part.index });
  if (r.part) tools.selectPart(r.part);
  if (r.degrees > 0) {
    toast(`The part could not stand like that, and fell over (${Math.round(r.degrees)}°). Turn on support to hold it in place.`);
    requestFrame();
  }
}

// The keys of a part move and turn it at once; the slice waits for a pause
// of 0.6 s in the keys.
let heldKeys = 0;
function sliceAfterKeys(turned = false) {
  clearTimeout(heldKeys);
  heldKeys = setTimeout(async () => {
    if (turned) await settleSelected();
    client.call("sliceHeld");
  }, 600);
}

// The card of a selected part, next to it in the view (partcard.js).
var partCard = new PartCard({
  client,
  browser,
  host: $("preview"),
  pixelOf: (p) => tools.pixelOf(p),
  select: (part) => tools.selectPart(part),
  search: (text, scope) => search.show(text, scope),
  toast: (t) => toast(t),
  // Moves the part to another plate (-1: a new plate).
  movePart: async (index, to) => client.call("partMove", { index, to }),
  // Copies until there are n in all (zs_set_fill).
  fillPart: async (index, n) => client.call("partFill", { index, n }),
  // The plane of a cut (zs_view_set_cut): a box and a height, or null.
  cutPlane: (b) => {
    if (b) view.x.zs_view_set_cut(view.v, b[0], b[1], b[2], b[3], b[4]);
    else view.x.zs_view_set_cut(view.v, 0, 0, 0, 0, 0);
    requestFrame();
  },
});

// The card of a selected line, next to it in the view (linecard.js).
var lineCard = new LineCard({
  browser,
  isolate: () => toggleIsolate(),
  isolated: () => app.isolate,
  host: $("preview"),
  more: () => showTab("selected"),
  close: () => select(-1, -1, false),
  // An edit of the line (zs_app_edit_add): kind 0 delete, 1 flow.
  // info: the line (inspect), with its key and layer.
  edit: async (info, kind, value) => {
    const r = await client.call("editAdd", { path: info.path, key: info.key, layer: info.layer, kind, value });
    if (!r.ok) {
      toast("The line did not change.");
      return;
    }
    select(-1, -1, false);
    toast(kind === 0 ? `The line does not print now. ${r.count} ${r.count === 1 ? "edit" : "edits"} on this plate; undo with Ctrl+Z.` : `The line has ${Math.round((value - 1) * 100)} % plastic now.`);
  },
});

// A plate of a printdeck.yml project is on the view (project.js): its
// profiles come from the project.
var projectActive = false; // var: applySettings can run before this line

// The answer of the worker to a change: the values, and the state to keep.
function applySettings(r) {
  if (!r?.values) return;
  app.snapshot = r;
  browser.setValues(r);
  if (r.saved) {
    store.saved = r.saved;
    // An edit of the machine settings stays with the printer: its profile
    // is the machine settings now.
    // A plate of a project has the machine of its Cura stack: it does not
    // change the printer of the user.
    const mine = projectActive ? null : store.printers?.[store.printer];
    if (mine && r.saved.machine && mine.profile !== r.saved.machine) mine.profile = r.saved.machine;
    saveStore();
  }
  updateMenus();
  updateBed();
}

// The bed model of the printer in the 3D view: loaded when the printer
// (machine.model, or machine.name) changes. A printer with no bed model in
// the library keeps the grid.
let bedKey = null;
async function updateBed() {
  const id = value("machine.model");
  const name = value("machine.name");
  const key = `${id}\n${name}`;
  if (key === bedKey) return;
  bedKey = key;
  let shown = false;
  try {
    const b = await bedFiles(wasm, id, name);
    if (key !== bedKey) return;
    shown = !!b && view.setBed(b.lib, b.index, b.mesh, b.texture) === 0;
  } catch (e) {
    console.warn("zslice: the bed model did not load", e);
  }
  if (key !== bedKey) return;
  if (!shown) view.clearBed();
  requestFrame();
}

// ---- the header menus ----

function stateHasChanges(text) {
  return (text ?? "").split("\n").some((l) => l.trim() !== "" && !l.startsWith("#") && !l.startsWith("["));
}

function value(name) {
  return app.snapshot?.values?.[name]?.value ?? "";
}

function updateMenus() {
  $("printer-menu").textContent = store.printer || "generic";
  const fname = value("filament.name");
  $("filament-menu").textContent = fname || store.filament || "Filament";
  const q = app.snapshot?.quality || "custom";
  $("quality-menu").textContent = `Quality: ${q}${stateHasChanges(store.saved?.project) ? " •" : ""}`;
  $("quality-menu").title = `Quality settings: ${q}. Pick a profile.`;
}

async function loadProfile(group, name, text) {
  const r = await client.call("profile", { group, text });
  if (r.error) {
    toast(`The profile ${name} did not load: ${r.error}`);
    return;
  }
  if (group === 0) {
    store.printer = name;
    projectActive = false;
  }
  if (group === 1) store.filament = name;
  saveStore();
  applySettings(r);
}

// A printer of the picker: its machine profile, then the changes of the
// second step. The printers of the user stay in the store (store.printers).
async function addPrinter(p) {
  store.printers = store.printers ?? {};
  store.printers[p.name] = { profile: p.profile, url: p.url };
  await loadProfile(0, p.name, p.profile);
  await setSetting("machine.name", p.name);
  if (p.nozzle > 0) await setSetting("machine.nozzle_diameter", String(p.nozzle));
  await setSetting("machine.bed_size_x", String(p.bedX));
  await setSetting("machine.bed_size_y", String(p.bedY));
  await setSetting("machine.max_height", String(p.height));
  await setSetting("filament.diameter", p.filament);
  store.printer = p.name;
  saveStore();
  updateMenus();
  toast(`${p.name} is the printer now.`);
}

// The machine settings in the panel, at the start G-code (window.c).
function openPrinterSettings() {
  showTab("settings");
  browser.openSetting("machine.start_gcode");
}

// The printers of the user (store.printers): rename, the address for
// prints, or remove. The settings of the printer now are in the panel.
function managePrinters() {
  const d = document.createElement("dialog");
  d.className = "printers-dialog";
  const title = Object.assign(document.createElement("h3"), { textContent: "Your printers" });
  const list = document.createElement("div");
  list.className = "printers-list";
  const fill = () => {
    list.replaceChildren();
    const names = Object.keys(store.printers ?? {});
    if (names.length === 0) list.append(Object.assign(document.createElement("div"), { className: "dim", textContent: "No printers. Add one with Add a printer… in the printer menu." }));
    for (const n of names) {
      const p = store.printers[n];
      const row = document.createElement("div");
      row.className = "printers-row";
      const name = Object.assign(document.createElement("input"), { value: n, title: "The name of the printer" });
      const url = Object.assign(document.createElement("input"), { value: p.url ?? "", placeholder: "http://printer.local", title: "The address of the printer, to send it prints (printdeck, OctoPrint, Moonraker). A printdeck with a secure address shows it on its System page (https://….d.printdeck.beetlebug.org): paste that one, to send from this site in any browser." });
      const now = Object.assign(document.createElement("span"), { className: "dim", textContent: n === store.printer ? "in use" : "" });
      const kind = document.createElement("select");
      kind.title = "How zslice talks to the printer";
      for (const [k, label] of Object.entries(KINDS)) kind.append(new Option(label, k, false, (p.kind ?? "none") === k));
      kind.onchange = () => {
        p.kind = kind.value;
        saveStore();
        updateSummary();
      };
      const key = Object.assign(document.createElement("input"), { type: "password", value: p.apiKey ?? "", placeholder: "API key", autocomplete: "off", title: "The API key of the printer (printdeck and OctoPrint: Settings › API; Moonraker: if it needs one). It stays in this browser." });
      key.onchange = () => {
        p.apiKey = key.value.trim();
        saveStore();
      };
      const result = Object.assign(document.createElement("span"), { className: "dim printers-test" });
      const testB = Object.assign(document.createElement("button"), { textContent: "Test" });
      testB.onclick = async () => {
        result.textContent = "…";
        const t = await testPrinter({ ...p, name: n });
        result.textContent = t.message;
        result.classList.toggle("error", !t.ok);
      };
      const use = Object.assign(document.createElement("button"), { textContent: "Use", disabled: n === store.printer });
      use.onclick = async () => {
        await loadProfile(0, n, store.printers[n].profile);
        fill();
      };
      const settings = Object.assign(document.createElement("button"), { textContent: "Settings…" });
      settings.onclick = async () => {
        if (n !== store.printer) await loadProfile(0, n, store.printers[n].profile);
        d.close();
        openPrinterSettings();
      };
      const rm = Object.assign(document.createElement("button"), { className: "destructive", textContent: "Remove" });
      rm.onclick = () => {
        if (!confirm(`Remove the printer ${n}? Its settings go too.`)) return;
        delete store.printers[n];
        if (store.printer === n) store.printer = "";
        saveStore();
        updateMenus();
        fill();
      };
      name.onchange = async () => {
        const to = name.value.trim();
        if (!to || to === n || store.printers[to]) {
          name.value = n;
          if (to && to !== n) toast(`A printer named ${to} is there already.`);
          return;
        }
        store.printers[to] = store.printers[n];
        delete store.printers[n];
        if (store.printer === n) {
          store.printer = to;
          await setSetting("machine.name", to);
        }
        saveStore();
        updateMenus();
        fill();
      };
      url.onchange = () => {
        p.url = url.value.trim();
        saveStore();
        updateSummary();
      };
      const line2 = document.createElement("div");
      line2.className = "printers-row2";
      // A key from the printer: it asks its user "Allow zslice?" (the
      // touch screen of a printdeck, the web page of OctoPrint).
      const getKey = Object.assign(document.createElement("button"), {
        textContent: "Get a key",
        title: "Ask the printer for a key: allow zslice on its touch screen (printdeck) or in its web page (OctoPrint)",
      });
      getKey.hidden = p.kind === "moonraker";
      getKey.onclick = async () => {
        getKey.disabled = true;
        result.classList.remove("error");
        const r = await requestKey({ ...p, url: url.value.trim() || p.url, name: n }, (sec) => {
          result.textContent = `Allow zslice on the printer (${120 - sec} s)…`;
        });
        getKey.disabled = false;
        result.textContent = r.message;
        result.classList.toggle("error", !r.ok);
        if (r.ok) {
          p.apiKey = r.key;
          key.value = r.key;
          saveStore();
        }
      };
      // Verified or not verified (link.js trustText).
      const trust = Object.assign(document.createElement("div"), { className: "dim printers-trust" });
      const showTrust = () => {
        trust.textContent = trustText(p);
      };
      showTrust();
      const urlChanged = url.onchange;
      url.onchange = () => {
        urlChanged();
        showTrust();
      };
      const kindChanged = kind.onchange;
      kind.onchange = () => {
        kindChanged();
        getKey.hidden = kind.value === "moonraker";
        showTrust();
      };
      line2.append(kind, key, getKey, testB, result);
      row.append(name, url, now, use, settings, rm, line2, trust);
      list.append(row);
    }
  };
  fill();
  const close = Object.assign(document.createElement("button"), { className: "suggested", textContent: "Close" });
  close.onclick = () => d.close();
  d.append(title, list, close);
  d.onclose = () => d.remove();
  document.body.append(d);
  d.showModal();
}

function showPrinterPicker(hooks) {
  openPrinterPicker(wasm, addPrinter, hooks).catch((e) => toast(`The printer picker failed: ${e.message}`));
}

$("printer-menu").onclick = () => {
  const items = [];
  const mine = Object.keys(store.printers ?? {});
  if (mine.length) {
    items.push({ title: "Your printers" });
    for (const n of mine) items.push({ label: n, checked: n === store.printer, action: () => loadProfile(0, n, store.printers[n].profile) });
  }
  items.push({ title: "Built-in" });
  for (const n of wasm.builtinProfiles(0)) {
    items.push({ label: n, checked: n === (store.printer || "generic"), action: () => loadProfile(0, n, `extends = "${n}"\n`) });
  }
  items.push(
    { sep: true },
    { label: "Printer settings and G-code…", tip: "The bed, the nozzle, the speeds, and the start and end G-code of this printer.", action: openPrinterSettings },
    { label: "Manage printers…", disabled: mine.length === 0, tip: "Rename your printers, set their addresses, or remove them.", action: managePrinters },
    { label: "Add a printer…", action: () => showPrinterPicker() },
  );
  openMenu($("printer-menu"), items);
};

$("filament-menu").onclick = () => {
  // The type of plastic: the built-in profile of the material. The
  // diameter stays (a property of the printer).
  const now = value("filament.material").toLowerCase();
  const items = [{ title: "Material" }];
  for (const n of wasm.builtinProfiles(1)) {
    if (!n.startsWith("generic-")) continue;
    const mat = n.slice(8).toUpperCase();
    const dia = value("filament.diameter") || "1.75";
    items.push({ label: mat, checked: now === mat.toLowerCase(), action: () => loadProfile(1, n, `extends = "${n}"\ndiameter = ${dia}\n`) });
  }
  openMenu($("filament-menu"), items);
};

$("quality-menu").onclick = () => {
  const q = app.snapshot?.quality || "";
  const items = [{ title: "Built-in" }];
  for (const n of wasm.builtinProfiles(2)) {
    items.push({
      label: n,
      checked: n === q,
      action: async () => {
        const r = await client.call("quality", { name: n });
        if (r.error) toast(`The quality ${n} did not load: ${r.error}`);
        applySettings(r);
      },
    });
  }
  openMenu($("quality-menu"), items);
};

$("main-menu").onclick = () => openMenu($("main-menu"), [
  { label: "Open…", action: () => $("file").click() },
  { label: "Save project…", action: () => saveProject() },
  { label: "Export G-code…", disabled: app.state !== "done", action: exportGcode },
  { label: "Remove this plate", action: () => removePlate(app.activePlate) },
  { sep: true },
  { label: "Open a project…", action: () => showTab("project") },
  { label: "Printers", action: () => showFarm(true) },
  { label: "History", action: () => toggleHistory(true) },
  { sep: true },
  { label: "Licenses", action: showLicenses },
  { label: "About zslice", action: () => toast(`zslice ${wasm.cstr(wasm.x.zs_version())}: a slicer in Zig, in WebAssembly. AGPL-3.0-or-later.`) },
]);

function showLicenses() {
  const d = document.createElement("dialog");
  d.style.cssText = "background:#303030;color:inherit;border:none;border-radius:12px;padding:12px;max-width:720px";
  const close = document.createElement("button");
  close.textContent = "Close";
  close.onclick = () => d.close();
  const list = document.createElement("div");
  for (const l of wasm.licenses()) {
    const det = document.createElement("details");
    const sum = document.createElement("summary");
    sum.textContent = `${l.name} (${l.license})`;
    const pre = document.createElement("div");
    pre.className = "dialog-text";
    pre.textContent = l.text;
    det.append(sum, pre);
    list.append(det);
  }
  d.append(list, close);
  d.onclose = () => d.remove();
  document.body.append(d);
  d.showModal();
}

// The height of the dock, for the print card over it in a narrow view
// (the dock wraps onto more rows).
new ResizeObserver(() => $("preview").style.setProperty("--dock-h", `${$("dock").offsetHeight}px`)).observe($("dock"));

// ---- the panel and the pages ----

// The panel has the settings, and the long form of the selected line
// (with one back arrow to the settings). The history is a popover over
// the history bar, the project a dialog, and the printers a page over the
// view.
function showTab(name) {
  if (name === "history") {
    toggleHistory(true);
    return;
  }
  if (name === "project") {
    const d = $("project-dialog");
    if (!d.open) d.showModal();
    return;
  }
  if (name === "farm") {
    showFarm(true);
    return;
  }
  showPanel();
  const selected = name === "selected";
  $("page-settings").hidden = selected;
  $("page-selected").hidden = !selected;
  // One back arrow: to the settings from the selected line, else the
  // arrow of the settings (it hides at their first column).
  $("selected-back").hidden = !selected;
  $("crumb-back").hidden = selected;
  $("crumbs").hidden = selected;
  $("panel-title").hidden = !selected;
  updateFocus();
}
$("selected-back").onclick = () => showTab("settings");

// The history popover: open (true), closed (false), or the other state.
function toggleHistory(open) {
  const pop = $("history-pop");
  const show = open ?? pop.hidden;
  pop.hidden = !show;
  if (show) history.refresh();
}
document.addEventListener("pointerdown", (e) => {
  const pop = $("history-pop");
  if (pop.hidden || pop.contains(e.target) || $("timeline").contains(e.target)) return;
  pop.hidden = true;
});

// The Printers page over the view: the tiles read the printers only while
// it shows.
function showFarm(show) {
  $("farm-view").hidden = !show;
  // The page has the width of the window.
  if (show && panelMode() === "overlay") setPanelMode("hidden");
  $("printers-page").setAttribute("aria-pressed", String(show));
  if (show) farm.start();
  else farm.stop();
}
$("printers-page").onclick = () => showFarm($("farm-view").hidden);
$("farm-back").onclick = () => showFarm(false);
$("project-close").onclick = () => $("project-dialog").close();

// ---- the 2D and the 3D view ----

// Shows the 2D layer view or the 3D view (the toggle of preview.c).
function showPage(page) {
  if (app.page === page) return;
  app.page = page;
  store.view = page;
  saveStore();
  $("view-2d").classList.toggle("checked", page === "2d");
  $("view-3d").classList.toggle("checked", page === "3d");
  requestFrame();
}
$("view-2d").disabled = false;
$("view-2d").title = "2D: one layer from the top. A drag pans, the wheel zooms, a double click fits the part.";
$("view-3d").title = "3D: the layers up to the slider. A left drag orbits, a middle or right drag pans (two fingers pressed down on a trackpad), scroll or pinch to zoom, double-click to reset.";
$("view-2d").onclick = () => showPage("2d");
$("view-3d").onclick = () => showPage("3d");
$("view-2d").classList.toggle("checked", app.page === "2d");
$("view-3d").classList.toggle("checked", app.page === "3d");

// ---- the selection ----

// Selects segment `seg` of path `path` (-1: none). `picked`: a click on
// the line, so the Selected page shows (inspector.c, on_picked).
function select(path, seg, picked) {
  app.sel = path;
  app.seg = path >= 0 ? seg : -1;
  view.highlight(path, app.seg, app.isolate);
  requestFrame();
  if (picked && path >= 0) {
    // The card of the line opens at the click; a panel that shows also
    // turns to the Selected page.
    lineCard.openAt(...(app.pickPoint ?? [120, 120]));
    if (panelMode() !== "hidden") showTab("selected");
  }
  if (path < 0) lineCard.close();
  inspect();
}

// Asks the worker for the Selected page of the selection. Only the last
// answer counts.
let inspectId = 0;
async function inspect(refind) {
  const id = ++inspectId;
  if (app.sel < 0 && !refind) {
    app.info = null;
    inspector.show(null);
    return;
  }
  const r = await client.call("inspect", { path: app.sel, seg: app.seg, refind });
  if (id !== inspectId) return;
  lineCard.show(r.info);
  app.info = r.info;
  if (refind) {
    // The same line in the new slice, or none.
    const path = r.info ? r.info.path : -1;
    app.sel = path;
    if (path < 0) app.seg = -1;
    else app.seg = Math.min(app.seg, view.pathSegments(path) - 1);
    view.highlight(app.sel, app.seg, app.isolate);
    requestFrame();
  }
  inspector.show(r.info);
}

// The place of the selection, to find it again after a new slice.
function refindKey() {
  const info = app.info;
  if (app.sel < 0 || !info) return null;
  view.pathBeads(app.sel, rangeTmp);
  const b = rangeTmp[1] > rangeTmp[0] ? rangeTmp[0] + ((rangeTmp[1] - rangeTmp[0]) >> 1) : -1;
  if (b < 0) return null;
  return { layer: info.layer, feature: info.feature, ...view.beadPoint(b) };
}
const rangeTmp = new Uint32Array(2);

// "Fade the others" of the line card: the selected line solid, and the
// other lines as faint ghosts. The choice stays in the store.
function toggleIsolate() {
  app.isolate = !app.isolate;
  store.isolate = app.isolate;
  saveStore();
  lineCard.setIsolate(app.isolate);
  view.highlight(app.sel, app.seg, app.isolate);
  requestFrame();
}

// The top layer goes to the layer of the selection, so the 2D view shows
// it and the 3D view does not hide it (preview.c, show_layer).
function showLayer(layer) {
  if (layer === layers.hi) return;
  layers.set(Math.min(layers.lo, layer), layer, true);
  stopReplay();
  view.setLayerRange(layers.lo, layers.hi);
  showScrub(layers.hi, null);
  updateFocus();
  requestFrame();
}

// ---- the keys of the preview (preview.c, on_preview_key) ----
//
// With a selected line: h and l (or Left and Right) step a segment along
// the print, and Shift steps a whole line; k and j (or Up and Down) go to
// the nearest line on the layer above or below; Escape clears the
// selection. With no selection: Left and Right move the nozzle through
// the top layer, and Up and Down move the top layer (Shift: the bottom
// layer). Page Up and Page Down move 10 layers. C: the preview to the
// layer of the line; Shift+C: all layers. The Menu key or Shift+F10: the
// context menu.

// The move of the nozzle from one segment to the next (h and l): from
// print time `from` to `to`, in `dur` seconds.
const step = { active: false, valid: false, from: 0, to: 0, now: 0, dur: 0, t0: 0 };

function stopStep() {
  step.active = false;
  step.valid = false;
}

function animateStep(now) {
  if (!step.t0) step.t0 = now;
  const f = step.dur > 0 ? Math.min(1, Math.max(0, (now - step.t0) / 1000 / step.dur)) : 1;
  // Linear in print time, so a fast travel looks fast and a slow wall
  // slow, as on the printer.
  step.now = step.from + (step.to - step.from) * f;
  view.setTime(step.now);
  app.time = step.now;
  if (f >= 1) step.active = false;
  return step.active;
}

function startStep(oldPath, oldSeg, path, seg) {
  const to = view.segmentEndTime(path, seg);
  const from = step.valid ? step.now : view.segmentEndTime(oldPath, oldSeg);
  stopReplay();
  showPage("3d");
  step.from = from;
  step.to = to;
  step.now = from;
  step.valid = true;
  // Half the print time, from 0.12 s to 0.6 s: a key held down gives a
  // quick move.
  step.dur = Math.min(0.6, Math.max(0.12, Math.abs(to - from) * 0.5));
  step.t0 = 0;
  step.active = true;
  view.setTime(from);
  requestFrame();
}

function cutToSelection() {
  if (app.sel >= 0) showLayer(view.pathLayer(app.sel));
}

function showAllLayers() {
  if (layers.count === 0) return;
  layers.set(0, layers.count - 1, true);
  stopReplay();
  stopStep();
  app.time = 0;
  view.setLayerRange(layers.lo, layers.hi);
  showScrub(layers.hi, null);
  updateFocus();
  requestFrame();
}

function isCut() {
  return layers.count > 0 && (layers.lo > 0 || layers.hi + 1 < layers.count);
}

// The keys of a selected part, and Tab through the parts: before the keys
// of the layers. Returns true if the key was for a part.
function partKey(e) {
  if (e.ctrlKey || e.metaKey || e.altKey) return false;
  const t = e.target;
  if (t?.closest?.("input, textarea, select, [contenteditable], .panel, .search-layer, .keys-layer")) return false;
  if (e.key === "Tab" && (t === document.body || t === canvas || t?.closest?.(".part-card"))) {
    if (!view.loaded && app.state === "empty") return false;
    e.preventDefault();
    const index = tools.part ? tools.part.index : -1;
    client.call("partStep", { index, dir: e.shiftKey ? -1 : 1 }).then((r) => {
      if (!r.part) return;
      if (tools.tool !== "move") tools.set("move");
      tools.selectPart(r.part);
    });
    return true;
  }
  if ((e.key === "r" || e.key === "R") && !e.shiftKey) {
    tools.set("turn");
    e.preventDefault();
    return true;
  }
  const part = tools.part;
  if (!part) return false;
  // The Turn tool: Page Up and Page Down tilt the part about Y.
  if (tools.tool === "turn" && (e.key === "PageUp" || e.key === "PageDown")) {
    e.preventDefault();
    e.stopPropagation();
    const deg = (e.shiftKey ? 5 : 15) * (e.key === "PageUp" ? 1 : -1);
    client.call("partTurn", { index: part.index, axis: 1, degrees: deg, hold: true }).then((r) => r.part && tools.selectPart(r.part));
    sliceAfterKeys(true);
    return true;
  }
  const dirs = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, 1], ArrowDown: [0, -1] };
  const d = dirs[e.key];
  if (!d) return false;
  e.preventDefault();
  e.stopPropagation();
  // The Turn tool: Left and Right turn the part on the bed (about Z), Up
  // and Down tilt it about X (Page Up and Page Down: about Y); Shift: 5°
  // in place of 15°.
  if (tools.tool === "turn") {
    const deg = e.shiftKey ? 5 : 15;
    const axis = d[0] !== 0 ? 2 : 0;
    const sign = d[0] !== 0 ? -d[0] : d[1];
    client.call("partTurn", { index: part.index, axis, degrees: sign * deg, hold: true }).then((r) => r.part && tools.selectPart(r.part));
    sliceAfterKeys(true);
    return true;
  }
  const step = e.shiftKey ? 10 : 1;
  const x = part.x + d[0] * step;
  const y = part.y + d[1] * step;
  tools.selectPart({ ...part, x, y });
  client.call("partMove", { index: part.index, x, y, hold: true }).then((r) => r.part && tools.selectPart(r.part));
  sliceAfterKeys();
  return true;
}

function onPreviewKey(e) {
  // The Support tool: Enter, Backspace, Delete, and Esc for its areas.
  if (tools.tool === "support" && !e.ctrlKey && !e.metaKey && !e.altKey && !e.target?.closest?.("input, textarea, select, [contenteditable], .panel") && supportTool.key(e)) {
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (partKey(e)) return;
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  if (menuOpen() || !view.loaded || layers.count === 0) return;
  const t = e.target;
  if (t && (t.closest?.("input, textarea, select, [contenteditable]") || t.closest?.(".panel"))) return;
  let dir = 0;
  let layerDir = 0;
  let jump = 1;
  switch (e.key) {
    case "ArrowLeft": case "h": dir = -1; break;
    case "ArrowRight": case "l": dir = 1; break;
    case "H": dir = -1; break;
    case "L": dir = 1; break;
    case "ArrowUp": case "k": case "K": layerDir = 1; break;
    case "ArrowDown": case "j": case "J": layerDir = -1; break;
    case "PageUp": layerDir = 1; jump = 10; break;
    case "PageDown": layerDir = -1; jump = 10; break;
    case "ContextMenu": {
      const r = canvas.getBoundingClientRect();
      showContextMenu(r.left + r.width / 2, r.top + r.height / 2);
      e.preventDefault();
      return;
    }
    case "F10":
      if (!e.shiftKey) return;
      showContextMenu(canvas.getBoundingClientRect().left + canvas.clientWidth / 2, canvas.getBoundingClientRect().top + canvas.clientHeight / 2);
      e.preventDefault();
      return;
    case "s": case "S": tools.set("select"); e.preventDefault(); return;
    case "m": case "M": tools.set("move"); e.preventDefault(); return;
    case "t": case "T": tools.set("measure"); e.preventDefault(); return;
    case "u": case "U": tools.set("support"); e.preventDefault(); return;
    case "g": case "G": if (!$("gaps").disabled) $("gaps").click(); e.preventDefault(); return;
    case "c": case "C":
      if (e.key === "C" || e.shiftKey) showAllLayers();
      else if (app.sel >= 0) cutToSelection();
      else return;
      e.preventDefault();
      return;
    case "Escape":
      if (tools.part) {
        tools.selectPart(null);
        e.preventDefault();
        return;
      }
      if (tools.pts.length > 0) {
        tools.clear();
        e.preventDefault();
        return;
      }
      if (app.sel < 0) return;
      select(-1, -1, false);
      e.preventDefault();
      return;
    default: return;
  }
  e.preventDefault();
  e.stopPropagation();
  let sel = app.sel;
  // h and l go on from what the view shows: the segment at the time of a
  // replay, a scrub, or a step, or the end of the top layer when the
  // selected line is on another layer.
  if (dir !== 0 && !step.valid) {
    let found = false;
    if (app.time > 0 && view.segmentAtTime(app.time)) found = true;
    else if (sel < 0 || view.pathLayer(sel) > layers.hi) found = view.segmentAtTime(layerTimes(layers.hi)[1]);
    if (found) {
      sel = view.hit[0];
      app.sel = sel;
      app.seg = view.hit[1];
      app.time = 0;
    }
  }
  if (sel >= 0) {
    if (dir !== 0) {
      // One segment at a time, in print order. Shift: a whole line.
      const oldPath = sel;
      const oldSeg = Math.max(0, app.seg);
      if (!view.step(sel, app.seg, dir, e.shiftKey)) return;
      const path = view.hit[0];
      const seg = view.hit[1];
      select(path, seg, false);
      showLayer(view.pathLayer(path));
      startStep(oldPath, oldSeg, path, Math.max(0, seg));
      return;
    }
    // Up or down: the nearest line, `jump` layers away (a layer with no
    // lines is passed).
    const layer = view.pathLayer(sel);
    let target = Math.min(layers.count - 1, Math.max(0, layer + layerDir * jump));
    while (target !== layer) {
      const hit = view.nearestOnLayer(sel, target);
      if (hit >= 0) {
        stopStep();
        select(hit, -1, false);
        showLayer(target);
        return;
      }
      target += layerDir;
      if (target < 0 || target >= layers.count) break;
    }
    return;
  }
  // No selection: Left and Right move the nozzle through the top layer
  // (2 % of the layer a step), the other keys move the layers.
  if (dir !== 0) {
    const r = $("scrub-range");
    r.value = String(Math.min(1, Math.max(0, Number(r.value) + dir * 0.02)));
    r.dispatchEvent(new Event("input"));
    return;
  }
  let lo = layers.lo;
  let hi = layers.hi;
  const n = layers.count;
  if (e.shiftKey) {
    lo = Math.min(n - 1, Math.max(0, lo + layerDir * jump));
    if (hi < lo) hi = lo;
  } else {
    hi = Math.min(n - 1, Math.max(0, hi + layerDir * jump));
    if (lo > hi) lo = hi;
  }
  layers.set(lo, hi);
}
// Before the knobs of the slider see the keys, as the capture phase of
// the GTK preview.
document.addEventListener("keydown", onPreviewKey, true);

// ---- the context menu (context-menu.js has its entries) ----

function showContextMenu(x, y) {
  // The place of the click, for "Add a drop of plastic here".
  app.menuAt = [x, y];
  const items = contextItems({
    onLine: app.sel >= 0,
    marks: app.marks > 0,
    cut: isCut(),
    run: runMenu,
  });
  openMenuAt(x, y, items, () => canvas.focus({ preventScroll: true }));
}

async function runMenu(act, arg) {
  const path = app.sel;
  const seg = app.seg;
  switch (act) {
    case "cutToLayer": cutToSelection(); break;
    case "addSupport": await client.call("markAdd", { path, seg, kind: arg }); break;
    case "removeMarks": await client.call("markRemoveNear", { path, seg }); break;
    case "copyForAi": await copyForAi(); break;
    case "putDown": await client.call("putDown", { path, seg }); break;
    case "place": await client.call("place", { path, code: arg }); break;
    case "plate": await client.call("plate", { action: arg }); break;
    case "addModels": addModels(); break;
    case "clearMarks": await client.call("marksClear"); break;
    case "allLayers": showAllLayers(); break;
    case "debugPrint": await debugPrint(arg === 1); break;
    case "drop": await dropHere(); break;
    case "resetView":
      if (app.page === "2d") view2d.fit(canvas.width, canvas.height);
      else view.resetSmooth();
      requestFrame();
      break;
  }
}

// "Copy for AI": a report of the selected line, to paste into an AI chat
// (view3d.c, on_copy_for_ai). The G-code stays in the page; Export
// G-code saves it.
async function copyForAi() {
  if (app.sel < 0) return;
  const r = await client.call("report", { path: app.sel });
  if (!r.text) {
    toast("No report: slice first.");
    return;
  }
  window.zslice.lastReport = r.text;
  try {
    await navigator.clipboard.writeText(r.text);
    toast("The report of the line is on the clipboard.");
  } catch {
    toast("The browser refused the clipboard.");
  }
}

// ---- the Selected page ----

const inspector = new Inspector($("page-selected"), {
  browser,
  setScoped: async (name, value, zmin, zmax) => {
    const perLayer = browser.byName.get(name)?.perLayer ?? false;
    try {
      const r = await client.call("setScoped", { name, value, zmin, zmax, perLayer });
      applySettings(r);
      return r.error;
    } catch (e) {
      return e.message;
    }
  },
  resetScoped: async (name, zmin, zmax, z) => applySettings(await client.call("resetScoped", { name, zmin, zmax, z })),
  openSetting: (name) => {
    showTab("settings");
    browser.openSetting(name);
  },
  copyForAi,
  markSet: (index, kind, r) => client.call("markSet", { index, kind, r }),
  markRemove: (index) => client.call("markRemove", { index }),
});

// ---- the tools: select, move, measure ----

var tools = new Tools({ // var: drawFrame can run before this line
  partSelected: (part) => partCard?.show(part),
  client, view, canvas, view2d,
  buttons: { select: $("tool-select"), move: $("tool-move"), turn: $("tool-turn"), measure: $("tool-measure"), support: $("tool-support") },
  toolChanged: (tool) => supportTool?.setActive(tool === "support"),
  readout: $("measure-readout"),
  page: () => app.page,
  layer: () => layers.hi,
  layerZ: (l) => app.layers?.z[l] ?? 0,
  select: (path, seg, picked) => select(path, seg, picked),
  requestFrame: () => requestFrame(),
  toast,
});

// ---- the Support tool (support.js) ----

var supportTool = new SupportTool({ // var: tools can call it before this line
  client, view, canvas,
  host: $("preview"),
  page: () => app.page,
  frame: () => requestFrame(),
  focus: () => updateFocus(),
  toast,
});

// ---- gaps ----

const gaps = new Gaps({
  client, view, gl, browser,
  button: $("gaps"),
  count: $("gap-count"),
  page: $("page-selected"),
  layerZ: (l) => app.layers?.z[l] ?? 0,
  // The gap page replaces the Selected page: no line is selected, and the
  // next line builds the page again.
  showPage: () => {
    app.sel = -1;
    app.seg = -1;
    app.info = null;
    view.highlight(-1, -1, false);
    inspector.signature = null;
    showTab("selected");
    requestFrame();
  },
  setSetting: (name, value) => setSetting(name, value),
  setScoped: (name, value, zmin, zmax) => inspector.ctx.setScoped(name, value, zmin, zmax),
  requestFrame: () => requestFrame(),
});

// ---- the history and undo ----

const history = new HistoryPage($("page-history"), {
  client,
  applySettings: (r) => applySettings(r),
  openSetting: (name) => {
    showTab("settings");
    browser.openSetting(name);
  },
  toast,
  visible: () => !$("history-pop").hidden,
  timeline: $("timeline"),
  undoRedo: (op) => undoRedo(op),
  toggle: () => toggleHistory(),
});

// ---- printdeck.yml projects ----

var project = new ProjectPage( // var: the plate labels can ask before this line
  $("page-project"), {
  statusChanged: () => updatePlateLabels(),
  client,
  applySettings: (r) => applySettings(r),
  toast,
  loading: () => {
    projectActive = true;
    // A new set of plates: the camera shows them all.
    app.frameAll = true;
  },
  opened: (name) => {
    stopReplay();
    select(-1, -1, false);
    view2d.fitted = false;
    app.modelName = name;
    $("title").textContent = name;
    document.title = `${name} · zslice`;
    $("empty").hidden = true;
    app.state = "ready";
    history.refresh();
  },
  printers: () => Object.keys(store.printers ?? {}),
  // The name of plate i of the set (from the core).
  plateName: (i) => app.plates[i]?.name ?? "",
  activate: (i) => activatePlate(i, true),
  usePrinter: (name) => {
    store.printer = name;
    saveStore();
    updateSummary();
  },
});

// The setting whose editor has the focus, for the history (one step for
// the edits of one setting while its editor keeps the focus).
var focusKey = null; // var: setSetting can run before this line
function sendFocus() {
  const key = document.activeElement?.closest?.("[data-setting]")?.dataset.setting ?? null;
  if (key === focusKey) return;
  focusKey = key;
  client.call("historyFocus", { key });
}
function noteFocus() {
  setTimeout(sendFocus, 0);
}
document.addEventListener("focusin", noteFocus);
document.addEventListener("focusout", noteFocus);

async function undoRedo(op) {
  const r = await client.call(op, {});
  applySettings(r);
  if (!r.ok) toast(op === "undo" ? "Nothing to undo." : "Nothing to redo.");
  history.refresh();
}

// ---- the printability check ----

// The issues of the slice in a list under the Check button (preview.c,
// fill_check). A click on an issue shows its layer and selects its line,
// so the Selected page says what it is.
const ISSUE_ICONS = ["ℹ", "⚠", "⛔"];
async function openCheck() {
  const button = $("check");
  const r = await client.call("checks", {});
  const list = document.createElement("div");
  list.className = "check-list";
  if (!r.issues || r.issues.length === 0) {
    list.append(Object.assign(document.createElement("div"), { className: "dim check-empty", textContent: r.empty }));
  } else {
    for (const is of r.issues) {
      const row = document.createElement("button");
      row.className = `check-row sev${Math.min(is.severity, 2)}`;
      const icon = Object.assign(document.createElement("span"), { className: "check-icon", textContent: ISSUE_ICONS[Math.min(is.severity, 2)] });
      const text = Object.assign(document.createElement("span"), { className: "check-text", textContent: is.text });
      row.append(icon, text);
      row.onclick = () => {
        closeMenu();
        if (is.layer >= layers.count) return;
        showLayer(is.layer);
        gaps.forget();
        if (is.path >= 0) select(is.path, 0, true);
      };
      list.append(row);
    }
  }
  openPopover(button, list);
}
$("check").disabled = false;
$("check").title = "Check the print: overhangs with no support, bridges, shapes in the air, lines over the flow of the hot end, layers that cool too little";
$("check").onclick = () => openCheck();

// ---- the print card ----

function updateSummary() {
  // An empty plate has no print: no card.
  $("summary").classList.toggle("is-empty", app.state === "empty");
  const card = $("summary");
  card.classList.toggle("stale", app.slicing);
  $("export").disabled = app.state !== "done";
  // A printer with a connection: the card prints to it, and the export
  // goes to the menu of the print button (window.c).
  const pr = currentPrinter();
  const linked = !!(pr && pr.kind && pr.kind !== "none" && pr.url);
  $("send-box").hidden = !linked;
  $("export").hidden = linked;
  if (linked) {
    $("send").textContent = sending ? "Sending…" : `Print to ${KINDS[pr.kind] ?? pr.kind}`;
    $("send").title = `Upload the G-code to ${pr.name} and start the print`;
    $("send").disabled = app.state !== "done" || sending;
    $("send-menu").disabled = app.state !== "done" || sending;
  }
  if (app.slicing) return;
  if (app.state !== "done" || !app.stats) {
    $("sum-time").textContent = app.state === "failed" ? "Slice failed" : "—";
    $("sum-detail").textContent = "";
    $("sum-took").textContent = "";
    $("sum-facts").replaceChildren();
    return;
  }
  const st = app.stats;
  $("sum-time").textContent = formatTime(st.printTimeS);
  const perG = Number(value("filament.price_per_kg")) / 1000;
  const perH = Number(value("machine.hour_rate")) || 0;
  const c = st.filamentG * perG + (st.printTimeS / 3600) * perH;
  const cost = c > 0 ? ` · ${c.toFixed(2)}` : "";
  $("sum-detail").textContent = `${st.filamentG.toFixed(1)} g · ${(st.filamentMm / 1000).toFixed(2)} m${cost} · ${st.layerCount} layers`;
  $("sum-took").textContent = app.sliceMs < 1000 ? `Sliced in ${app.sliceMs.toFixed(0)} ms` : `Sliced in ${(app.sliceMs / 1000).toFixed(1)} s`;
  // A part off the bed, or on another part: the printer can hit its frame.
  const warn = $("sum-warn");
  warn.replaceChildren();
  warn.classList.remove("sum-hint");
  warn.hidden = true;
  if (app.fits === false) {
    warn.hidden = false;
    warn.textContent = "A part is off the bed or on another part. Move it, turn it, scale it, or cut it (the part card) before you print.";
  } else if (app.tiny?.length > 0) {
    // A file in inches or in meters: offer the scale.
    const t = app.tiny[0];
    warn.hidden = false;
    warn.classList.add("sum-hint");
    const by = (k, label) => {
      const b = el("button", "", label);
      b.onclick = async () => {
        for (const p of app.tiny) await client.call("partScale", { index: p.index, s: p.scale * k });
      };
      return b;
    };
    warn.append(`${t.name || "The part"} is only ${t.size.toFixed(2)} mm. Was the file in inches or in meters? `, by(25.4, "Inches (×25.4)"), by(1000, "Meters (×1000)"));
  } else if (app.overhang >= OVERHANG_HINT_MM2 && (value("project.support") || "off") === "off") {
    // Support is off, and a large area faces down in the air: the print
    // can fail there. One click turns support on.
    warn.hidden = false;
    warn.classList.add("sum-hint");
    const on = el("button", "", "Turn on support");
    on.onclick = () => setSetting("project.support", "everywhere");
    warn.append(`About ${Math.round(app.overhang)} mm² of the part hangs in the air with no support. It can droop or fail. `, on);
  }
  fillFacts();
}

// The main settings of the print, as small buttons on the print card. A
// click opens the search on that setting, to change it there.
function fillFacts() {
  const box = $("sum-facts");
  const num = (n) => Number(value(n));
  const mm = (v) => `${Number(v.toPrecision(3))} mm`;
  const facts = [];
  const lh = num("project.layer_height");
  const first = num("project.first_layer_height");
  if (lh > 0) facts.push([`${mm(lh)} layers${first > 0 && Math.abs(first - lh) > 1e-6 ? ` (first ${mm(first)})` : ""}`, "layer height", "The layer height, and the height of the first layer"]);
  const walls = num("project.wall_count");
  if (walls > 0) facts.push([`${walls} walls`, "wall count", "The number of walls"]);
  const density = num("project.infill_density");
  facts.push([density > 0 ? `${Math.round(density * 100)} % ${value("project.infill_pattern")}` : "no infill", "infill density", "The infill density and pattern"]);
  const support = value("project.support");
  facts.push([support && support !== "off" ? `support: ${support === "buildplate" ? "on the bed" : support}${value("project.support_style") === "tree" ? ", tree" : ""}` : "no support", "support", "Support under overhangs"]);
  const brim = num("project.brim_width");
  const skirt = num("project.skirt_loops");
  facts.push([brim > 0 ? `brim ${mm(brim)}` : skirt > 0 ? `skirt ${skirt}` : "no skirt", brim > 0 ? "brim width" : "skirt loops", "The brim, or the skirt"]);
  const nozzle = num("filament.nozzle_temp");
  const bed = num("filament.bed_temp");
  if (nozzle > 0) facts.push([`${nozzle} °C${bed > 0 ? ` / bed ${bed} °C` : ""}`, "nozzle temperature", "The temperatures of the nozzle and the bed"]);
  const nd = num("machine.nozzle_diameter");
  if (nd > 0) facts.push([`${mm(nd)} nozzle`, "nozzle diameter", "The diameter of the nozzle (printer settings)"]);
  box.replaceChildren(...facts.map(([text, query, title]) => {
    const b = document.createElement("button");
    b.className = "sum-fact";
    b.textContent = text;
    b.title = `${title}. Click to change it.`;
    b.onclick = () => search.show(query);
    return b;
  }));
}

async function exportGcode() {
  if (app.state !== "done") return;
  if (app.fits === false && !window.confirm("A part is off the bed or on another part. The printer can hit its frame or the other part. Go on?")) return;
  const r = await client.call("gcode", { plate: app.activePlate, plates: app.plates.length });
  if (!r.bytes) {
    toast("No G-code: slice first.");
    return;
  }
  download(await signGcode(new Uint8Array(r.bytes)), `${gcodeFileName(r)}.gcode`, "text/x-gcode");
  await warnUnsigned();
}

// The name of a G-code file (zs_app_gcode_name, from the worker): the
// model, the plate, the layer height, the material, the printer, and the
// time, for example "3DBenchy_0.2mm_PLA_MK4_50m".
function gcodeFileName(r) {
  return r.fileName || (r.name || "part").replace(/\.(stl|3mf)$/i, "");
}
$("export").onclick = exportGcode;

// A drop of plastic at the place of the right click, on the top layer of
// the view (zs_app_edit_add_dot): for a small gap.
async function dropHere() {
  if (app.state !== "done" || !app.menuAt) return;
  const r = canvas.getBoundingClientRect();
  const px = (app.menuAt[0] - r.left) * dpr();
  const py = (app.menuAt[1] - r.top) * dpr();
  const c = wasm.cell;
  if (!view.x.zs_view_surface_point(view.v, px, py, 0, c)) {
    toast("Right-click on the print for a drop.");
    return;
  }
  const x = wasm.f64(c);
  const y = wasm.f64(c + 8);
  const res = await client.call("editDot", { layer: layers.hi, z: app.layers?.z?.[layers.hi], x, y, d: 1.0 });
  toast(res.ok ? `A drop of plastic at ${x.toFixed(1)}, ${y.toFixed(1)} on layer ${layers.hi + 1}. Undo with Ctrl+Z.` : "No drop: slice first.");
}

// A test print (zs_app_debug_gcode): the top layer of the view, or the
// layers that show, alone and lowered onto the bed, to check them before
// a long print.
async function debugPrint(topOnly) {
  if (app.state !== "done") return;
  const hi = layers.hi;
  const lo = topOnly ? hi : layers.lo;
  const r = await client.call("debugGcode", { lo, hi: hi + 1 });
  if (!r.bytes) {
    toast("No G-code: slice first.");
    return;
  }
  const base = (r.name || "part").replace(/\.(stl|3mf)$/i, "");
  const what = lo === hi ? `layer-${hi + 1}` : `layers-${lo + 1}-${hi + 1}`;
  download(await signGcode(new Uint8Array(r.bytes)), `${base}-test-${what}.gcode`, "text/x-gcode");
  toast(lo === hi ? `A test print of layer ${hi + 1}, on the bed.` : `A test print of layers ${lo + 1} to ${hi + 1}, on the bed.`);
}

// ---- print: send the G-code to the printer ----

// The printer of the user that is in use, with its name, or null.
function currentPrinter() {
  const p = store.printers?.[store.printer];
  return p ? { ...p, name: store.printer } : null;
}

// The key of the signatures: made at the first start (signing.js). A
// browser with no Ed25519 gets the message once, at the first export or
// send.
var signWarned = false;
async function warnUnsigned() {
  if (signWarned || (await canSign())) return;
  signWarned = true;
  toast(NO_SIGNATURES, 12000);
}
canSign();

var sending = false; // var: updateSummary can run before this line
async function sendGcode(print) {
  const pr = currentPrinter();
  if (!pr || app.state !== "done" || sending) return;
  if (app.fits === false && !window.confirm("A part is off the bed or on another part. The printer can hit its frame or the other part. Go on?")) return;
  const r = await client.call("gcode", { plate: app.activePlate, plates: app.plates.length });
  if (!r.bytes) {
    toast("No G-code: slice first.");
    return;
  }
  const base = gcodeFileName(r);
  sending = true;
  updateSummary();
  try {
    const res = await sendToPrinter(pr, `${base}.gcode`, new Uint8Array(r.bytes), print);
    toast(res.message);
    await warnUnsigned();
    if (res.ok && print) project.sent();
  } finally {
    sending = false;
    updateSummary();
  }
}
$("send").onclick = () => sendGcode(true);

// The Printers page: the printers of the user, and a send of the plate to
// any of them (farm.js).
var farm = new FarmPage({
  root: $("page-farm"),
  printers: () => store.printers ?? {},
  canSend: () => app.state === "done",
  plateName: () => app.plates[app.activePlate]?.name || app.modelName || "the plate",
  slicedFor: () => store.printer ?? "",
  plates: () => app.plates,
  plateTotals: async () => (await client.call("plateTotals", {})).totals ?? [],
  formatTime: (s) => formatTime(s),
  sendPlate: async (i, pr) => {
    const r = await client.call("plateGcode", { index: i });
    if (!r.bytes) return { ok: false, message: "No G-code: the plate has no slice yet." };
    const base = r.fileName || (r.name || `plate-${i + 1}`).replace(/\.(stl|3mf)$/i, "");
    return sendToPrinter(pr, `${base}.gcode`, new Uint8Array(r.bytes), true);
  },
  toast: (t) => toast(t),
  send: async (pr, print) => {
    const r = await client.call("gcode", { plate: app.activePlate, plates: app.plates.length });
    if (!r.bytes) return { ok: false, message: "No G-code: slice first." };
    const res = await sendToPrinter(pr, `${gcodeFileName(r)}.gcode`, new Uint8Array(r.bytes), print);
    if (res.ok && print) project.sent();
    return res;
  },
});
$("send-menu").onclick = () => openMenu($("send-menu"), [
  { label: "Upload only", tip: "Upload the G-code to the printer, and do not start it.", action: () => sendGcode(false) },
  { label: "Export G-code…", action: exportGcode },
]);

// ---- the worker events ----

function onWorkerEvent(m) {
  // The slices of the other plates of the set show only on their labels.
  if ((m.event === "slicing" || m.event === "progress" || m.event === "failed") && m.plate !== undefined && m.plate !== app.activePlate) return;
  switch (m.event) {
    case "plates":
      onPlates(m);
      break;
    case "stale":
      // A new active plate that slices again: its old slice until then.
      if (m.scene) {
        view.readScene(m.scene);
        gl.setOutlines(view.outlines());
      }
      $("empty").hidden = true;
      app.state = "ready";
      app.stats = null;
      updateSummary();
      requestFrame();
      break;
    case "slicing":
      app.slicing = true;
      inspector.setStale(true);
      $("busy").hidden = false;
      $("busy").textContent = "Slicing…";
      $("sum-progress").hidden = false;
      $("sum-progress").firstElementChild.style.width = "0%";
      updateSummary();
      break;
    case "progress":
      $("busy").textContent = `Slicing… ${Math.round(m.progress * 100)} %`;
      $("sum-progress").firstElementChild.style.width = `${(m.progress * 100).toFixed(1)}%`;
      break;
    case "sliced": {
      app.slicing = false;
      // A plate with a slice is not empty (also a plate that became active).
      $("empty").hidden = true;
      inspector.setStale(false);
      $("busy").hidden = true;
      $("sum-progress").hidden = true;
      app.state = "done";
      if (m.ms > 0) app.sliceMs = m.ms;
      app.stats = m.stats;
      app.layers = m.layers;
      app.marks = m.marks;
      supportTool?.setAreas(m.areas);
      app.parts = m.parts;
      app.fits = m.fits !== false;
      app.overhang = 0;
      app.tiny = m.tiny ?? [];
      checkOverhang();
      // The selection, to find it again in the new slice.
      const key = refindKey();
      const first = !view.loaded;
      if (m.scene) {
        view.readScene(m.scene);
        gl.setOutlines(view.outlines());
      }
      if (first) view2d.fitted = false;
      layers.setLayers(m.layers.z.length, m.layers.slowed, m.layers.z);
      if (!replay.playing) view.setLayerRange(layers.lo, layers.hi);
      showScrub(layers.hi, null);
      $("scrub").hidden = false;
      browser.setFeatureStats(m.featureStats);
      showLegend();
      updateFocus();
      updateSummary();
      if (key) inspect(key);
      else if (app.sel >= 0) select(-1, -1, false);
      gaps.refresh(layers.hi, true);
      requestFrame();
      keepSoon();
      break;
    }
    case "history":
      history.refresh();
      break;
    case "cleared":
      // An empty plate: nothing to keep.
      clearTimeout(keepTimer);
      if (app.plates.length <= 1) clearPlate();
      if (m.scene) {
        view.readScene(m.scene);
        gl.setOutlines(view.outlines());
      }
      app.state = "empty";
      app.stats = null;
      layers.setLayers(0, null, null);
      $("scrub").hidden = true;
      $("empty").hidden = false;
      if (app.plates.length <= 1) $("title").textContent = "zslice";
      select(-1, -1, false);
      updateSummary();
      requestFrame();
      break;
    case "failed":
      app.slicing = false;
      $("busy").hidden = true;
      $("sum-progress").hidden = true;
      app.state = m.state === 4 ? "failed" : app.state;
      updateSummary();
      if (m.error) toast(`The slice failed: ${m.error}`);
      break;
    case "crashed":
      toast(`The worker stopped: ${m.error}`);
      break;
  }
}

// ---- the plate set ----
//
// The core keeps one app for each plate (zs_set, in the worker). The view
// of the page shows all plates in a row (src/render/plates.zig): the
// active plate is the full view, and the others are fixed beads. `[` and `]` go to the plate before
// and the next plate, Home shows all plates, and a double click on a plate
// goes to it. A click on another plate makes it active.

const STATUS_TEXT = { empty: "empty", stale: "to slice", slicing: "slicing", done: "", failed: "failed", resin: "Resin: not yet" };

// The list of the plates from the worker, and the changes for the view
// (m.sync: the beds, the clears, the flags, the footprints, and the beads
// of the other plates; see zs_set_view_sync).
function onPlates(m) {
  const before = app.activePlate;
  app.plates = m.plates;
  app.activePlate = m.active;
  showProjectTotals();
  if (app.wantPlate === m.active) app.wantPlate = -1;
  if (m.sync) {
    try {
      view.syncPlates(m.sync);
    } catch (e) {
      toast(e.message);
    }
  }
  if (m.active !== before) {
    // The selection and the tools are of the plate that was active.
    stopReplay();
    select(-1, -1, false);
    tools.clear?.();
    view2d.fitted = false;
  }
  if (app.framePlate === m.active) {
    view.framePlate(m.active);
    app.framePlate = -1;
  }
  if (app.frameAll) {
    view.framePlate(-1);
    app.frameAll = false;
  }
  project.showActive(m.active);
  updatePlateBar();
  requestFrame();
}

// Makes plate i the active plate; with `frame`, the camera goes to it.
async function activatePlate(i, frame) {
  if (i < 0 || i >= app.plates.length) return;
  if (frame) app.framePlate = i;
  if (i === app.activePlate) {
    if (frame) {
      view.framePlate(i);
      app.framePlate = -1;
      requestFrame();
    }
    return;
  }
  if (i === app.wantPlate) return;
  app.wantPlate = i;
  const r = await client.call("plateActivate", { index: i });
  applySettings(r);
  const p = app.plates[r.index];
  const name = p?.name || "zslice";
  app.modelName = p?.name ?? "";
  $("title").textContent = name;
  document.title = `${name} · zslice`;
  history.refresh();
}

async function addPlate() {
  app.framePlate = app.plates.length;
  const r = await client.call("plateAdd");
  applySettings(r);
  $("title").textContent = app.plates[r.index]?.name ?? "zslice";
  history.refresh();
}

// Removes plate i, after a question if it has parts. The plates are not
// in the undo list, so a removal cannot be undone.
async function removePlate(i) {
  const p = app.plates[i];
  if (!p) return;
  if (p.parts > 0 && !confirm(`Remove plate ${i + 1} and its ${p.parts === 1 ? "part" : `${p.parts} parts`}? This cannot be undone.`)) return;
  const r = await client.call("plateRemove", { index: i });
  project.removed(i);
  applySettings(r);
  const q = app.plates[r.index];
  const name = q?.name || "zslice";
  app.modelName = q?.name ?? "";
  $("title").textContent = name;
  document.title = `${name} · zslice`;
  history.refresh();
}

function updatePlateBar() {
  const n = app.plates.length;
  $("plate-name").textContent = `Plate ${app.activePlate + 1} of ${Math.max(n, 1)}`;
  $("plate-prev").disabled = app.activePlate <= 0;
  $("plate-next").disabled = app.activePlate >= n - 1;
  $("plate-all").hidden = n <= 1;
  updatePlateLabels();
}

// The labels over the plates: made again when the list changes, placed
// on each frame.
function updatePlateLabels() {
  const root = $("plate-labels");
  const n = app.plates.length > 1 ? app.plates.length : 0;
  while (root.children.length > n) root.lastChild.remove();
  while (root.children.length < n) {
    const el = document.createElement("div");
    el.className = "plate-label";
    const i = root.children.length;
    el.onclick = () => activatePlate(i, true);
    el.oncontextmenu = (e) => {
      e.preventDefault();
      openMenuAt(e.clientX, e.clientY, [{ label: `Remove plate ${i + 1}`, action: () => removePlate(i) }]);
    };
    root.append(el);
  }
  app.plates.forEach((p, i) => {
    const el = root.children[i];
    if (!el) return;
    el.classList.toggle("active", i === app.activePlate);
    const status = STATUS_TEXT[p.status] ?? p.status;
    el.replaceChildren(`${i + 1}. ${p.name || "Empty plate"}`);
    // The print status of a project plate: a mark at the front.
    const ps = project?.printStatus(i);
    if (ps && ps !== "todo") {
      const m = document.createElement("span");
      m.className = `pl-print pl-${ps}`;
      m.textContent = { printing: "Printing", printed: "✓ Printed", failed: "Failed" }[ps] ?? ps;
      el.prepend(m);
    }
    if (status) {
      const s = document.createElement("span");
      s.className = "pl-status";
      s.textContent = status;
      el.append(s);
    }
    el.title = [p.printer, p.status === "resin" ? "zslice slices FDM plates only, for now." : ""].filter(Boolean).join(" · ");
  });
}

// Places each label over the middle of the back edge of its plate.
function placePlateLabels() {
  const root = $("plate-labels");
  if (root.children.length === 0 || app.page !== "3d") {
    root.hidden = root.children.length === 0 || app.page !== "3d";
    return;
  }
  root.hidden = false;
  const k = dpr();
  app.plates.forEach((p, i) => {
    const el = root.children[i];
    if (!el) return;
    const o = view.plateOrigin(i);
    const q = view.pixelOf(o[0] + (p.bed[0] || 220) / 2, o[1] + (p.bed[1] || 220), 0);
    if (!q) {
      el.style.display = "none";
      return;
    }
    el.style.display = "";
    el.style.left = `${q[0] / k}px`;
    el.style.top = `${q[1] / k}px`;
  });
  // A label that covers one at its left goes up over it.
  const shown = [...root.children].filter((e) => e.style.display !== "none").map((e) => ({ e, r: e.getBoundingClientRect() }));
  shown.sort((a, b) => a.r.left - b.r.left);
  for (let i = 1; i < shown.length; i++) {
    for (let j = 0; j < i; j++) {
      const a = shown[j].r;
      const b = shown[i].r;
      if (b.left < a.right + 4 && b.right > a.left - 4 && b.top < a.bottom + 2 && b.bottom > a.top - 2) {
        const up = b.bottom - a.top + 4;
        shown[i].e.style.top = `${parseFloat(shown[i].e.style.top) - up}px`;
        shown[i].r = shown[i].e.getBoundingClientRect();
      }
    }
  }
}

$("plate-prev").onclick = () => activatePlate(app.activePlate - 1, true);
$("plate-next").onclick = () => activatePlate(app.activePlate + 1, true);
$("plate-all").onclick = () => {
  view.framePlate(-1);
  requestFrame();
};
$("plate-add").onclick = () => addPlate();
$("plate-remove").onclick = () => removePlate(app.activePlate);

// The keys of the plates: [ and ] (the plate before and the next plate,
// framed), F (frame the active plate), and Home (all plates), also with no
// slice.
document.addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey || menuOpen()) return;
  const t = e.target;
  if (t && (t.closest?.("input, textarea, select, [contenteditable]") || t.closest?.(".panel"))) return;
  if (e.key === "[" || e.key === "]") {
    activatePlate(app.activePlate + (e.key === "]" ? 1 : -1), true);
  } else if ((e.key === "f" || e.key === "F") && !e.shiftKey) {
    view.framePlate(app.activePlate);
    requestFrame();
  } else if (e.key === "Home") {
    if (app.plates.length > 1) view.framePlate(-1);
    else view.resetSmooth();
    requestFrame();
  } else return;
  e.preventDefault();
  e.stopPropagation();
}, true);

// ---- the work across a refresh (keep.js) ----

let keepTimer = 0;
function keepSoon() {
  clearTimeout(keepTimer);
  keepTimer = setTimeout(async () => {
    try {
      const r = await client.call("plate3mf");
      if (r.bytes) await savePlate(app.modelName || r.name || "plate", r.bytes);
    } catch {
      // The next slice tries again.
    }
  }, 1500);
}

// ---- open a model ----

// Saves all plates as one project file (zs_set_project_save): a 3MF file
// that zslice opens with its plates, and other slicers as its first plate.
async function saveProject() {
  try {
    const name = (app.plates[0]?.name || app.modelName || "project").replace(/\.(stl|3mf)$/i, "");
    const r = await client.call("projectSave", { name });
    download(new Uint8Array(r.bytes), `${name}.3mf`, "model/3mf");
    toast(app.plates.length > 1 ? `Saved ${app.plates.length} plates in ${name}.3mf.` : `Saved ${name}.3mf.`);
  } catch (e) {
    toast(e.message);
  }
}

// The sums of all plates on the print card (zs_set_totals), with two
// plates or more: the time, the filament, and the cost of the project.
let totalsBusy = false;
async function showProjectTotals() {
  const box = $("sum-project");
  if (app.plates.length < 2) {
    box.hidden = true;
    return;
  }
  if (totalsBusy) return;
  totalsBusy = true;
  try {
    const t = await client.call("totals");
    if (!t || t.plates < 2) {
      box.hidden = true;
      return;
    }
    const cost = t.cost > 0 ? ` · ${t.cost.toFixed(2)}` : "";
    const wait = t.missing > 0 ? ` (${t.missing} ${t.missing === 1 ? "plate slices" : "plates slice"})` : "";
    box.textContent = `All ${t.plates} plates: ${formatTime(t.timeS)} · ${t.filamentG.toFixed(1)} g${cost}${wait}`;
    box.title = `${t.parts} parts on ${t.plates} plates. The cost: the filament ${t.costFilament.toFixed(2)}, the printer time ${t.costMachine.toFixed(2)} (machine.hour_rate).`;
    box.hidden = false;
  } finally {
    totalsBusy = false;
  }
}

async function openFile(file) {
  if (!file) return;
  stopReplay();
  // A project file of zslice: its plates replace the plates.
  if (/\.3mf$/i.test(file.name)) {
    const probe = await file.arrayBuffer();
    if (await client.call("projectFileIs", { bytes: probe })) {
      projectActive = false;
      project.unload();
      try {
        const r = await client.call("projectFileOpen", { bytes: probe }, [probe]);
        applySettings(r);
        select(-1, -1, false);
        $("empty").hidden = true;
        app.state = "ready";
        $("title").textContent = file.name;
        document.title = `${file.name} · zslice`;
        if (r.note) toast(r.note);
        history.refresh();
      } catch (e) {
        toast(e.message);
      }
      return;
    }
  }
  const wasProject = projectActive || project.loaded != null;
  projectActive = false;
  project.unload();
  const bytes = await file.arrayBuffer();
  try {
    // With plates of the user, the file goes on the active plate, and the
    // other plates stay. A project set makes way for the file.
    const keepSet = app.plates.length > 1 && !wasProject;
    await client.call("load", { name: file.name, bytes, keepSet }, [bytes]);
    select(-1, -1, false);
    view2d.fitted = false;
    app.modelName = file.name;
    $("title").textContent = file.name;
    document.title = `${file.name} · zslice`;
    $("empty").hidden = true;
    app.state = "ready";
  } catch (e) {
    toast(e.message);
  }
}

// "Add models…": more parts on the plate (zs_app_add_stl).
async function addFiles(files) {
  for (const file of files) {
    const bytes = await file.arrayBuffer();
    try {
      await client.call("add", { name: file.name, bytes }, [bytes]);
      $("empty").hidden = true;
      if (app.state === "empty") app.state = "ready";
      if (!app.modelName) {
        app.modelName = file.name;
        $("title").textContent = file.name;
      }
    } catch (e) {
      toast(e.message);
    }
  }
}

function addModels() {
  const input = document.createElement("input");
  input.type = "file";
  input.multiple = true;
  input.accept = $("file").accept;
  input.onchange = () => addFiles([...input.files]);
  input.click();
}

$("open").onclick = () => $("file").click();
// + adds models to the active plate; Open replaces the active plate.
$("add").onclick = () => addModels();
$("empty-open").onclick = () => $("file").click();
$("file").onchange = () => {
  openFile($("file").files[0]);
  $("file").value = "";
};

const preview = $("preview");
preview.addEventListener("dragover", (e) => {
  e.preventDefault();
  preview.classList.add("drop");
});
preview.addEventListener("dragleave", () => preview.classList.remove("drop"));
preview.addEventListener("drop", (e) => {
  e.preventDefault();
  preview.classList.remove("drop");
  openFile(e.dataTransfer.files[0]);
});

document.addEventListener("keydown", (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  if (e.key === "o") {
    e.preventDefault();
    $("file").click();
  } else if (e.key === "e") {
    e.preventDefault();
    exportGcode();
  } else if (e.key === "s") {
    e.preventDefault();
    saveProject();
  } else if ((e.key === "z" || e.key === "Z" || e.key === "y") && !e.target.closest("input, textarea, select")) {
    e.preventDefault();
    undoRedo(e.key === "z" && !e.shiftKey ? "undo" : "redo");
  }
});

// ---- the search of settings and actions (/) ----

const search = new SearchOverlay({
  browser,
  infos,
  focus: (mask, first) => {
    app.focusMask = mask;
    app.focusFirst = first;
    updateFocus();
  },
  unfocus: () => (panelMode() === "hidden" ? clearFocus() : browser.sendFocus()),
  actions: () => [
    { label: "Open a model…", keys: "Ctrl+O", run: () => $("file").click() },
    { label: "Add models to the plate…", run: () => addModels() },
    { label: "Export G-code…", keys: "Ctrl+E", run: () => exportGcode() },
    { label: "Test print the top layer", hint: "the layer alone, on the bed", run: () => debugPrint(true) },
    { label: "Test print the layers shown", hint: "the layers of the slider alone, on the bed", run: () => debugPrint(false) },
    { label: "Save the project…", keys: "Ctrl+S", hint: "all plates in one 3MF file", run: () => saveProject() },
    { label: "Print", hint: "send the G-code to the printer and start", run: () => sendGcode(true) },
    { label: "Arrange the plate", hint: "pack the parts on the bed", run: () => client.call("plate", { action: "arrange" }) },
    { label: "Smart placement", hint: "turn and arrange the parts", run: () => client.call("plate", { action: "smart" }) },
    { label: "Remove this plate", hint: "the plate and its parts", run: () => removePlate(app.activePlate) },
    { label: "Check the print", hint: "problems and advice", run: () => openCheck() },
    { label: "Undo", keys: "Ctrl+Z", run: () => undoRedo("undo") },
    { label: "Redo", keys: "Ctrl+Shift+Z", run: () => undoRedo("redo") },
    { label: "2D layer view", run: () => showPage("2d") },
    { label: "3D view", run: () => showPage("3d") },
    { label: "Manage printers…", run: () => managePrinters() },
    { label: "Open a project", hint: "printdeck.yml from GitHub or a folder", run: () => showTab("project") },
    { label: "History", hint: "the changes, undo one change", run: () => showTab("history") },
    { label: "Keyboard shortcuts", keys: "?", run: () => shortcuts.show() },
    { label: "All settings", keys: "N", hint: "the panel of the settings", run: () => showTab("settings") },
    { label: "Printers", hint: "your printers, their jobs, and the plates to print", run: () => showFarm(true) },
  ],
});
const shortcuts = new ShortcutSheet();
$("search-open").onclick = () => search.show();

// Esc closes the search also when the view has the focus (after a turn of
// the view), once the keys of the view (a selection, the tape) are done.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || e.defaultPrevented || !search.open) return;
  if (e.target.closest?.("input:not(.search-input), textarea, select")) return;
  e.preventDefault();
  search.close();
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Delete" && partCard.open && !e.target.closest?.("input, textarea, select, [contenteditable]")) {
    e.preventDefault();
    partCard.act("remove");
    return;
  }
  // A selected line: Delete takes it out of the print (an edit).
  if (e.key === "Delete" && app.sel >= 0 && !partCard.open && !e.target.closest?.("input, textarea, select, [contenteditable]")) {
    e.preventDefault();
    if (lineCard.info) lineCard.ctx.edit(lineCard.info, 0, 1);
    return;
  }
  if (!["/", "?", "n", "N", "d", "D"].includes(e.key) || e.ctrlKey || e.metaKey || e.altKey) return;
  if ((e.key === "d" || e.key === "D") && !partCard.open) return;
  if (e.target.closest?.("input, textarea, select, [contenteditable]")) return;
  e.preventDefault();
  if (e.key === "n" || e.key === "N") {
    togglePanel();
  } else if ((e.key === "d" || e.key === "D") && partCard.open) {
    partCard.act("duplicate");
  } else if (e.key === "?") {
    search.close();
    shortcuts.toggle();
  } else if (search.open) {
    // / again closes the search (it stays open while the view moves).
    search.close();
  } else {
    shortcuts.close();
    search.show();
  }
});

// ---- the worker starts ----

// A printer that serves this page (for example a printdeck on the LAN) can
// put printer.json next to it: { "name", "kind", "url" (empty: this
// server), "profile" (a machine profile text, optional) }. The app adds
// that printer, and uses it when no printer is set up yet.
async function hostPrinter() {
  let p = null;
  try {
    const r = await fetch("printer.json", { cache: "no-store" });
    if (!r.ok) return;
    p = await r.json();
  } catch {
    return;
  }
  if (!p?.name || !KINDS[p.kind]) return;
  store.printers = store.printers ?? {};
  const known = store.printers[p.name];
  store.printers[p.name] = {
    profile: known?.profile ?? p.profile ?? store.saved?.machine ?? "",
    url: p.url || location.origin,
    kind: p.kind,
    apiKey: known?.apiKey ?? p.apiKey ?? "",
    // The https address of a printdeck with a certificate, or "".
    https: p.https || known?.https || "",
  };
  if (!store.printer) store.printer = p.name;
  saveStore();
  // On a deck page over http, offer its secure address. The work of this
  // page stays here: the other address is another site to the browser.
  if (p.https && location.protocol === "http:" && !location.href.startsWith(p.https)) {
    const go = new URL(location.pathname + location.search, p.https).href;
    toast(`This printer has a secure address. Open zslice at ${go} to use it from any page. Your plate here stays here: save it first (Ctrl+S).`, 12000);
  }
}
await hostPrinter();

const init = await client.call("init", { module, saved: store.saved ?? null, mode: app.mode });
if (init.errors?.length) toast(`Some saved settings did not load: ${init.errors.join("; ")}`);
applySettings(init);
history.refresh();
updateSummary();
resize();
// The saved printdeck.yml project: its plan, and its plates again.
project.start();

// The first visit (no printer set up), and the test hook
// ?printers&q=<search>&pick=<model id>&step=2: the printer picker.
const params = new URLSearchParams(location.search);
if (params.has("printers") || (!store.printer && !stateHasChanges(store.saved?.machine) && !params.has("model"))) {
  showPrinterPicker({ query: params.get("q"), model: params.get("pick"), step: params.get("step"), welcome: !params.has("printers") });
}

// The plate of the last visit (keep.js), when the page has no model to
// open: the work goes on after a refresh.
const modelUrl = new URLSearchParams(location.search).get("model");
if (!modelUrl) {
  // The plates of a saved project come back instead (project.start).
  const kept = project.willRestore() ? null : await loadPlate();
  if (kept?.bytes) {
    await openFile(new File([kept.bytes], "plate.3mf"));
    if (app.state !== "empty" && kept.name) {
      app.modelName = kept.name;
      $("title").textContent = kept.name;
      document.title = `${kept.name} · zslice`;
    }
  }
}

// A test hook: ?model=<url> opens a model at the start.
if (modelUrl) {
  const r = await fetch(modelUrl);
  const name = decodeURIComponent(modelUrl.split("/").pop() || "model.stl");
  const data = await r.arrayBuffer();
  await openFile(new File([data], name));
  // &copies=n: n parts on the plate (a test of a full plate).
  const copies = Number(new URLSearchParams(location.search).get("copies") ?? 1);
  const more = [];
  for (let i = 1; i < copies; i++) more.push(new File([data], name));
  if (more.length) await addFiles(more);
}

// For tests: frame times. Each of n frames gets the input of a drag
// (orbit, pan, zoom) or a move of the slider, as the events give it, and
// the frame loop draws it. Returns the CPU time of each draw (ms) and the
// time from one frame to the next: p50, p95, and max.
async function bench(kind, n = 120) {
  const gap = new Float64Array(n - 1);
  const w = canvas.width;
  const h = canvas.height;
  const start = frameCount;
  let last = 0;
  for (let i = 0; i < n; i++) {
    const twoD = app.page === "2d";
    if (kind === "orbit") {
      if (twoD) view2d.pan(3, 1);
      else view.orbit(3, 1);
    } else if (kind === "pan") {
      if (twoD) view2d.pan(4, 2);
      else view.pan(4, 2);
    } else if (kind === "zoom") {
      const f = i < n / 2 ? 0.97 : 1 / 0.97;
      if (twoD) view2d.zoomAt(1 / f, w / 2, h / 2, h);
      else view.zoomAt(f, w / 2, h / 2);
    } else if (kind === "slider") {
      layers.set(layers.lo, (i * 3) % layers.count);
    }
    requestFrame();
    // This callback runs after drawFrame in the same frame.
    const now = await new Promise((r) => requestAnimationFrame(r));
    if (last) gap[i - 1] = now - last;
    last = now;
  }
  const drawn = Math.min(frameCount - start, frameTimes.length);
  const draw = new Float64Array(drawn);
  for (let i = 0; i < drawn; i++) draw[i] = frameTimes[(frameCount - 1 - i) % frameTimes.length];
  const stat = (a) => {
    const s = Float64Array.from(a).sort();
    return { p50: +s[s.length >> 1].toFixed(2), p95: +s[Math.floor(s.length * 0.95)].toFixed(2), max: +s[s.length - 1].toFixed(2) };
  };
  return { kind, page: app.page, frames: n, draw: stat(draw), gap: stat(gap) };
}

// For tests: the time of picks over a grid of pixels (ms).
function benchPick(step = 40) {
  const t = [];
  let hits = 0;
  for (let y = step; y < canvas.height; y += step) {
    for (let x = step; x < canvas.width; x += step) {
      const t0 = performance.now();
      if (hitAt(x, y)) hits++;
      t.push(performance.now() - t0);
    }
  }
  t.sort((a, b) => a - b);
  return { page: app.page, picks: t.length, hits, p50: +t[t.length >> 1].toFixed(3), p95: +t[Math.floor(t.length * 0.95)].toFixed(3), max: +t[t.length - 1].toFixed(3) };
}

// For tests: the state of the page.
window.zslice = {
  project,
  search,
  shortcuts,
  partCard,
  turnRings,
  supportTool,
  app, view, view2d, layers, browser, client, gl, inspector, gaps, history, undoRedo, tools, store, managePrinters, openPrinterSettings, loadProfile, setSetting, pickAt, topLayerPoint, openCheck, frameTimes,
  select, showPage, showTab, hitAt, showContextMenu, step, bench, benchPick,
  get frameCount() { return frameCount; },
  get pickMs() { return pickMs; },
  requestFrame,
  drawNow: () => drawFrame(performance.now()),
};
