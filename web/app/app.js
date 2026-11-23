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
// The parts of the window have modules of their own: input.js (the mouse
// and the touch over the view), tools.js, turn.js, support.js, partcard.js,
// linecard.js, settings.js, search.js, history.js, farm.js, and more (see
// the imports). This file joins them. Its sections, in order:
//   - the saved state
//   - small helpers
//   - start
//   - the 3D view
//   - the panel: a drawer (docs/internals/one-view.md)
//   - the splitter: the width of the panel, kept in the store
//   - the size of the view, and a pick in it
//   - the layer slider and the replay
//   - the colors
//   - the settings
//   - the turn of a part, and the cards of a part and a line
//   - the settings: the answer of the worker, and the bed
//   - the header menus
//   - the panel and the pages
//   - the 2D and the 3D view
//   - the selection
//   - the keys of the preview (preview.c, on_preview_key)
//   - the keys of the window
//   - the context menu (context-menu.js has its entries)
//   - the Selected page
//   - the tools: select, move, measure
//   - the Support tool (support.js)
//   - the mouse, the touch screen, and the wheel over the view
//   - gaps
//   - the history and undo
//   - printdeck.yml projects
//   - the printability check
//   - the print card
//   - print: send the G-code to the printer
//   - the worker events
//   - the plate set
//   - the work across a refresh (keep.js)
//   - open a model
//   - the search of settings and actions (/)
//   - the worker starts
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// theme.js first: it sets the colors before the rest of the page loads.
import { isDark, onThemeChange, themeChoice, setTheme } from "./theme.js";
import { Wasm } from "./wasm.js";
import { LINK, LinkRules, downloadModel, registerLinks } from "./openlink.js";
import { ImportRules, askImportPage, showImportList } from "./modelimport.js";
import { savePlate, loadPlate, clearPlate, loadSession } from "./keep.js";
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
import { RangeCard } from "./rangecard.js";
import { FilamentList, setFilaments, filamentStats, filaments, followFilaments } from "./filaments.js";
import { PaintTool } from "./paint.js";
import { LabelTool } from "./label.js";
import { LabelCard } from "./labelcard.js";
import { Gizmo } from "./gizmo.js";
import { SelectionModel, FRAME_ALL } from "./selection.js";
import { attachViewInput } from "./input.js";
import { FarmPage } from "./farm.js";
import { Tools } from "./tools.js";
import { SupportTool } from "./support.js";
import { KINDS, send as sendToPrinter, test as testPrinter, requestKey, trustText, status as printerStatus, camera as printerCamera, detectKind, deckPrinters, deckAddress, deckRoot, plainName, loadedFilaments, webAddress, nozzleOfCode } from "./link.js";
import { CameraView } from "./camera.js";
import { signGcode, keyId as signingKeyId, supported as canSign, UNSUPPORTED as NO_SIGNATURES } from "./signing.js";
import { contextItems } from "./context-menu.js";
import { Clipboard } from "./clipboard.js";
import { openMenu, openMenuAt, menuOpen, openPopover, closeMenu } from "./menus.js";
import { formatClock, formatTime, useCore } from "./format.js";
import { drawSigns, signLines } from "./signs.js";
import { openPrinterPicker, bedFiles, findModel } from "./printers.js";

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
  // Preferences: the first view ("2d", "3d"), or the last view ("last").
  page: (store.firstView === "2d" || store.firstView === "3d") ? store.firstView : store.view === "2d" ? "2d" : "3d",
  // The info of the selected line from the worker (the Selected page).
  // The line itself is in the selection model (app.sel, app.seg below).
  info: null,
  isolate: store.isolate ?? false,
  marks: 0,
  parts: 0,
  // The print time that the 3D view shows (a replay, a scrub, or a step
  // of h and l), or 0 for whole layers.
  time: 0,
  // The plate set (zs_set in the worker): the list from the worker ({ id,
  // name, status, bed, model, printer, parts, message }), and the plate
  // that the worker reported last. The selection model has the active
  // plate (app.activePlate below).
  plates: [],
  shownPlate: 0,
  // The next new plate gets the camera.
  frameAdded: false,
};

const client = new Client(onWorkerEvent);

// The one record of the selection and the focus (selection.js). These
// properties read it, so no other copy exists.
const selection = new SelectionModel(wasm);
client.sel = selection;
Object.defineProperties(app, {
  activePlate: { get: () => selection.plate },
  sel: {
    get: () => selection.line().path,
    set: (path) => {
      const l = selection.line();
      selection.setLine(path === l.path ? l.key : 0n, path, path < 0 ? -1 : l.seg);
    },
  },
  seg: {
    get: () => selection.line().seg,
    set: (seg) => {
      const l = selection.line();
      if (l.path >= 0) selection.setLine(l.key, l.path, seg);
    },
  },
});

// ---- the 3D view ----

const canvas = $("gl");
const gl = new GlRenderer(canvas);
const view = new View3D(wasm, 16, 16);

// The view follows the theme (theme.js): the background, the grid, and
// the bed of the 3D view (zs_view_set_dark) and of the 2D view.
{
  const apply = (on) => {
    view.x.zs_view_set_dark(view.v, on ? 1 : 0);
    gl.dark = on;
  };
  apply(isDark());
  // A change later draws a frame (the first frame comes after the start).
  onThemeChange((on) => {
    apply(on);
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
  // A new scene in steps: one step in each frame.
  const staging = stageStep();
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
  gizmo?.place();
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
  labelTool?.place();
  if (rangeCard?.open) rangeCard.place();
  placeOpenButton();
  frameTimes[frameCount++ % frameTimes.length] = performance.now() - t0;
  if (more || staging) requestFrame();
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

// ---- the size of the view, and a pick in it ----

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

const dpr = () => window.devicePixelRatio || 1;

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
  const hit = hitAt(px, py);
  // The Select tool in 3D: a click on a support line selects that
  // support (support.js, selectAt), and not the line.
  if (hit && picked && app.page === "3d" && tools.tool === "select") {
    const f = view.x.zs_view_path_feature(view.v, view.hit[0]);
    if (f === 6 || f === 7) {
      const [path, seg] = view.hit;
      select(-1, -1, false);
      supportTool.selectAt(path, seg);
      return;
    }
  }
  supportTool?.clearLite();
  if (hit) select(view.hit[0], view.hit[1], picked);
  else select(-1, -1, false);
}

// Shift+click in the Select tool: the line there and its whole run, from
// the retraction before it to the next one (one extrusion), lit together.
async function pickRun(px, py) {
  app.pickPoint = [px / dpr(), py / dpr()];
  if (!hitAt(px, py)) {
    select(-1, -1, false);
    return;
  }
  const [path, seg] = view.hit;
  select(path, seg, true);
  const r = await client.call("pathRun", { path });
  if (!r.run || app.sel !== path) return;
  const others = [];
  for (let k = r.run[0]; k <= r.run[1] && others.length < 20000; k++) if (k !== path) others.push(k);
  view.highlightMore(others);
  app.run = r.run;
  requestFrame();
  toast(r.run[1] > r.run[0] ? `A run of ${r.run[1] - r.run[0] + 1} lines: one extrusion, from a retraction to the next.` : "A run of one line: it has a retraction before and after it.");
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
  // The next play starts at this top layer, not where the last play
  // stopped.
  replay.t = 0;
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

$("colors").title = `The colors of the lines: ${MODES[app.mode]}`;
$("colors").onclick = () => openMenu($("colors"), [...MODES.map((m, i) => ({
  label: m,
  checked: i === app.mode,
  action: () => {
    app.mode = i;
    store.mode = i;
    saveStore();
    $("colors").title = `The colors of the lines: ${m}`;
    // A color mode is for the 3D view.
    showPage("3d");
    client.call("mode", { value: i });
  },
})), { sep: true }, {
  // The simulated plastic shows after each slice: the plan is one click
  // away.
  label: app.simulated ? "Show the plan" : "Show the print as it forms",
  action: () => toggleSimulation(),
}]);

// The print as it forms: the core simulates the plastic of the slice (it
// falls where nothing holds it, sags, cools, and sets), and the view shows
// it in place of the planned lines. A new slice shows the plan again.
async function toggleSimulation() {
  const on = !app.simulated;
  if (on && !app.simResult) toast("Simulating the plastic of the print…", 30000);
  const r = await client.call("simulate", { on });
  if (r.error) {
    toast(r.error);
    return;
  }
  if (on && r.stats) {
    const s = r.stats;
    const fresh = !app.simResult;
    app.simResult = s;
    updateSummary();
    if (fresh) toast(s.moved > 0 ? `The plastic of ${s.movedPaths} lines does not stay where it prints: up to ${s.maxMove.toFixed(1)} mm off. Turn on support, or change the turn of the part.` : "All the plastic stays where it prints.", 8000);
  }
}

// The words of the Check for the simulated print: where it fails, or how
// far it droops. Null if the plastic stays where it prints.
function simCheckText(s) {
  const as = s.materialExact ? "" : ` (simulated as ${s.material}: the simulation has no data for this plastic)`;
  if (s.failed > 0 && s.firstFailedLayer >= 0) return `The print fails at layer ${s.firstFailedLayer + 1}: the plastic over air falls${as}. `;
  if (s.maxDrop > 0.5) return `The plastic droops up to ${s.maxDrop.toFixed(1)} mm where nothing holds it${as}. `;
  return null;
}

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
// The issues of the check after each slice: one list for the Check
// button of the tool strip and the badge of the print card, so the two
// always agree.
async function checkOverhang() {
  const plate = app.activePlate;
  try {
    const r = await client.call("checks", {});
    if (app.activePlate !== plate || app.state !== "done") return;
    app.issues = r.issues ?? [];
    // Kinds of checks.zig: 2 overhang, 3 island.
    app.overhang = (value("project.support") || "off") === "off" ? app.issues.filter((i) => (i.kind === 2 || i.kind === 3) && i.severity >= 1).reduce((s, i) => s + (i.value || 0), 0) : 0;
    updateCheckCount();
    updateSummary();
  } catch {
    // No hint.
  }
}

// Faster slicing on or off (the Speed settings).
async function setFasterSlicing(on) {
  sendFocus();
  applySettings(await client.call("speed", { on }));
  work.text();
}

// The Speed section of the settings panel.
function showSpeed() {
  showTab("settings");
  browser.showSpeed();
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
  // The Speed section, and its Faster slicing switch (src/app/speed.zig).
  speed: {
    options: wasm.speedOptions(),
    note: wasm.cstr(wasm.x.zs_speed_switch_note()),
    prefsNote: wasm.cstr(wasm.x.zs_speed_prefs_note()),
    set: (on) => setFasterSlicing(on),
    preferences: () => showPreferences(),
  },
  // A new filament of the plate, for the chips of project.filament
  // (filaments.js): its index, or -1.
  addFilament: async () => {
    const r = await client.call("filamentAdd", {});
    setFilaments(r.list);
    return r.index;
  },
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

// ---- the turn of a part, and the cards of a part and a line ----

// The gizmo of the transform tool on the selected part (gizmo.js): the
// rings turn it, the arrows move and lift it, and a drag of the part
// carries it (tools.js).
var gizmo = new Gizmo({
  host: $("preview"),
  view,
  client,
  frame: () => requestFrame(),
  part: () => (app.page === "3d" ? tools.part : null),
  active: () => tools.tool === "move",
  select: (part) => tools.selectPart(part),
  update: (part) => tools.updatePart(part),
  place: (id, x, y, z) => tools.placePart(id, x, y, z),
  // A click on a handle: the part under the pointer, if it is another.
  clickThrough: (px, py, shift) => {
    const hit = tools.partAt(px, py);
    if (!hit) return;
    if (shift) tools.togglePart(hit);
    else if (hit.id !== selection.primary) tools.selectPart(hit);
  },
  settle: (index, why) => settleSelected(index, why),
  toast: (t) => toast(t),
});

// Physics after a turn or a move: a part that cannot stand falls onto a
// face, unless support holds it; a part in the air with no support falls
// to the bed. The toast says so.
// index: the part (the selected part if none).
// The fall shows in the view: each frame runs the rigid body in the core
// (zs_app_fall_step) and turns the beads of the part to its place
// (zs_view_part_preview). At rest, the core puts the part flush on its new
// face, and the plate slices; the new beads end the preview.
let falling = false;
// why: the words of the toast for the fall (else the words of a part
// that tips over).
async function settleSelected(index = tools.part?.index, why = "") {
  if (index === undefined || index < 0 || falling) return;
  falling = true;
  try {
    await fall(index, why);
  } finally {
    falling = false;
  }
}

async function fall(index, why = "") {
  // A part in the air with no support: the toast says why it falls.
  if (!why) {
    const q = await client.call("partGet", { index });
    if (q.part?.note?.startsWith("Support is off")) why = q.part.note;
  }
  const r = await client.call("fallStart", { index });
  if (!r.started) {
    if (r.held) toast("This part could not stand like that on its own. Support is on, so the support holds it in place.");
    return;
  }
  if (await runFall(index, gizmo.takeLive(index))) {
    toast(why || "The part could not stand like that, and fell over. Turn on support to hold it in place.");
    // The card shows the part where it rests.
    client.call("partGet", { index }).then((q) => q.part && tools.updatePart(q.part));
  }
}

// The frames of a fall: the body steps in the core, and the beads of the
// part follow it. True when the part rests. off: the offset of the part
// from its beads in the view (the end of a drag of the gizmo, before its
// slice), or null; the fall turns it with the part.
async function runFall(index, off = null) {
  let last = performance.now();
  for (;;) {
    const now = await new Promise((res) => requestAnimationFrame(res));
    const f = await client.call("fallStep", { dt: (now - last) / 1000 });
    last = now;
    if (f.none) break;
    // The frame at rest sets no preview: the slice of the new place can
    // load first, and a preview after it would move the new beads by the
    // fall (into the bed).
    if (!f.done) {
      const m = [...f.move];
      if (off) {
        // The move of the turn of the offset: m + R off.
        const [x, y, z, w] = f.q;
        m[0] += (1 - 2 * (y * y + z * z)) * off[0] + 2 * (x * y - z * w) * off[1] + 2 * (x * z + y * w) * off[2];
        m[1] += 2 * (x * y + z * w) * off[0] + (1 - 2 * (x * x + z * z)) * off[1] + 2 * (y * z - x * w) * off[2];
        m[2] += 2 * (x * z - y * w) * off[0] + 2 * (y * z + x * w) * off[1] + (1 - 2 * (x * x + y * y)) * off[2];
      }
      view.x.zs_view_part_preview(view.v, index, f.q[0], f.q[1], f.q[2], f.q[3], f.pivot[0], f.pivot[1], f.pivot[2], m[0], m[1], m[2], 0);
    }
    requestFrame();
    if (f.done) return true;
  }
  return false;
}

// The keys of a part move and turn it at once; the slice waits for a pause
// of 0.6 s in the keys.
// turned: the index of the part that the keys turned. A click away in the
// pause clears the selection, and that part still settles.
let heldKeys = 0;
let keysTurned = new Set();
function sliceAfterKeys(turned = -1) {
  clearTimeout(heldKeys);
  if (turned >= 0) keysTurned.add(turned);
  heldKeys = setTimeout(async () => {
    const parts = keysTurned;
    keysTurned = new Set();
    for (const i of parts) await settleSelected(i);
    client.call("sliceHeld");
  }, 600);
}

// The card of a selected part, next to it in the view (partcard.js).
// The filaments of the plate on the print card (filaments.js).
var filamentList = new FilamentList({ client, applySettings: (r) => applySettings(r), toast: (t) => toast(t), nozzles: () => Number(value("machine.nozzles")) || 1 });

// The Paint tool (P): filaments on the surface of a part (paint.js).
var paintTool = new PaintTool({
  client,
  view,
  gl,
  canvas,
  host: $("preview"),
  button: $("tool-paint"),
  // The selected part, else the first part.
  part: () => (tools.part ? tools.part.index : app.parts > 0 ? 0 : -1),
  partFilament: async (i) => {
    const r = await client.call("partSettings", { index: i });
    const own = r.list?.find(([n]) => n === "project.filament");
    return Number(own ? own[1] : browser.values?.["project.filament"]?.value ?? 1) || 1;
  },
  requestFrame: () => requestFrame(),
  toast: (t) => toast(t),
  addFilament: async () => {
    const r = await client.call("filamentAdd", {});
    setFilaments(r.list);
    return r.index;
  },
});
$("tool-paint").onclick = () => {
  labelTool?.close();
  paintTool.toggle();
};

// The Label tool (E): text and marks on the surface of a part, in a
// filament of their own (label.js, labelcard.js).
var labelTool = new LabelTool({
  client,
  view,
  gl,
  canvas,
  host: $("preview"),
  button: $("tool-label"),
  Card: LabelCard,
  part: () => (tools.part ? tools.part.index : -1),
  partAt: (px, py) => tools.partAt(px, py),
  pixelOf: (p) => tools.pixelOf(p),
  page: () => app.page,
  requestFrame: () => requestFrame(),
  toast: (t) => toast(t),
  addFilament: async () => {
    const r = await client.call("filamentAdd", {});
    setFilaments(r.list);
    return r.index;
  },
  // The tool opens: the paint tool closes, and the part card goes (the
  // label card shows in its place).
  opened: () => {
    paintTool.close();
    if (tools.tool !== "select") tools.set("select");
    tools.selectPart(null);
  },
});
$("tool-label").onclick = () => labelTool.toggle();
$("sum-pop").insertBefore(filamentList.node, $("sum-took"));

var partCard = new PartCard({
  client,
  // A click on a label of the part: the Label tool selects it.
  openLabel: (index, id) => labelTool.open(index, id),
  browser,
  host: $("preview"),
  pixelOf: (p) => tools.pixelOf(p),
  select: (part) => tools.selectPart(part),
  update: (part) => tools.updatePart(part),
  otherParts: () => tools.otherParts(),
  stamp: () => tools.stamp,
  selectReply: (list, stamp) => tools.selectReply(list, stamp),
  search: (text, scope) => search.show(text, scope),
  toast: (t) => toast(t),
  // Moves the part to another plate (-1: a new plate).
  movePart: async (index, to) => client.call("partToPlate", { index, to }),
  // Copies until there are n in all (zs_set_fill).
  fillPart: async (index, n) => client.call("partFill", { index, n }),
  // The physics after an edit of the pose (a fall, or a part in the air).
  settle: (index) => settleSelected(index),
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
  // The box of the selected line on the screen, in CSS pixels.
  lineBox: () => {
    if (app.page !== "3d" || app.sel < 0) return null;
    const c = view.w.cell;
    if (!view.x.zs_view_path_rect(view.v, app.sel, c)) return null;
    const k = window.devicePixelRatio || 1;
    const f = new Float32Array(view.w.u8.buffer, c, 4);
    return [f[0] / k, f[1] / k, f[2] / k, f[3] / k];
  },
  isolate: () => toggleIsolate(),
  isolated: () => app.isolate,
  host: $("preview"),
  // The jump from a setting of the card to the setting in the panel.
  openSetting: (name) => {
    showTab("settings");
    browser.openSetting(name);
  },
  // All settings: the long form of the line in the panel takes the place
  // of the card; the line stays selected.
  more: () => {
    lineCard.close();
    showTab("selected");
    // The focus goes into the panel, so Esc hides it.
    $("selected-back").focus({ preventScroll: true });
  },
  // With the panel on the line, a close of the card keeps the selection
  // (the panel has its data); else it clears it.
  close: () => {
    if (panelMode() !== "hidden" && !$("page-selected").hidden) lineCard.close();
    else select(-1, -1, false);
  },
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
  // The Filament row: a filament for the body of the selected line on
  // its layer (the lines joined to it), as paint of its part
  // (zs_app_paint_body). The body shows in the color at once; the slice
  // follows. The beads of the body on the layers above and below where it
  // goes on come back for the buttons of the card (taken now: the slice
  // numbers the lines again).
  paintLine: async (info, f) => {
    const path = app.sel;
    if (path < 0) return { error: "No line." };
    const layer = view.pathLayer(path);
    const beads = view.connectedBeads(path, layer, layer);
    if (!beads) return { error: "The line has no body." };
    const ext = view.connectedLayers(path) ?? [layer, layer];
    const above = ext[1] > layer ? view.connectedBeads(path, layer + 1, ext[1]) : null;
    const below = ext[0] < layer ? view.connectedBeads(path, ext[0], layer - 1) : null;
    lightLine(path, layer, layer, f);
    const r = await client.call("paintBody", { beads, filament: f });
    return { error: r.error ?? null, lo: ext[0], hi: ext[1], above, below };
  },
  // The same filament on more layers of the body (the beads of paintLine).
  extendLine: async (beads, f) => {
    if (app.sel >= 0) {
      let lo = Infinity;
      let hi = -1;
      for (let k = 1; k < beads.length; k += 9) {
        lo = Math.min(lo, beads[k]);
        hi = Math.max(hi, beads[k]);
      }
      const layer = view.pathLayer(app.sel);
      lightLine(app.sel, Math.min(lo, layer), Math.max(hi, layer), f);
    }
    const r = await client.call("paintBody", { beads, filament: f });
    return r.error ?? null;
  },
  addFilament: () => browser.ctx.addFilament(),
});

// ---- the settings: the answer of the worker, and the bed ----

// A plate of a printdeck.yml project is on the view (project.js): its
// profiles come from the project.
var projectActive = false; // var: applySettings can run before this line

// The answer of the worker to a change: the values, and the state to keep.
function applySettings(r) {
  if (!r?.values) return;
  app.snapshot = r;
  browser.setValues(r);
  for (const f of prefsFollowers ?? []) f();
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
  drawFilamentButton();
  const q = qualityName(app.snapshot?.quality || "custom");
  $("quality-menu").textContent = `${q}${stateHasChanges(store.saved?.project) ? " •" : ""}`;
  $("quality-menu").title = `Quality settings: ${q}. Pick a profile.`;
}

async function loadProfile(group, name, text) {
  // A switch to another printer: the printer before keeps the filament
  // that it used (store.printers[name].filament), for a switch back. A
  // plate of a project has the filament of the project.
  const before = group === 0 && store.printer !== name && !projectActive ? store.printers?.[store.printer] : null;
  if (before && store.saved?.filament !== undefined) {
    before.filament = store.saved.filament;
    before.filamentName = store.filament ?? "";
  }
  const r = await client.call("profile", { group, text });
  if (r.error) {
    toast(`The profile ${name} did not load: ${r.error}`);
    return;
  }
  if (group === 0) {
    const switched = store.printer !== name;
    store.printer = name;
    projectActive = false;
    // The filament that this printer was last used with. A printer with
    // no saved filament keeps the filament now.
    const mine = switched ? store.printers?.[name] : null;
    if (mine?.filament !== undefined) {
      const f = await client.call("profile", { group: 1, text: mine.filament });
      if (f.error) console.warn(`zslice: the filament of ${name} did not load: ${f.error}`);
      else {
        store.filament = mine.filamentName || store.filament;
        saveStore();
        applySettings(f);
        return;
      }
    }
  }
  if (group === 1) store.filament = name;
  saveStore();
  applySettings(r);
}

// A printer of the picker: its machine profile, then the changes of the
// second step. The printers of the user stay in the store (store.printers).
// Connects zslice to a printdeck or an OctoPrint printer that has no key
// (the App Keys flow, link.js requestKey): the printer asks "Allow
// zslice?" on its screen, and after Allow its key goes to the store. A
// printdeck that drives more than one printer lists them
// (/slicer/printer.json), and the user picks the ones to add: each one has
// the key of the deck and the path of its API under the deck.
function pairPrinter(name, fresh = false) {
  const p = store.printers?.[name];
  if (!p || (p.kind !== "printdeck" && p.kind !== "octoprint")) return Promise.resolve(false);
  return new Promise((done) => {
    const d = document.createElement("dialog");
    d.className = "printers-dialog pair-dialog";
    const title = Object.assign(document.createElement("h3"), { textContent: `Connect to ${name}` });
    const text = Object.assign(document.createElement("p"), { className: "pair-text" });
    const count = Object.assign(document.createElement("p"), { className: "dim pair-count" });
    const list = Object.assign(document.createElement("div"), { className: "pair-list" });
    const bar = Object.assign(document.createElement("div"), { className: "pair-actions" });
    const cancel = Object.assign(document.createElement("button"), { textContent: "Cancel" });
    const again = Object.assign(document.createElement("button"), { textContent: "Try again", hidden: true });
    const add = Object.assign(document.createElement("button"), { className: "suggested", textContent: "Add", hidden: true });
    bar.append(again, cancel, add);
    d.append(title, text, count, list, bar);
    document.body.append(d);
    let ctrl = null;
    let ok = false;
    const close = () => {
      ctrl?.abort();
      d.close();
      d.remove();
      done(ok);
    };
    cancel.onclick = close;
    d.oncancel = (e) => {
      e.preventDefault();
      close();
    };
    const run = async () => {
      again.hidden = true;
      cancel.textContent = "Cancel";
      text.classList.remove("error");
      const id = p.kind === "printdeck" ? await signingKeyId() : "";
      text.textContent = p.kind === "printdeck"
        ? `Tap Allow on the screen of the printdeck${id ? `, and check that it shows the key ${id}` : ""}.`
        : "Allow zslice in the web page of OctoPrint: it shows a request for zslice.";
      ctrl = new AbortController();
      const r = await requestKey({ ...p, name }, (sec) => {
        count.textContent = `Waiting for Allow: ${Math.max(0, 120 - sec)} s left.`;
      }, ctrl.signal);
      if (r.cancelled) return;
      count.textContent = "";
      if (!r.ok) {
        text.textContent = r.message;
        text.classList.add("error");
        again.hidden = false;
        return;
      }
      ok = true;
      p.apiKey = r.key;
      saveStore();
      text.textContent = `Connected to ${name}.`;
      cancel.textContent = "Close";
      if (p.kind === "printdeck") {
        const dp = await deckPrinters({ ...p, name });
        const base = (p.url || "").replace(/\/$/, "");
        const httpsBase = (p.https || dp.https || "").replace(/\/$/, "");
        // The deck names the printers and their paths: a path must stay on
        // the deck (the key goes there), and a name must be a plain key.
        // All the printers of the deck, the one at its own address too
        // (url ""): each gets its own address and the name of the deck.
        // The list did not come: say why (a key the deck refused for the
        // list, or no answer), not only "Connected".
        if (!dp.ok) {
          text.textContent = `Connected to ${name}, but the list of its printers did not come: ${dp.message}`;
          text.classList.add("error");
        }
        const others = dp.ok ? dp.printers.filter((q) => q && plainName(q.name) && q.kind !== "resin" && (q.url === "" || q.url == null || deckAddress(base, q.url))) : [];
        if (others.length > 1 || (fresh && others.length)) {
          text.textContent = others.length > 1 ? `Connected to ${dp.name || name}. It drives ${others.length} printers: pick the ones to add.` : `Connected to ${dp.name || name}.`;
          const boxes = others.map((q) => {
            const label = q.label && q.label !== q.name ? `${q.name} (${q.label})` : q.name;
            const row = Object.assign(document.createElement("label"), { className: "pair-row" });
            const cb = Object.assign(document.createElement("input"), { type: "checkbox", checked: fresh || !store.printers[label] });
            const dot = Object.assign(document.createElement("span"), { className: "menu-dot" });
            if (/^#[0-9a-f]{6}$/i.test(q.color ?? "")) dot.style.background = q.color;
            row.append(cb, dot, label);
            list.append(row);
            return { cb, q, label };
          });
          add.hidden = false;
          add.onclick = async () => {
            add.disabled = true;
            let first = null;
            for (const { cb, q, label } of boxes) {
              if (!cb.checked) continue;
              const had = store.printers[label];
              // The profile of the printer: the library model of its
              // product name, else the one it had.
              // The model, then the full name, then the short label: a label
              // ("TAZ") alone matched the first TAZ, a TAZ 6.
              let m = null;
              if (!had?.profile) {
                for (const hint of [q.model, q.name, q.label]) {
                  m = hint ? await findModel(wasm, hint).catch(() => null) : null;
                  if (m) break;
                }
              }
              store.printers[label] = {
                profile: had?.profile ?? m?.profile ?? (fresh ? "" : p.profile ?? ""),
                // The printer at the deck's own address (url "") is at the
                // root of the deck, also when the deck was added at the
                // address of another of its printers.
                url: q.url ? deckAddress(base, q.url) : deckRoot(base), kind: "printdeck", apiKey: r.key,
                https: httpsBase ? (q.url ? deckAddress(httpsBase, q.url) : deckRoot(httpsBase)) : "", color: q.color || "", label: q.label || "",
                // The name of the printer on the deck: a send checks it.
                deckName: q.name,
                files: q.files || "", model: q.model || "",
              };
              first ??= label;
            }
            // The entry that only held the address of the deck goes.
            if (fresh && !boxes.some((b) => b.cb.checked && b.label === name)) delete store.printers[name];
            saveStore();
            if (fresh && first) await usePrinter(first);
            updateMenus();
            close();
          };
        }
      }
      if (!$("farm-view").hidden) farm.start();
    };
    again.onclick = run;
    d.showModal();
    run();
  });
}

// Makes printer `name` of the store the printer now: its profile, if it
// has one.
async function usePrinter(name) {
  const pr = store.printers?.[name];
  if (!pr) return;
  if (pr.profile) await loadProfile(0, name, pr.profile);
  else store.printer = name;
  saveStore();
  updateMenus();
}

// Connects to a printdeck by its address, with no printer first: the deck
// asks "Allow zslice?" on its screen, then lists its printers, and the
// user picks the ones to add. Each one gets its own address on the deck,
// its name on the deck, and the profile of its model.
function connectDeck() {
  const d = document.createElement("dialog");
  d.className = "printers-dialog pair-dialog";
  const title = Object.assign(document.createElement("h3"), { textContent: "Connect a printdeck" });
  const text = Object.assign(document.createElement("p"), { className: "pair-text", textContent: "The address of the printdeck: on its System page. A secure address (https://….d.printdeck.beetlebug.org) works from this site in any browser." });
  const url = Object.assign(document.createElement("input"), { placeholder: "https://….d.printdeck.beetlebug.org or http://printdeck.local", autocomplete: "off", spellcheck: false });
  url.className = "pair-url";
  const msg = Object.assign(document.createElement("p"), { className: "dim pair-count" });
  const bar = Object.assign(document.createElement("div"), { className: "pair-actions" });
  const cancel = Object.assign(document.createElement("button"), { textContent: "Cancel" });
  const go = Object.assign(document.createElement("button"), { className: "suggested", textContent: "Connect" });
  bar.append(cancel, go);
  d.append(title, text, url, msg, bar);
  document.body.append(d);
  const close = () => {
    d.close();
    d.remove();
  };
  cancel.onclick = close;
  const connect = async () => {
    const u = webAddress(url.value.trim());
    if (!u) {
      msg.textContent = "Type the address of the printdeck.";
      return;
    }
    go.disabled = true;
    msg.textContent = "Looking for the printdeck…";
    const k = await detectKind(u);
    go.disabled = false;
    if (!k.ok) {
      msg.textContent = k.message;
      return;
    }
    if (k.kind !== "printdeck") {
      msg.textContent = `This address is ${k.kind === "moonraker" ? "a Klipper printer (Moonraker)" : "an OctoPrint printer"}, not a printdeck. Add it with Add a printer…`;
      return;
    }
    // A name for the entry while it pairs: the host of the address.
    let name = "printdeck";
    try {
      name = new URL(u).hostname || name;
    } catch {}
    store.printers = store.printers ?? {};
    if (!store.printers[name]) store.printers[name] = { profile: "", url: /^https:/i.test(u) ? "" : u, https: /^https:/i.test(u) ? u : "", kind: "printdeck" };
    if (!store.printers[name].url) store.printers[name].url = u;
    saveStore();
    close();
    await pairPrinter(name, true);
    updateMenus();
  };
  go.onclick = connect;
  url.onkeydown = (e) => {
    if (e.key === "Enter") connect();
  };
  d.oncancel = (e) => {
    e.preventDefault();
    close();
  };
  d.showModal();
  url.focus();
}

async function addPrinter(p) {
  store.printers = store.printers ?? {};
  store.printers[p.name] = { profile: p.profile, url: p.url };
  // An address: the kind of the printer, and its key at once.
  if (p.url) {
    const k = await detectKind(p.url);
    if (k.ok) {
      store.printers[p.name].kind = k.kind;
      saveStore();
      if (k.kind !== "moonraker") pairPrinter(p.name);
    } else {
      toast(`${p.name}: ${k.message} Set its connection in Manage printers.`);
    }
  }
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
// The printers of the user: edit, test, use, or remove each. `focus`: the
// name of a printer whose row gets the focus (from its card).
function managePrinters(focus) {
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
        // A printdeck shows the key id of the request: the user checks it.
        const id = p.kind === "printdeck" ? await signingKeyId() : "";
        const r = await requestKey({ ...p, url: url.value.trim() || p.url, name: n }, (sec) => {
          result.textContent = id ? `Allow zslice on the printer, and check that it shows the key ${id} (${120 - sec} s)…` : `Allow zslice on the printer (${120 - sec} s)…`;
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
  // From a card: the focus on the name of that printer.
  if (focus) {
    const input = [...list.querySelectorAll(".printers-row input")].find((x) => x.value === focus);
    input?.focus();
    input?.scrollIntoView({ block: "nearest" });
  }
}

function showPrinterPicker(hooks) {
  openPrinterPicker(wasm, addPrinter, hooks).catch((e) => toast(`The printer picker failed: ${e.message}`));
}

$("printer-menu").onclick = () => {
  const items = [];
  const mine = Object.keys(store.printers ?? {});
  if (mine.length) {
    items.push({ title: "Your printers" });
    for (const n of mine) items.push({ label: n, color: store.printers[n].color, checked: n === store.printer, action: () => loadProfile(0, n, store.printers[n].profile) });
  }
  items.push({ title: "Built-in" });
  for (const n of wasm.builtinProfiles(0)) {
    items.push({ label: n, checked: n === (store.printer || "generic"), action: () => loadProfile(0, n, `extends = "${n}"\n`) });
  }
  items.push(
    { sep: true },
    { label: "Printer settings and G-code…", tip: "The bed, the nozzle, the speeds, and the start and end G-code of this printer.", action: openPrinterSettings },
    { label: "Manage printers…", disabled: mine.length === 0, tip: "Rename your printers, set their addresses, or remove them.", action: managePrinters },
    { label: "Connect a printdeck…", action: () => connectDeck() },
    { label: "Import a profile…", tip: "Read the settings of a PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura profile.", action: importProfile },
    { label: "Add a printer…", action: () => showPrinterPicker() },
  );
  openMenu($("printer-menu"), items);
};

$("filament-menu").onclick = () => {
  // The filaments of the plate: a printer that changes the filament by
  // itself (machine.filament_change = tool, an AMS) prints with each of
  // them. Each one has a color and a material; "+ Add a filament" adds
  // one. Then the built-in material profiles of filament 1 (the diameter
  // stays: a property of the printer).
  const box = document.createElement("div");
  box.className = "fil-pop";
  const tool = value("machine.filament_change") === "tool";
  const list = new FilamentList({ client, applySettings: (r) => applySettings(r), toast: (t) => toast(t), nozzles: () => Number(value("machine.nozzles")) || 1 });
  const note = document.createElement("div");
  note.className = "dim fil-pop-note";
  note.textContent = tool
    ? `${store.printer || "This printer"} changes the filament by itself. Add the filaments it has, then give a part or layers a filament (right click, or the card of a part).`
    : "Add a filament to print in more colors: the print pauses at each change.";
  box.append(list.node, note);
  // The filaments that the printer has loaded (a printdeck printer).
  const pr = currentPrinter();
  if (pr?.kind === "printdeck") {
    const use = document.createElement("button");
    use.className = "fil-use";
    use.textContent = `Use the filaments of ${pr.name}`;
    use.title = "Read the spools that the printer has loaded (the AMS trays and the external spool), and make the filaments of the plate the same: count, material, and color. The filaments that you set by hand follow the printer again.";
    use.onclick = async () => {
      use.disabled = true;
      use.textContent = "Reading the printer…";
      const r = await useLoadedFilaments(pr);
      use.disabled = false;
      use.textContent = `Use the filaments of ${pr.name}`;
      toast(r.message);
    };
    box.insertBefore(use, note);
  }
  const now = value("filament.material").toLowerCase();
  const mats = document.createElement("div");
  mats.className = "fil-pop-mats";
  const head = document.createElement("div");
  head.className = "fil-head";
  head.textContent = "Profile of filament 1";
  mats.append(head);
  const row = document.createElement("div");
  row.className = "fil-pop-matrow";
  for (const n of wasm.builtinProfiles(1)) {
    if (!n.startsWith("generic-")) continue;
    const mat = n.slice(8).toUpperCase();
    const dia = value("filament.diameter") || "1.75";
    const b = document.createElement("button");
    b.className = "flat chip" + (now === mat.toLowerCase() ? " checked" : "");
    b.textContent = mat;
    b.title = `Load the built-in ${mat} profile for filament 1`;
    b.onclick = () => {
      closeMenu();
      loadProfile(1, n, `extends = "${n}"\ndiameter = ${dia}\n`);
    };
    row.append(b);
  }
  mats.append(row);
  box.append(mats);
  openPopover($("filament-menu"), box);
};

// Makes the filaments of the plate the loaded filaments of printer `pr`
// (zs_app_filaments_from_printer): the same count, then the material
// (its built-in profile), the color, and the nozzle of each, in the order
// of the printer (filament k prints from its spool k). take: the
// filaments that the user set by hand follow the printer too; else the
// automatic follow, which the core skips on a printer that pauses for
// each change. Then the nozzle of the printer. Returns { ok, changed,
// message }.
async function useLoadedFilaments(pr, take = true) {
  const r = await loadedFilaments(pr);
  if (!r.ok) return r;
  const a = await client.call("filamentsFromPrinter", { name: pr.name, json: JSON.stringify({ filaments: r.list }), flags: take ? 1 : 2 });
  if (a.list) setFilaments(a.list);
  if (a.changed) applySettings(a);
  // The nozzle that the printer has (both nozzles of an X2D are the same
  // kind): the type and the flow of its file.
  let nozzleWords = "";
  let changed = a.changed;
  const nz = (r.nozzles ?? []).map((n) => nozzleOfCode(n.type)).find(Boolean);
  if (nz && (value("machine.nozzle_type") !== nz.type || value("machine.nozzle_flow") !== nz.flow)) {
    await setSetting("machine.nozzle_type", nz.type);
    await setSetting("machine.nozzle_flow", nz.flow);
    nozzleWords = ` Nozzles: ${nz.type.replace("_", " ")}, ${nz.flow.replace("_", " ")}.`;
    changed = true;
  }
  return { ok: a.ok, changed, message: `${a.message}${nozzleWords}` };
}

// The plate uses the filaments that are in its printer: on a change of the
// printer, then each 20 s while the page shows (a printdeck printer). A
// filament that the user set by hand stays; "Use the filaments of" in the
// filament menu makes it follow the printer again.
const follow = { name: null, at: 0, busy: false };
async function followPrinterFilaments() {
  const pr = currentPrinter();
  if (follow.busy || document.visibilityState === "hidden") return;
  if (pr?.kind !== "printdeck" || !app.snapshot) {
    follow.name = pr?.name ?? null;
    return;
  }
  if (pr.name === follow.name && Date.now() - follow.at < 20000) return;
  follow.busy = true;
  follow.name = pr.name;
  follow.at = Date.now();
  try {
    const r = await useLoadedFilaments(pr, false);
    if (r.ok && r.changed) toast(r.message);
  } catch (e) {
    console.warn(`zslice: the filaments of ${pr.name}: ${e.message}`);
  } finally {
    follow.busy = false;
  }
}
setInterval(followPrinterFilaments, 2000);

// The filament button: a dot in the color of each filament of the plate,
// and the name of the filament, or the count of filaments.
function drawFilamentButton() {
  const b = $("filament-menu");
  const list = filaments();
  const name = value("filament.name") || store.filament || "Filament";
  const dots = document.createElement("span");
  dots.className = "fil-dots";
  for (const f of list.slice(0, 8)) {
    const d = document.createElement("span");
    d.className = "fil-dot";
    d.style.background = /^#[0-9a-f]{6}$/i.test(f.color) ? f.color : "#d0d0cc";
    dots.append(d);
  }
  const text = document.createElement("span");
  text.textContent = list.length > 1 ? `${list.length} filaments` : name;
  // The filaments that come from the spools of the printer.
  const fromPrinter = list.length > 0 && list.every((f) => f.fromPrinter);
  if (fromPrinter) {
    const from = document.createElement("span");
    from.className = "dim fil-from";
    from.textContent = "From the printer";
    b.replaceChildren(dots, text, from);
  } else b.replaceChildren(dots, text);
  b.title = (list.length > 1 ? `The ${list.length} filaments of the plate: click to change them` : "The filament: click to change it, or to add filaments") +
    (fromPrinter ? `. They are the spools in ${store.printer || "the printer"}.` : "");
}
followFilaments(drawFilamentButton);

// The name of a quality for the screen: a built-in one in capitals at
// the start ("Standard"); a name of the user as the user wrote it.
function qualityName(n) {
  return wasm.builtinProfiles(2).includes(n) || n === "custom" ? n.charAt(0).toUpperCase() + n.slice(1) : n;
}

$("quality-menu").onclick = () => {
  const q = app.snapshot?.quality || "";
  const items = [{ title: "Built-in" }];
  for (const n of wasm.builtinProfiles(2)) {
    items.push({
      label: qualityName(n),
      detail: wasm.qualitySummary(n),
      checked: n === q,
      action: async () => {
        const r = await client.call("quality", { name: n });
        if (r.error) toast(`The quality ${n} did not load: ${r.error}`);
        applySettings(r);
      },
    });
  }
  items.push({ sep: true }, { label: "Import a profile…", tip: "Read the settings of a PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura profile.", action: importProfile });
  openMenu($("quality-menu"), items);
};

// Imports the profile of another slicer: a PrusaSlicer or OrcaSlicer
// .ini, an OrcaSlicer or Bambu Studio .json, a 3MF project of these
// slicers, or a Cura .curaprofile. Its values become changes of the
// settings, and a dialog shows the report.
function importProfile() {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".ini,.json,.3mf,.curaprofile,.cfg,.gcode";
  input.onchange = async () => {
    const f = input.files[0];
    if (!f) return;
    const bytes = await f.arrayBuffer();
    const r = await client.call("importProfile", { name: f.name, bytes }, [bytes]);
    if (r.error) {
      toast(r.error);
      return;
    }
    applySettings(r);
    showImportReport(f.name, r.rows);
  };
  input.click();
}

// The report of an import: the values that zslice set, the values that
// went into the limits of a setting, and the keys with no zslice setting.
function showImportReport(file, rows) {
  const d = document.createElement("dialog");
  d.className = "import-report";
  d.style.cssText = "background:var(--dialog);color:var(--fg);border:none;border-radius:12px;padding:12px;max-width:760px;max-height:80vh";
  const head = document.createElement("h3");
  const format = rows.find((r) => r[0] === "format")?.[1] ?? "Profile";
  head.textContent = `${format}: ${file}`;
  const body = document.createElement("div");
  body.style.cssText = "overflow:auto;max-height:60vh";
  const section = (title, list, cells) => {
    if (!list.length) return;
    const h = document.createElement("h4");
    h.textContent = `${title} (${list.length})`;
    const t = document.createElement("table");
    t.style.cssText = "border-collapse:collapse;font-size:12px;width:100%";
    for (const r of list) {
      const tr = document.createElement("tr");
      for (const c of cells(r)) {
        const td = document.createElement("td");
        td.style.cssText = "padding:2px 6px;vertical-align:top";
        td.textContent = c;
        tr.append(td);
      }
      t.append(tr);
    }
    body.append(h, t);
  };
  const set = rows.filter((r) => r[0] === "set" || r[0] === "near");
  section("Set", set, (r) => [`${r[1]} = ${r[2]}`, `${r[3]} = ${r[4]}`, r[0] === "near" ? r[5] : ""]);
  section("Clamped to the limits of the setting", rows.filter((r) => r[0] === "clamp"), (r) => [`${r[1]} = ${r[2]}`, `${r[3]} = ${r[4]}`, `wanted ${r[5]}`]);
  section("Not imported", rows.filter((r) => r[0] === "unused"), (r) => [`${r[1]} = ${r[2]}`, r[3]]);
  const close = document.createElement("button");
  close.textContent = "Close";
  close.onclick = () => d.close();
  d.onclose = () => d.remove();
  d.append(head, body, close);
  document.body.append(d);
  d.showModal();
}

// The project items of a menu: the page of the open project and "Close
// the project", or "Open a project…".
function projectItems() {
  const name = project.openName();
  if (!name) return [{ label: "Open a project…", action: () => showTab("project") }];
  return [
    { label: `The project ${name}…`, action: () => showTab("project") },
    { label: `Close the project ${name}`, action: () => closeProject() },
  ];
}

// Closes the project: its plates stay on the view as the user's plates.
function closeProject() {
  const name = project.openName();
  project.close();
  if (name) toast(`The project ${name} is closed. Its plates stay.`);
}

// The items that people use most come first.
$("main-menu").onclick = () => openMenu($("main-menu"), [
  { label: "Open…", action: () => $("file").click() },
  { label: "Export G-code…", disabled: app.state !== "done", action: exportGcode },
  { label: "Add models to this plate…", disabled: app.state === "empty", action: () => addModels() },
  { label: "Save project…", action: () => saveProject() },
  { sep: true },
  { label: "Printers", action: () => showFarm(true) },
  { label: "History", action: () => toggleHistory(true) },
  ...projectItems(),
  { sep: true },
  // The plate items, as in the GTK main menu.
  { label: "Smart placement", disabled: app.state === "empty", tip: "Turn and arrange the parts", action: () => client.call("plate", { action: "smart" }) },
  { label: "Arrange the plate", disabled: app.state === "empty", tip: "Pack the parts on the bed", action: () => client.call("plate", { action: "arrange" }) },
  { label: "Clear the plate", disabled: app.state === "empty", action: () => client.call("plate", { action: "clear" }) },
  { label: "Remove this plate", action: () => removePlate(app.activePlate) },
  { label: "Calibrate", submenu: calibrateItems() },
  { sep: true },
  { label: "Hide the bed", checked: app.bedHidden, accel: "B", tip: "The bed and its grid do not draw, so the bottom of a part shows from below.", action: toggleBed },
  { label: "2D view", checked: app.page === "2d", accel: "2", tip: "One layer from the top. A drag pans, the wheel zooms, a double click fits the part.", action: toggle2d },
  { label: "Theme", submenu: themeItems() },
  { label: "Preferences…", accel: PREFS_ACCEL, action: () => showPreferences() },
  { sep: true },
  { label: "Keyboard shortcuts", accel: "?", action: () => shortcuts.show() },
  { label: "Licenses", action: showLicenses },
  { label: "About zslice", action: () => toast(`zslice ${wasm.cstr(wasm.x.zs_version())}: a slicer in Zig, in WebAssembly. AGPL-3.0-or-later.`) },
]);

// ---- calibration prints (src/app/calibrate.zig) ----

const CALIBRATIONS = [
  { kind: 0, label: "Temperature tower", tip: "A block for each nozzle temperature of the material" },
  { kind: 1, label: "Retraction test", tip: "Two pillars: a retraction length for each band" },
  { kind: 2, label: "Flow test", tip: "A row of cubes, each with its own flow" },
  { kind: 3, label: "Pressure advance tower", tip: "Thin walls with sharp corners: a pressure advance for each band" },
];

// The items of the Calibrate menu: a test on a new plate, and the values
// of the test of this plate.
function calibrateItems() {
  return [
    ...CALIBRATIONS.map((c) => ({ label: c.label, tip: `${c.tip}, on a new plate`, action: () => calibrate(c.kind) })),
    { sep: true },
    { label: "Use a value of this test…", tip: "How to read the test of this plate, and a button for each of its values", action: () => showCalibration() },
  ];
}

// A calibration print on a new plate, then its card.
async function calibrate(kind) {
  app.frameAdded = true;
  const r = await client.call("calibrate", { kind });
  app.frameAdded = false;
  if (!r.ok) {
    toast(r.error || "The test did not load.");
    return;
  }
  applySettings(r);
  $("empty").hidden = true;
  if (app.state === "empty") app.state = "ready";
  $("title").textContent = r.calibration?.name ?? "zslice";
  history.refresh();
  showCalibration(r.calibration);
}

// How to read the test of the active plate, and a button for each value:
// the button sets the value on each plate.
async function showCalibration(cal) {
  const c = cal ?? (await client.call("calibration")).calibration;
  if (!c) {
    toast("This plate has no calibration test. Open the Calibrate menu to make one.");
    return;
  }
  const d = document.createElement("dialog");
  d.style.cssText = "background:var(--dialog);color:var(--fg);border:none;border-radius:12px;padding:12px;max-width:560px";
  const head = document.createElement("h3");
  head.textContent = c.name;
  const note = document.createElement("p");
  note.textContent = c.note;
  const list = document.createElement("div");
  list.style.cssText = "display:flex;flex-wrap:wrap;gap:6px;margin:8px 0";
  for (const st of c.steps) {
    const b = document.createElement("button");
    b.textContent = `Use ${st.text}`;
    b.title = `Set ${c.setting} to ${st.value} on each plate`;
    b.onclick = async () => {
      const r = await client.call("calibrationUse", { setting: c.setting, value: st.value });
      if (r.error) {
        toast(r.error);
        return;
      }
      applySettings(r);
      toast(`${c.setting} is ${st.value} now.`);
      d.close();
    };
    list.append(b);
  }
  const close = document.createElement("button");
  close.textContent = "Close";
  close.onclick = () => d.close();
  d.onclose = () => d.remove();
  d.append(head, note, list, close);
  document.body.append(d);
  d.showModal();
}

// The theme: the system, light, or dark (theme.js keeps the choice in
// this browser).
function themeItems() {
  const now = themeChoice();
  return [
    { label: "Follow the system", checked: now === "system", action: () => setTheme("system") },
    { label: "Light", checked: now === "light", action: () => setTheme("light") },
    { label: "Dark", checked: now === "dark", action: () => setTheme("dark") },
  ];
}

function showLicenses() {
  const d = document.createElement("dialog");
  d.style.cssText = "background:var(--dialog);color:var(--fg);border:none;border-radius:12px;padding:12px;max-width:720px";
  const close = document.createElement("button");
  close.textContent = "Close";
  close.onclick = () => d.close();
  // The reference explorer: where zslice got its ideas, data, and code.
  const refs = document.createElement("p");
  const a = document.createElement("a");
  a.href = "https://zslice.beetlebug.org/references/explore/";
  a.target = "_blank";
  a.rel = "noopener";
  a.textContent = "The references: where zslice got its ideas, data, and code";
  refs.append(a);
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
  d.append(refs, list, close);
  d.onclose = () => d.remove();
  document.body.append(d);
  d.showModal();
}

// ---- Preferences ----
//
// The options of the app, for this browser: the slicer options that change
// no G-code (the app preferences of the core: APP_PREFS in core.js, kept in
// the saved state), the theme, the first view, and the printers. The
// settings of a print are in the settings panel. Ctrl+, (Cmd+, on a Mac)
// opens it, as Preferences in the GTK app.

const PREFS_ACCEL = /Mac|iPhone|iPad/.test(navigator.platform) ? "Cmd+," : "Ctrl+,";

// The labels of the app preferences in the dialog.
const PREF_LABELS = {
  "engine.threads": "Slicer threads",
  "engine.draft_slices": "Draft slices during edits",
  "engine.auto_simulate": "Show the print as it forms after each slice",
};

function showPreferences() {
  const open = document.querySelector("dialog.prefs-dialog");
  if (open) return;
  const d = document.createElement("dialog");
  d.className = "printers-dialog prefs-dialog";
  d.append(Object.assign(document.createElement("h3"), { textContent: "Preferences" }));
  const section = (title) => {
    const h = document.createElement("div");
    h.className = "group-title";
    h.textContent = title;
    d.append(h);
  };
  const line = (label, control, help) => {
    const row = document.createElement("div");
    row.className = "prefs-row";
    const text = document.createElement("div");
    text.className = "prefs-text";
    text.append(Object.assign(document.createElement("div"), { className: "name", textContent: label }));
    if (help) text.append(Object.assign(document.createElement("div"), { className: "speed-note", textContent: help }));
    row.append(text, control);
    d.append(row);
  };
  const choice = (items, now, set) => {
    const sel = document.createElement("select");
    sel.className = "choice";
    for (const [value, label] of items) sel.append(new Option(label, value));
    sel.value = now;
    sel.onchange = () => set(sel.value);
    return sel;
  };

  section("Slicing");
  const editors = [];
  for (const name of Object.keys(PREF_LABELS)) {
    const info = infos.find((i) => i.name === name);
    if (!info) continue;
    const ed = browser.makeEditor(info, "prefs");
    ed.update(app.snapshot?.values?.[name]);
    editors.push([name, ed]);
    line(PREF_LABELS[name], ed.node, info.doc);
  }
  // The values follow the answers of the worker while the dialog is open.
  const follow = () => { for (const [name, ed] of editors) ed.update(app.snapshot?.values?.[name]); };
  prefsFollowers.add(follow);

  section("Look");
  line("Theme", choice([["system", "Follow the system"], ["light", "Light"], ["dark", "Dark"]], themeChoice(), (v) => setTheme(v)));
  line("First view", choice([["last", "The last view"], ["3d", "3D"], ["2d", "2D (one layer)"]], store.firstView ?? "last", (v) => {
    store.firstView = v;
    saveStore();
  }), "The view at the start of the app.");

  section("Printers");
  const printers = document.createElement("div");
  printers.className = "prefs-buttons";
  const manage = Object.assign(document.createElement("button"), { textContent: "Manage printers…" });
  manage.onclick = () => { d.close(); managePrinters(); };
  const page = Object.assign(document.createElement("button"), { textContent: "Printers page" });
  page.onclick = () => { d.close(); showFarm(true); };
  printers.append(manage, page);
  line("Your printers", printers, "Their addresses and keys, and the page of their jobs.");

  const note = document.createElement("p");
  note.className = "speed-note";
  note.textContent = "This browser keeps these choices. The settings of a print are in the settings panel (N).";
  const close = Object.assign(document.createElement("button"), { textContent: "Close" });
  close.onclick = () => d.close();
  d.append(note, close);
  d.onclose = () => {
    prefsFollowers.delete(follow);
    d.remove();
  };
  document.body.append(d);
  d.showModal();
}

// The open Preferences dialog follows the values (applySettings).
var prefsFollowers = new Set(); // var: applySettings can run before this line

// The height of the dock, for the print card over it in a narrow view
// (the dock wraps onto more rows).
new ResizeObserver(() => $("preview").style.setProperty("--dock-h", `${$("dock").offsetHeight}px`)).observe($("dock"));
// The height of the print card, for the layer slider over it.
new ResizeObserver(() => $("preview").style.setProperty("--card-h", `${$("summary").offsetHeight}px`)).observe($("summary"));

// ---- the panel and the pages ----

// The panel has the settings, and the long form of the selected line
// (with one back arrow to the settings). The history is a popover over
// its button in the dock, the project a dialog, and the printers a page over the
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
  // The title of the Selected page: a line, a gap, or a part.
  if (selected) $("panel-title").textContent = app.selectedKind === "gap" ? "Selected gap" : "Selected line";
  updateFocus();
}
$("selected-back").onclick = () => showTab("settings");

// The history popover: open (true), closed (false), or the other state.
// It opens over its button in the dock, and never covers the button.
function toggleHistory(open) {
  const pop = $("history-pop");
  const show = open ?? pop.hidden;
  pop.hidden = !show;
  $("history-button").setAttribute("aria-expanded", String(show));
  if (show) {
    placeHistory();
    history.refresh().then(() => {
      placeHistory();
      // The arrow keys go through the steps at once.
      (pop.querySelector(".hist-now") ?? $("page-history")).focus({ preventScroll: true });
      pop.querySelector(".hist-now")?.scrollIntoView({ block: "nearest" });
    });
  }
}
// Over the history button: its bottom 8 px above the top of the button,
// its left at the left of the button, and inside the view.
function placeHistory() {
  const pop = $("history-pop");
  if (pop.hidden) return;
  const view = $("preview").getBoundingClientRect();
  const b = $("history-button").getBoundingClientRect();
  pop.style.maxHeight = `${Math.max(160, Math.min(560, b.top - view.top - 20))}px`;
  const w = pop.offsetWidth;
  const left = Math.max(8, Math.min(view.width - w - 8, b.left - view.left - 8));
  pop.style.left = `${left}px`;
  pop.style.bottom = `${view.bottom - b.top + 8}px`;
}
window.addEventListener("resize", placeHistory);
$("history-button").onclick = () => toggleHistory();
$("history-close").onclick = () => toggleHistory(false);
document.addEventListener("pointerdown", (e) => {
  const pop = $("history-pop");
  if (pop.hidden || pop.contains(e.target) || $("history-button").contains(e.target)) return;
  // The right-click menu of a step.
  if ($("menu-layer")?.contains(e.target)) return;
  toggleHistory(false);
});
// Esc closes the popover first, before the keys of the view see it.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || $("history-pop").hidden) return;
  if (e.target.closest?.("input, textarea, select")) return;
  e.preventDefault();
  e.stopPropagation();
  toggleHistory(false);
  $("history-button").focus();
}, true);

// The Printers page over the view: the tiles read the printers only while
// it shows.
function showFarm(show) {
  $("farm-view").hidden = !show;
  // The page has the width of the window.
  if (show && panelMode() === "overlay") setPanelMode("hidden");
  $("printers-page").setAttribute("aria-pressed", String(show));
  $("printers-page").classList.toggle("checked", show);
  if (show) farm.start();
  else farm.stop();
}
$("printers-page").onclick = () => showFarm($("farm-view").hidden);
$("farm-back").onclick = () => showFarm(false);
$("project-close").onclick = () => $("project-dialog").close();

// ---- the 2D and the 3D view ----

// Key B and the item "Hide the bed" of the main menu: the bed model and
// the grids do not draw, so the bottom of a part shows from below (for a
// look, or a label on the bottom, with no turn of the part).
function toggleBed() {
  app.bedHidden = !app.bedHidden;
  view.x.zs_view_set_bed_hidden(view.v, app.bedHidden ? 1 : 0);
  toast(app.bedHidden ? "The bed is hidden. Press B to show it." : "The bed shows again.");
  requestFrame();
}

// Shows the 2D layer view or the 3D view (the toggle of preview.c). The
// key 2 and the item "2D view" of the main menu switch between them. In
// the 2D view, a sign at the top of the view says so.
function showPage(page) {
  if (app.page === page) return;
  app.page = page;
  store.view = page;
  saveStore();
  $("view-sign").hidden = page !== "2d";
  requestFrame();
}
function toggle2d() {
  showPage(app.page === "2d" ? "3d" : "2d");
}
$("view-sign").onclick = () => showPage("3d");
$("view-sign").hidden = app.page !== "2d";

// ---- the selection ----

// Selects segment `seg` of path `path` (-1: none). `picked`: a click on
// the line, so the Selected page shows (inspector.c, on_picked).
function select(path, seg, picked) {
  app.sel = path;
  app.seg = path >= 0 ? seg : -1;
  view.highlight(path, app.seg, app.isolate);
  // A new selection drops the other lines of a run.
  if (app.run) {
    app.run = null;
    view.highlightMore([]);
  }
  requestFrame();
  if (picked && path >= 0) {
    // The card of the line opens at the click; a panel that shows also
    // turns to the Selected page.
    // With the panel on the Selected page, the panel shows the new line,
    // and no card opens (the same data twice). Else the card opens at the
    // click.
    app.selectedKind = "line";
    if (panelMode() !== "hidden" && !$("page-selected").hidden) showTab("selected");
    else {
      lineCard.openAt(...(app.pickPoint ?? [120, 120]));
      if (panelMode() !== "hidden") showTab("selected");
    }
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
    selection.lineFound(path, path >= 0 ? view.pathSegments(path) : 0);
    if (path >= 0 && app.sel !== path) {
      // The line has another key now (a line near the old place).
      selection.setLine(BigInt(r.info.key ?? 0), path, Math.min(Math.max(app.seg, 0), view.pathSegments(path) - 1));
    }
    view.highlight(app.sel, app.seg, app.isolate);
    requestFrame();
  }
  // The key of the line: the next slice finds it by this key.
  if (r.info?.key && r.info.path === app.sel) selection.setLine(BigInt(r.info.key), app.sel, app.seg);
  inspector.show(r.info);
}

// The place of the selection, to find it again after a new slice.
function refindKey() {
  const info = app.info;
  if (app.sel < 0 || !info) return null;
  view.pathBeads(app.sel, rangeTmp);
  const b = rangeTmp[1] > rangeTmp[0] ? rangeTmp[0] + ((rangeTmp[1] - rangeTmp[0]) >> 1) : -1;
  if (b < 0) return null;
  return { key: String(selection.line().key), layer: info.layer, feature: info.feature, ...view.beadPoint(b) };
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
// - the arrows move it 1 mm on the bed (Shift: 10 mm);
// - Page Up and Page Down lift it 1 mm (Shift: 10 mm): up it floats,
//   down it sinks into the bed;
// - [ and ] turn it 15° about Z (Shift: 1°);
// - Ctrl and the arrows turn it 15° about X (Up and Down) and Y (Left and
//   Right); Shift: 1°.
// The view and the card follow at once; the slice waits for a pause of
// the keys (sliceAfterKeys), and then the physics (a part in the air or on
// an edge falls).
function partKey(e) {
  if (e.metaKey || e.altKey) return false;
  const t = e.target;
  if (t?.closest?.("input, textarea, select, [contenteditable], .panel, .search-layer, .keys-layer")) return false;
  if (!e.ctrlKey && e.key === "Tab" && (t === document.body || t === canvas || t?.closest?.(".part-card"))) {
    if (!view.loaded && app.state === "empty") return false;
    e.preventDefault();
    const index = tools.part ? tools.part.index : -1;
    const stamp = tools.stamp;
    client.call("partStep", { index, dir: e.shiftKey ? -1 : 1 }).then((r) => {
      if (!r.part || stamp !== tools.stamp) return;
      if (tools.tool !== "move") tools.set("move");
      tools.selectPart(r.part);
    });
    return true;
  }
  if (!e.ctrlKey && (e.key === "r" || e.key === "R" || e.key === "g" || e.key === "G") && !e.shiftKey) {
    tools.set("move");
    e.preventDefault();
    return true;
  }
  const part = tools.part;
  if (!part) return false;
  const dirs = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, 1], ArrowDown: [0, -1] };
  const d = dirs[e.key];
  const turnStep = e.shiftKey ? 1 : 15;
  const done = () => {
    e.preventDefault();
    e.stopPropagation();
    return true;
  };
  // Ctrl and the arrows: a turn about X (Up and Down) or Y (Left and
  // Right) of the bed.
  if (e.ctrlKey) {
    if (!d) return false;
    const axis = d[0] !== 0 ? 1 : 0;
    const sign = d[0] !== 0 ? d[0] : -d[1];
    client.call("partTurn", { index: part.index, axis, degrees: sign * turnStep, hold: true }).then((r) => r.part && tools.updatePart(r.part));
    sliceAfterKeys(part.index);
    return done();
  }
  // [ and ]: a turn about Z.
  if (e.code === "BracketLeft" || e.code === "BracketRight" || e.key === "[" || e.key === "]" || e.key === "{" || e.key === "}") {
    // As the GTK app: [ turns clockwise (seen from above), ] the other way.
    const sign = e.code === "BracketLeft" || e.key === "[" || e.key === "{" ? -1 : 1;
    client.call("partTurn", { index: part.index, axis: 2, degrees: sign * turnStep, hold: true }).then((r) => r.part && tools.updatePart(r.part));
    sliceAfterKeys(part.index);
    return done();
  }
  const step = e.shiftKey ? 10 : 1;
  // Page Up and Page Down: the lift.
  if (e.key === "PageUp" || e.key === "PageDown") {
    const z = Math.round(((part.z ?? 0) + (e.key === "PageUp" ? step : -step)) * 100) / 100;
    tools.placePart(part.id, part.x, part.y, z);
    client.call("partLift", { index: part.index, z, hold: true }).then((r) => r.part && tools.updatePart(r.part));
    sliceAfterKeys(part.index);
    return done();
  }
  if (!d) return false;
  // A selection of several parts: all of them move, in one call.
  if (tools.parts.length > 1) {
    const moved = tools.parts.map((p) => ({ ...p, x: p.x + d[0] * step, y: p.y + d[1] * step }));
    for (const p of moved) tools.placePart(p.id, p.x, p.y, p.z ?? 0);
    client.call("partsMove", { moves: moved.map((p) => ({ index: p.index, x: p.x, y: p.y })), hold: true }).then((r) => r.parts && tools.updateParts(r.parts));
    sliceAfterKeys();
    return done();
  }
  const x = part.x + d[0] * step;
  const y = part.y + d[1] * step;
  tools.placePart(part.id, x, y, part.z ?? 0);
  client.call("partMove", { index: part.index, x, y, hold: true }).then((r) => r.part && tools.updatePart(r.part));
  sliceAfterKeys();
  return done();
}

// The layer range of Shift+J and Shift+K: { a: the first layer, b: the
// layer that moves }, or null.
let keyRange = null;

function onPreviewKey(e) {
  // The Support tool: Enter, Backspace, Delete, and Esc for its areas.
  if ((tools.tool === "support" || supportTool?.lite) && !e.ctrlKey && !e.metaKey && !e.altKey && !e.target?.closest?.("input, textarea, select, [contenteditable], .panel, .search-layer, .keys-layer") && supportTool.key(e)) {
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  // The Label tool: Delete removes the selected label.
  if (labelTool?.on && labelTool.sel >= 0 && (e.key === "Delete" || e.key === "Backspace") && !e.ctrlKey && !e.metaKey && !e.altKey && !e.target?.closest?.("input, textarea, select, [contenteditable], .panel, .search-layer, .keys-layer")) {
    labelTool.remove();
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (partKey(e)) return;
  // Ctrl+F and Ctrl+B (as in vi): a page of layers up or down, 5 % of the
  // layers of the print (at least 2).
  const page = (e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && (e.key === "f" || e.key === "b");
  if ((e.ctrlKey || e.metaKey || e.altKey) && !page) return;
  if (menuOpen() || !view.loaded || layers.count === 0) return;
  const t = e.target;
  // The search and the list of keys have their own arrow keys and V.
  if (t && (t.closest?.("input, textarea, select, [contenteditable]") || t.closest?.(".panel, .search-layer, .keys-layer"))) return;
  let dir = 0;
  let layerDir = 0;
  let jump = 1;
  if (page) {
    layerDir = e.key === "f" ? 1 : -1;
    jump = Math.max(2, Math.round(layers.count * 0.05));
  }
  // Shift+K and Shift+J: a range of layers that grows from the layer of
  // the selected line (or the top layer), as a drag of the Select tool
  // makes; the card of the range opens on it.
  if (!page && e.shiftKey && (e.key === "K" || e.key === "J")) {
    if (!rangeCard.open || !keyRange) {
      const base = app.sel >= 0 ? view.pathLayer(app.sel) : layers.hi;
      keyRange = { a: base, b: base };
    }
    keyRange.b = Math.min(layers.count - 1, Math.max(0, keyRange.b + (e.key === "K" ? 1 : -1)));
    const lo = Math.min(keyRange.a, keyRange.b);
    const hi = Math.max(keyRange.a, keyRange.b);
    // From the selected line: its body of its part; else all the layers.
    if (keyRange.path === undefined) keyRange.path = app.sel;
    if (keyRange.path >= 0) {
      view.lightColor(null);
      view.lightConnected(keyRange.path, lo, hi);
      app.rangeLight = { path: keyRange.path, layer: view.pathLayer(keyRange.path), lo, hi };
    } else view.lightLayers(lo, hi);
    rangeCard.show(lo, hi);
    requestFrame();
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (page) {
    // The layer move below.
  } else switch (e.key) {
    // The arrows (and h and l) step along the line.
    case "ArrowLeft": dir = -1; break;
    case "ArrowRight": dir = 1; break;
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
    case "v": case "V": tools.set("select"); e.preventDefault(); return;
    // S: the Support tool; S again opens or closes its pane. U is the old
    // key of the tool.
    case "s": case "S": case "u": case "U":
      if (tools.tool === "support") supportTool?.togglePane();
      else tools.set("support");
      e.preventDefault();
      return;
    case "m": case "M": tools.set("move"); e.preventDefault(); return;
    case "p": case "P": labelTool.close(); paintTool.toggle(); e.preventDefault(); return;
    // h and l step as Left and Right (vim): a segment of the selected
    // line, or the nozzle. Shift+H and Shift+L: a whole line.
    case "h": case "H": dir = -1; break;
    case "l": case "L": dir = 1; break;
    case "e": case "E": labelTool.toggle(); e.preventDefault(); return;
    // R and G: other keys of the transform tool (M).
    case "g": case "G": case "r": case "R": tools.set("move"); e.preventDefault(); return;
    case "t": case "T": tools.set("measure"); e.preventDefault(); return;
    case "c": case "C":
      if (e.key === "C" || e.shiftKey) showAllLayers();
      else if (app.sel >= 0) cutToSelection();
      else return;
      e.preventDefault();
      return;
    case "Escape":
      if (labelTool.on) {
        if (labelTool.drawing >= 0) labelTool.stopDrawing();
        else if (labelTool.sel >= 0) labelTool.select(-1);
        else labelTool.close();
        e.preventDefault();
        return;
      }
      if (paintTool.on) {
        paintTool.close();
        e.preventDefault();
        return;
      }
      if (rangeCard.open) {
        rangeCard.close();
        e.preventDefault();
        return;
      }
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

// ---- the keys of the window ----
//
// The keys of the view are above (onPreviewKey). These work in the whole
// window: the plates, Ctrl and a letter, Esc of the search, and the keys
// of the cards, the panel, and the search.

// The keys of the plates: [ and ] (the plate before and the next plate,
// framed), F (frame the active plate), and Home (all plates), also with no
// slice.
document.addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey || menuOpen()) return;
  const t = e.target;
  if (t && (t.closest?.("input, textarea, select, [contenteditable]") || t.closest?.(".panel"))) return;
  if (e.key === "[" || e.key === "]") {
    // A selected part in the 3D view: [ and ] turn it (partKey).
    if (tools.part && app.page === "3d") return;
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

// Ctrl+O opens, Ctrl+E exports, Ctrl+S saves the project, and Ctrl+Z,
// Ctrl+Shift+Z, and Ctrl+Y undo and redo.
document.addEventListener("keydown", (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  if (e.key === ",") {
    e.preventDefault();
    showPreferences();
  } else if (e.key === "o") {
    e.preventDefault();
    $("file").click();
  } else if (e.key === "e") {
    e.preventDefault();
    exportGcode();
  } else if (e.key === "s") {
    e.preventDefault();
    saveProject();
  } else if (e.key === "h" && !e.shiftKey && !e.altKey) {
    e.preventDefault();
    toggleHistory();
  } else if ((e.key === "z" || e.key === "Z" || e.key === "y") && !e.target.closest("input, textarea, select")) {
    e.preventDefault();
    undoRedo(e.key === "z" && !e.shiftKey ? "undo" : "redo");
  }
});

// Esc closes the search also when the view has the focus (after a turn of
// the view), once the keys of the view (a selection, the tape) are done.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || e.defaultPrevented || !search.open) return;
  if (e.target.closest?.("input:not(.search-input), textarea, select")) return;
  e.preventDefault();
  search.close();
});

// Delete removes the part of the card, or takes the selected line out of
// the print. N shows the panel, D copies the part of the card, ? shows
// the keys, / opens the search, 2 shows the 2D view or the 3D view
// again, and 3 shows the 3D view.
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
  if (!["/", "?", "n", "N", "d", "D", "2", "3", "b", "B"].includes(e.key) || e.ctrlKey || e.metaKey || e.altKey) return;
  if ((e.key === "d" || e.key === "D") && !partCard.open) return;
  if (e.target.closest?.("input, textarea, select, [contenteditable]")) return;
  e.preventDefault();
  if (e.key === "2") {
    toggle2d();
  } else if (e.key === "b" || e.key === "B") {
    toggleBed();
  } else if (e.key === "3") {
    showPage("3d");
  } else if (e.key === "n" || e.key === "N") {
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

// ---- the context menu (context-menu.js has its entries) ----

async function showContextMenu(x, y) {
  // The place of the click, for "Add a drop of plastic here".
  app.menuAt = [x, y];
  // What is under the pointer: a support line, a line of a part, or none.
  let on = "empty";
  if (app.sel >= 0) {
    const k = await client.call("lineFeature", { path: app.sel });
    on = k.feature === 6 || k.feature === 7 ? "support" : "part";
  }
  const items = contextItems({
    on,
    marks: app.marks > 0,
    cut: isCut(),
    clip: clipboard.full,
    clipParts: clipboard.hasParts,
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
    case "removeSupport": {
      // The support that the Select tool picked goes with it: its
      // handles and its overhang.
      supportTool?.clearLite();
      const r = await client.call("supportRemoveAt", { path, seg });
      if (r.error) toast(r.error);
      else supportTool?.setAreas(r.areas);
      break;
    }
    case "copyForAi": await copyForAi(); break;
    case "pasteHere": await clipboard.pasteAt(app.menuAt[0], app.menuAt[1]); break;
    case "copyPart":
    case "cutPart":
    case "duplicatePart": {
      const r = await client.call("partAt", { path, bed: false, x: 0, y: 0 });
      if (!r.part) break;
      const sel = { kind: "parts", indices: [r.part.index] };
      if (act === "copyPart") await clipboard.copy(sel);
      else if (act === "cutPart") await clipboard.cut(sel);
      else {
        const stamp = tools.stamp;
        const d = await client.call("partsAction", { indices: sel.indices, action: "duplicate" });
        if (d.ok) tools.selectReply(d.parts ?? [], stamp);
      }
      break;
    }
    case "copyPlate": await clipboard.copyPlate(); break;
    case "duplicatePlate": await clipboard.duplicatePlate(); break;
    case "pastePlate": await clipboard.pasteAsPlate(); break;
    case "putDown": await client.call("putDown", { path, seg }); break;
    case "place": await client.call("place", { path, code: arg }); break;
    case "plate": await client.call("plate", { action: arg }); break;
    case "addModels": addModels(); break;
    case "removePlate": await removePlate(app.activePlate); break;
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
  // The card of the part goes beside the part and its gizmo.
  partSelected: (part, parts) => partCard?.show(part, parts),
  sel: selection,
  client, view, canvas, view2d,
  buttons: { select: $("tool-select"), move: $("tool-move"), measure: $("tool-measure"), support: $("tool-support") },
  gizmo: () => gizmo,
  again: (t) => { if (t === "support") supportTool?.togglePane(); },
  toolChanged: (tool) => {
    supportTool?.setActive(tool === "support");
    supportTool?.clearLite();
    rangeCard?.close();
  },
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
  menu: (x, y, items) => openMenuAt(x, y, items, () => canvas.focus({ preventScroll: true })),
});

// ---- a range of layers: a drag of the Select tool (rangecard.js) ----

// The top of layer l, and its bottom, mm.
const layerTop = (l) => app.layers?.z[l] ?? 0;
const layerBottom = (l) => (l > 0 ? layerTop(l - 1) : layerTop(0) - (app.layers?.height?.[0] ?? 0));

var rangeCard = new RangeCard({ // var: drawFrame can run before this line
  browser,
  host: $("preview"),
  pixelOf: (p) => view.pixelOf(p[0], p[1], p[2]),
  bounds: () => view.bounds(),
  layerZ: layerTop,
  layerBottom,
  edit: async (name, value, zmin, zmax, names) => {
    const r = await client.call("setScoped", { name, value, zmin, zmax, perLayer: true, at: { z: zmin, names } });
    applySettings(r);
    return r;
  },
  reset: async (name, zmin, zmax, names) => {
    const r = await client.call("resetScoped", { name, zmin, zmax, z: zmin, at: { z: zmin, names } });
    applySettings(r);
    return r;
  },
  values: async (z, names) => (await client.call("valuesAt", { z, names })).at,
  search: (text, scope) => search.show(text, scope),
  // The range lights one body of a part (a drag from a line).
  body: () => (app.rangeLight?.path ?? -1) >= 0,
  // The filament of the lit body: its beads go to the worker, which
  // paints the part under them (src/paint_body.zig) and slices. The body
  // shows in the color of the filament at once.
  paintBody: async (f) => {
    const r = app.rangeLight;
    const beads = r && r.path >= 0 ? view.connectedBeads(r.path, r.lo, r.hi) : null;
    if (!beads) return "No body is lit.";
    r.color = filaments()[f - 1]?.color ?? null;
    view.lightColor(r.color);
    requestFrame();
    const res = await client.call("paintBody", { beads, filament: f });
    return res.error ?? null;
  },
  // The region of the lit body (zs_app_region_find): { id, values }.
  regionOf: async () => {
    const r = app.rangeLight;
    const beads = r && r.path >= 0 ? view.connectedBeads(r.path, r.lo, r.hi) : null;
    if (!beads) return { id: 0, values: {} };
    return client.call("regionOf", { beads });
  },
  // A setting of the region of the lit body (zs_app_region_set): a
  // modifier volume of the part, then a slice.
  regionSet: async (id, name, value) => {
    const r = app.rangeLight;
    const beads = r && r.path >= 0 ? view.connectedBeads(r.path, r.lo, r.hi) : null;
    if (!beads && !id) return { error: "No part of the layers is lit." };
    const res = await client.call("regionSet", { beads, region: id, name, value });
    if (res.error) toast(res.error);
    return res;
  },
  close: () => {
    app.rangeLight = null;
    view.lightLayers(-1);
    view.lightConnected(-1);
    view.lightColor(null);
    requestFrame();
  },
});

// The layer under the pointer in a drag over layers: the pointer goes to
// the nearest point of the line on the screen from the bed to the top
// layer, up through the point of the press. Two projections for each
// move, and no pick. A view from above (a short line) picks the line
// under the pointer.
function layerUnder(d, px, py) {
  const z = app.layers?.z;
  if (!z || z.length === 0) return null;
  const lo = layers.lo;
  const hi = Math.min(layers.hi, z.length - 1);
  const a = view.pixelOf(d.pt[0], d.pt[1], 0);
  const b = view.pixelOf(d.pt[0], d.pt[1], z[hi]);
  const len2 = a && b ? (b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2 : 0;
  if (len2 < (24 * dpr()) ** 2) return hitAt(px, py) ? view.pathLayer(view.hit[0]) : null;
  const t = Math.max(0, Math.min(1, ((px - a[0]) * (b[0] - a[0]) + (py - a[1]) * (b[1] - a[1])) / len2));
  const want = t * z[hi];
  // The first layer with its top at or over the height.
  let l = lo;
  let h = hi;
  while (l < h) {
    const m = (l + h) >> 1;
    if (z[m] < want) l = m + 1;
    else h = m;
  }
  return l;
}

// A new scene (a slice, or the simulated print after it) clears the lit
// body of a range: light it again from its start line, if that line is
// still on its layer; else all the lines of the layers.
// A slice can number the lines again (a new filament of a body splits its
// layers), so the start line is the line of its layer at the point of the
// press, if the range has one.
// The body of a line that the Filament row of the line card colors: lit
// in the color of the filament until the slice comes back.
function lightLine(path, lo, hi, f) {
  if (app.rangeLight) return;
  app.lineLight = true;
  view.lightConnected(path, lo, hi);
  view.lightColor(filaments()[f - 1]?.color ?? null);
  requestFrame();
}

view.onLoad = () => {
  // The slice of a filament of the line card: its lines have the color now.
  if (app.lineLight) {
    app.lineLight = false;
    view.lightConnected(-1);
    view.lightColor(null);
  }
  const r = app.rangeLight;
  if (!r || !rangeCard.open) return;
  if (r.path >= 0 && r.pt && view.pickLayer(r.layer, r.pt[0], r.pt[1])) r.path = view.hit[0];
  view.lightColor(r.color ?? null);
  if (r.path >= 0 && view.pathLayer(r.path) === r.layer) view.lightConnected(r.path, r.lo, r.hi);
  else view.lightLayers(r.lo, r.hi);
};

const rangeDrag = {
  // A press: on a printed line, the start of a drag over layers.
  start(px, py) {
    if (!app.layers || !hitAt(px, py)) return null;
    const path = view.hit[0];
    const layer = view.pathLayer(path);
    const c = view.w.cell;
    if (!view.x.zs_view_surface_point(view.v, px, py, 0, c)) return null;
    return { path, layer, cur: layer, pt: [view.w.f64(c), view.w.f64(c + 8)], lit: false };
  },
  move(d, px, py) {
    const l = layerUnder(d, px, py);
    if (l === null || (d.lit && l === d.cur)) return;
    if (!d.lit) {
      // The drag is for the layers: no line, and no card of an old range.
      select(-1, -1, false);
      supportTool?.clearLite();
      if (rangeCard.open) rangeCard.close();
    }
    d.lit = true;
    d.cur = l;
    // The body of the part of the line where the drag started, on these
    // layers: not every line of the layers.
    view.lightColor(null);
    view.lightConnected(d.path, d.layer, l);
    app.rangeLight = { path: d.path, layer: d.layer, lo: Math.min(d.layer, l), hi: Math.max(d.layer, l), pt: d.pt };
    requestFrame();
  },
  end(d) {
    if (d.lit) rangeCard.show(d.layer, d.cur);
  },
  clear() {
    if (rangeCard.open) rangeCard.close();
  },
};

// ---- the mouse, the touch screen, and the wheel over the view ----

attachViewInput(canvas, { app, view, view2d, tools, supportTool, requestFrame, pickAt, pickRun, hitAt, select, showContextMenu, activatePlate, signMenu: (i, x, y) => openMenuAt(x, y, [{ label: `Go to plate ${i + 1}`, action: () => activatePlate(i, true) }, { label: `Remove plate ${i + 1}`, action: () => removePlate(i) }]), range: rangeDrag });

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
    app.selectedKind = "gap";
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
  tools: { undo: $("undo"), redo: $("redo"), button: $("history-button"), count: $("history-count"), sum: $("history-sum") },
  undoRedo: (op) => undoRedo(op),
  get browser() {
    return browser;
  },
});

// ---- printdeck.yml projects ----

var project = new ProjectPage( // var: the plate signs can ask before this line
  $("page-project"), {
  statusChanged: () => updatePlateSigns(),
  // The project closed: the session keeps its plates as the user's.
  closed: () => {
    keepSoon();
    updatePlateSigns();
  },
  client,
  applySettings: (r) => applySettings(r),
  toast,
  loading: () => {
    projectActive = true;
    // A new set of plates: the camera shows them all.
    selection.frame(FRAME_ALL);
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
    history.markSaved();
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
  // The labels of the step (label.js).
  labelTool?.reload();
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
$("check").title = "Check the print: overhangs with no support, bridges, shapes in the air, lines over the flow of the hot end, layers that cool too little, parts that can tip over";
$("check").onclick = () => openCheck();

// ---- the print card ----
//
// The print is at the right end of the bottom bar: its time, and Print or
// Export. A click on the time opens the details pane over the bar: the
// main settings, the warnings, and the usual refinements. A badge on the
// time counts the warnings and the refinements.

function showSumPop(open) {
  const pop = $("sum-pop");
  pop.hidden = !open;
  $("sum-more").setAttribute("aria-expanded", String(open));
  showSumCamera(open);
}

// The camera of the printer at the top of the details, while the printer
// of the plate prints (camera.js). It plays only while the details show,
// so the 3D view keeps its frames.
let sumCam = null;
async function showSumCamera(open) {
  const box = $("sum-cam");
  sumCam?.close();
  sumCam = null;
  box.hidden = true;
  box.replaceChildren();
  const pr = currentPrinter();
  if (!open || !pr || !pr.kind || pr.kind === "none" || !(pr.url || pr.https)) return;
  const st = await printerStatus(pr);
  if ($("sum-pop").hidden || sumCam || !st.ok || (st.status.farm !== 2 && st.status.farm !== 3)) return;
  const cam = await printerCamera(pr);
  if ($("sum-pop").hidden || sumCam || !cam.ok || !cam.camera) return;
  sumCam = new CameraView(cam.camera, { label: pr.name, printdeck: pr.kind === "printdeck" });
  const s = st.status;
  const line = document.createElement("div");
  line.className = "dim sum-cam-line";
  line.textContent = `${pr.name}: ${s.job ? `${s.job}, ` : ""}${Math.round(s.progress * 100)} %${s.timeLeft > 0 ? `, ${formatTime(s.timeLeft)} left` : ""}`;
  box.append(sumCam.el, line);
  box.hidden = false;
}
$("sum-more").onclick = () => showSumPop($("sum-pop").hidden);
document.addEventListener("pointerdown", (e) => {
  if ($("sum-pop").hidden) return;
  if (e.target.closest?.("#sum-pop, #sum-more")) return;
  showSumPop(false);
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("sum-pop").hidden) showSumPop(false);
});

// The problems of the check (a warning or worse), as the Check button
// and the print card count them.
function checkProblems() {
  return (app.issues ?? []).filter((i) => i.severity >= 1).length;
}

// The count on the Check button of the tool strip: the same number as the
// badge of the print card.
function updateCheckCount() {
  const n = checkProblems();
  const b = $("check");
  let c = b.querySelector(".check-count");
  if (!c) {
    c = Object.assign(document.createElement("span"), { className: "check-count" });
    b.append(c);
  }
  c.textContent = n > 0 ? String(n) : "";
  c.hidden = n === 0;
  b.title = n > 0 ? `Check the print: ${n} ${n === 1 ? "problem" : "problems"} to look at` : "Check the print: overhangs with no support, bridges, shapes in the air, lines over the flow of the hot end, layers that cool too little, parts that can tip over";
}

function updateBadge() {
  const badge = $("sum-badge");
  const warn = !$("sum-warn").hidden;
  const n = checkProblems();
  const tips = $("refine-tips").hidden ? 0 : $("refine-tips").querySelectorAll(".refine-row").length;
  // The badge counts the problems of the Check (the same list as the
  // Check button), or a warning of the card (a part off the bed).
  badge.classList.toggle("warn", warn || n > 0);
  badge.hidden = !warn && n === 0 && tips === 0;
  badge.textContent = n > 0 ? `${n} to check` : warn ? "Check" : tips === 1 ? "1 refinement" : `${tips} refinements`;
  // A warning does not open the details: they cover the part. The badge
  // in the warning color is the sign, and a click opens them.
}

function updateSummary() {
  updateSummaryCard();
  updateBadge();
}

// The work bar of the view: the draft slice, the exact slice, and the
// simulated print, each with the progress of the core. The bar shows
// after SHOW_MS of work, so a fast slice gives no flicker. The text has
// what runs and its time, then the times of the last draft and the last
// exact slice. "Draft" comes first while the view shows a draft.
const work = {
  SHOW_MS: 150,
  // The text stays this long after the work ends.
  KEEP_MS: 2500,
  kind: "", // "draft", "exact", "sim", or "" (no work)
  t0: 0,
  fraction: 0,
  showTimer: 0,
  hideTimer: 0,
  tick: 0,
  // The times of the last draft and exact slice (ms), and the progress
  // of the simulation that ended.
  last: { draft: 0, exact: 0 },
  // For tests: each start and end, with its time.
  log: [],

  start(kind) {
    if (this.kind !== kind) {
      this.kind = kind;
      this.t0 = performance.now();
      this.log.push({ kind, start: this.t0 });
    }
    this.fraction = 0;
    $("work-fill").style.width = "0%";
    clearTimeout(this.hideTimer);
    if (!this.showTimer && !$("work").classList.contains("on")) {
      this.showTimer = setTimeout(() => {
        this.showTimer = 0;
        if (!this.kind) return;
        $("work").classList.add("on");
        this.text();
      }, this.SHOW_MS);
    }
    if (!this.tick) this.tick = setInterval(() => this.text(), 100);
  },

  progress(f) {
    this.fraction = f;
    $("work-fill").style.width = `${(f * 100).toFixed(1)}%`;
    this.text();
  },

  // The work of `kind` ended; ms: the time of a slice (0: the time since
  // the start).
  end(kind, ms = 0) {
    if (kind && this.kind && kind !== this.kind) return;
    const took = ms > 0 ? ms : performance.now() - this.t0;
    if (this.kind === "draft" || this.kind === "exact") this.last[this.kind] = took;
    if (this.kind) this.log.push({ kind: this.kind, end: performance.now(), ms: took });
    this.kind = "";
    clearTimeout(this.showTimer);
    this.showTimer = 0;
    clearInterval(this.tick);
    this.tick = 0;
    $("work").classList.remove("on");
    this.text();
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => this.text(), this.KEEP_MS);
  },

  time(ms) {
    return ms < 1000 ? `${ms.toFixed(0)} ms` : `${(ms / 1000).toFixed(2)} s`;
  },

  // The times of the last slices: "Draft 480 ms · Exact 1.47 s".
  lastText() {
    const parts = [];
    if (this.last.draft > 0) parts.push(`Draft ${this.time(this.last.draft)}`);
    if (this.last.exact > 0) parts.push(`Exact ${this.time(this.last.exact)}`);
    return parts.join(" · ");
  },

  text() {
    const node = $("busy");
    let t = "";
    if (this.kind) {
      const s = ((performance.now() - this.t0) / 1000).toFixed(this.kind === "draft" ? 2 : 1);
      if (this.kind === "sim") t = `Simulation ${Math.round(this.fraction * 100)} %`;
      else t = `${this.kind === "draft" ? "Draft" : "Slice"} ${s} s`;
      // The view still has the draft while the exact slice runs.
      if (app.draft && this.kind !== "draft") t = `Draft · ${t}`;
    } else if (app.draft) t = `Draft · ${this.time(this.last.draft)}`;
    else t = this.lastText();
    // The Faster slicing switch (the Speed settings), so its state shows.
    const speed = app.snapshot?.speed;
    if (t && speed === "on") t = `${t} · Faster slicing on`;
    else if (t && speed === "custom") t = `${t} · Custom speed settings`;
    const running = !!this.kind && performance.now() - this.t0 >= this.SHOW_MS;
    const fresh = !this.kind && this.log.length > 0 && performance.now() - this.log[this.log.length - 1].end < this.KEEP_MS;
    node.textContent = t;
    node.classList.toggle("on", t !== "" && (running || app.draft || fresh));
  },
};

function updateSummaryCard() {
  // An empty plate has no print: no card.
  $("summary").classList.toggle("is-empty", app.state === "empty");
  const card = $("summary");
  // A draft on the view: the print (its file, its time, its weight) is
  // of the exact slice, which follows.
  const ready = app.state === "done" && !app.draft;
  card.classList.toggle("stale", app.slicing || app.draft);
  $("export").disabled = !ready;
  // A printer with a connection: the card prints to it, and the export
  // goes to the menu of the print button (window.c).
  const pr = currentPrinter();
  const linked = !!(pr && pr.kind && pr.kind !== "none" && pr.url);
  $("send-box").hidden = !linked;
  $("export").hidden = linked;
  if (linked) {
    $("send").textContent = sending ? "Sending…" : `Print to ${KINDS[pr.kind] ?? pr.kind}`;
    // A printdeck with "Start prints from the slicer" off waits for a
    // press of Print on the deck.
    $("send").title = pr.kind === "printdeck" ? `Upload the G-code to ${pr.name} and start the print (a deck set to ask waits for a press of Print on it)` : `Upload the G-code to ${pr.name} and start the print`;
    $("send").disabled = !ready || sending;
    $("send-menu").disabled = !ready || sending;
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
  const cost = c > 0 ? ` · cost ${c.toFixed(2)}` : "";
  const fs = filamentStats();
  const changes = fs?.changes > 0 ? ` · ${fs.changes} ${fs.changes === 1 ? "change" : "changes"}` : "";
  $("sum-detail").textContent = `${st.filamentG.toFixed(1)} g · ${(st.filamentMm / 1000).toFixed(2)} m${cost} · ${st.layerCount} layers${changes}`;
  $("sum-took").textContent = work.lastText() || (app.sliceMs < 1000 ? `Sliced in ${app.sliceMs.toFixed(0)} ms` : `Sliced in ${(app.sliceMs / 1000).toFixed(1)} s`);
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
  } else if (app.simResult && simCheckText(app.simResult)) {
    // The simulated print ran: it replaces the estimate from the area that
    // hangs in the air.
    warn.hidden = false;
    warn.classList.add("sum-hint");
    const text = simCheckText(app.simResult);
    if ((value("project.support") || "off") === "off") {
      const on = el("button", "", "Turn on support");
      on.onclick = () => setSetting("project.support", "everywhere");
      warn.append(text + "Turn on support or turn the part. ", on);
    } else warn.append(text + "Turn the part, or add support there.");
  } else if (!app.simResult && app.overhang >= OVERHANG_HINT_MM2 && (value("project.support") || "off") === "off" && !(supportTool?.areas?.length > 0)) {
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
  // A Bambu Lab printer prints a .gcode.3mf file (the G-code, its MD5,
  // and the filaments of the print).
  if (String(value("machine.model") || "").startsWith("bambu-lab")) {
    const b = await client.call("bambuFile", { title: gcodeFileName(r) });
    if (b.bytes) {
      download(new Uint8Array(b.bytes), `${gcodeFileName(r)}.gcode.3mf`, "model/3mf");
      return;
    }
  }
  download(await signGcode(new Uint8Array(r.bytes)), `${gcodeFileName(r)}.gcode`, "text/x-gcode");
  await warnUnsigned();
}

// The name of a G-code file (zs_app_gcode_name, from the worker): the
// model, the plate, the layer height, the material, the printer, and the
// time, for example "3DBenchy_0.2mm_PLA_MK4_50m".
function gcodeFileName(r) {
  return r.fileName || (r.name || "part").replace(/.(stl|3mf|obj|step|stp)$/i, "");
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
  const base = (r.name || "part").replace(/.(stl|3mf|obj|step|stp)$/i, "");
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
  // A print can start as soon as the file is there: a fresh yes of the
  // person, each time. (A printdeck set to ask waits for a press on it.)
  if (print && !window.confirm(`Is the bed of ${pr.name} clear? The print starts when the file is there.`)) return;
  const r = await client.call("gcode", { plate: app.activePlate, plates: app.plates.length });
  if (!r.bytes) {
    toast("No G-code: slice first.");
    return;
  }
  const base = gcodeFileName(r);
  sending = true;
  updateSummary();
  try {
    const res = await sendToPrinter(pr, `${base}.gcode`, new Uint8Array(r.bytes), print, bambuWrap(pr, base));
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
  // With no printer of the user: the picker of a new printer.
  manage: (name) => (Object.keys(store.printers ?? {}).length ? managePrinters(name) : showPrinterPicker()),
  // A printer with no key, or a key that it refuses: the App Keys flow.
  pair: (name) => pairPrinter(name),
  canSend: () => app.state === "done",
  plateName: () => app.plates[app.activePlate]?.name || app.modelName || "the plate",
  slicedFor: () => store.printer ?? "",
  plates: () => app.plates,
  plateTotals: async () => (await client.call("plateTotals", {})).totals ?? [],
  formatTime: (s) => formatTime(s),
  sendPlate: async (i, pr) => {
    const r = await client.call("plateGcode", { index: i });
    if (!r.bytes) return { ok: false, message: "No G-code: the plate has no slice yet." };
    const base = r.fileName || (r.name || `plate-${i + 1}`).replace(/.(stl|3mf|obj|step|stp)$/i, "");
    return sendToPrinter(pr, `${base}.gcode`, new Uint8Array(r.bytes), true, bambuWrap(pr, base));
  },
  toast: (t) => toast(t),
  send: async (pr, print) => {
    const r = await client.call("gcode", { plate: app.activePlate, plates: app.plates.length });
    if (!r.bytes) return { ok: false, message: "No G-code: slice first." };
    const res = await sendToPrinter(pr, `${gcodeFileName(r)}.gcode`, new Uint8Array(r.bytes), print, bambuWrap(pr, gcodeFileName(r)));
    if (res.ok && print) project.sent();
    return res;
  },
});

// A printer that prints .gcode.3mf files (a Bambu Lab printer, alone or
// behind a deck): the deck says so in its printer list ("files"), or the
// printer has a Bambu Lab machine. The options of the send that wrap the
// signed G-code, or none.
function bambuWrap(pr, base) {
  const bambu = pr?.files === "gcode.3mf" || (!pr?.files && /^bambu-lab/.test(String(store.printers?.[pr?.name]?.profile ?? "")));
  if (!bambu) return {};
  return {
    filename: `${base}.gcode.3mf`,
    wrap: async (signed) => (await client.call("bambuFileGcode", { gcode: signed.buffer.slice(signed.byteOffset, signed.byteOffset + signed.byteLength), title: base })).bytes,
  };
}
$("send-menu").onclick = () => openMenu($("send-menu"), [
  { label: "Upload only", tip: "Upload the G-code to the printer, and do not start it.", action: () => sendGcode(false) },
  { label: "Export G-code…", action: exportGcode },
]);

// ---- the worker events ----

// A new scene of a large plate goes to the view in steps, so that each
// frame stays short while it comes. Until the last step, the frames draw
// the old scene, so the picture stays the old one. Each frame does one
// step of each kind:
// 1. It sends up to STAGE_UPLOAD bytes of the instances and of the light
//    beads to new GPU buffers (gl.stagePut).
// 2. It copies up to STAGE_COPY bytes of the scene to wasm memory, and
//    when all are there, the view reads up to STAGE_COPY bytes of them
//    into the lists of its stage (view.stageScene).
// Then a frame loads the scene (view.commitScene swaps the lists, and the
// sync of the frame uses the new GPU buffers) and handles the "sliced"
// event. With the read and the upload in one step, the frames around a
// new scene of nine Benchies were up to 0.56 s apart (Chromium, Intel HD
// 530).
const STAGE_UPLOAD = 4 << 20;
const STAGE_COPY = 16 << 20;
let staged = null;

// Starts the steps for event m, or returns false for a small scene.
function stageScene(m) {
  const inst = view.sceneSpan(m.scene, 0);
  const light = view.sceneSpan(m.scene, 1);
  if (!inst || !light || inst.count * 32 <= STAGE_UPLOAD) return false;
  const n = m.scene.byteLength;
  gl.stageBegin(inst.count, light.count);
  const up = [[inst.offset, inst.count * 32, false]];
  if (light.count > 0) up.push([light.offset, light.count * 32, true]);
  staged = { m, n, ptr: view.w.alloc(n), copied: 0, read: false, up, upAt: 0, upDone: 0 };
  requestFrame();
  return true;
}

// One step of each kind. With `all`, the rest at once (another event
// came, and the events keep their order). Returns true while steps are
// left.
function stageStep(all = false) {
  const s = staged;
  if (!s) return false;
  try {
    if (stageWork(s, all)) return true;
  } catch (e) {
    // The steps failed: the event reads the scene in one step.
    staged = null;
    if (!s.read) view.w.free(s.ptr, s.n);
    gl.stageDrop();
    gl.stageDropLight();
    s.m.noStage = true;
    onWorkerEvent(s.m);
    return false;
  }
  staged = null;
  s.m.staged = true;
  onWorkerEvent(s.m);
  return false;
}

// The steps of stageStep: true while steps are left.
function stageWork(s, all) {
  const budget = all ? Infinity : STAGE_UPLOAD;
  let left = budget;
  while (s.upAt < s.up.length && left > 0) {
    const [off, len, light] = s.up[s.upAt];
    const k = Math.min(left, len - s.upDone);
    gl.stagePut(new Uint8Array(s.m.scene, off + s.upDone, k), s.upDone, light);
    s.upDone += k;
    left -= k;
    if (s.upDone === len) {
      s.upAt++;
      s.upDone = 0;
    }
  }
  if (s.copied < s.n) {
    const c = Math.min(all ? Infinity : STAGE_COPY, s.n - s.copied);
    view.w.u8.set(new Uint8Array(s.m.scene, s.copied, c), s.ptr + s.copied);
    s.copied += c;
    if (!all) return true;
  }
  if (!s.read) {
    s.read = view.stageScene(s.ptr, s.n, all ? 0xffffffff : STAGE_COPY);
    if (s.read) view.w.free(s.ptr, s.n);
    if (!all) return true;
  }
  return s.upAt < s.up.length;
}

function onWorkerEvent(m) {
  // The slices of the other plates of the set show only on their signs.
  if ((m.event === "slicing" || m.event === "progress" || m.event === "failed") && m.plate !== undefined && m.plate !== app.shownPlate) return;
  // The table of the parts: the model drops a selected part that is gone.
  if (m.event === "parts") {
    selection.setParts(m.table);
    tools.tableChanged();
    return;
  }
  // A scene in steps comes first, so the events keep their order. The
  // history, and the plates with the same active plate, leave the view
  // of the active plate as it is: they come after each slice, and they
  // do not wait.
  const passes = m.event === "history" || (m.event === "plates" && m.active === app.shownPlate);
  if (staged && staged.m !== m && !passes) stageStep(true);
  switch (m.event) {
    case "plates":
      onPlates(m);
      break;
    case "stale":
      // A new active plate that slices again: its old slice until then.
      if (m.scene) {
        view.readScene(m.scene);
        if (m.sceneParts) selection.setScene(m.sceneParts);
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
      work.start(m.draft ? "draft" : "exact");
      $("sum-progress").hidden = false;
      $("sum-progress").firstElementChild.style.width = "0%";
      updateSummary();
      break;
    case "sim":
      // The simulated print of the slice runs in the worker.
      if (m.progress >= 1) work.end("sim");
      else {
        if (work.kind !== "sim") work.start("sim");
        work.progress(m.progress);
      }
      break;
    case "progress":
      work.progress(m.progress);
      $("sum-progress").firstElementChild.style.width = `${(m.progress * 100).toFixed(1)}%`;
      break;
    case "sliced": {
      // A large scene: the steps first (stageScene), then this event again.
      if (m.scene && !m.staged && !m.noStage && stageScene(m)) break;
      app.slicing = false;
      app.simulated = !!m.simulated;
      // A plate with a slice is not empty (also a plate that became active).
      $("empty").hidden = true;
      inspector.setStale(false);
      $("sum-progress").hidden = true;
      app.state = "done";
      // A draft keeps the numbers of the last exact slice on the print
      // card: the exact slice follows.
      app.draft = !!m.draft;
      if (m.ms > 0) {
        work.end(m.draft ? "draft" : "exact", m.ms);
        if (!m.draft) app.sliceMs = m.ms;
      } else work.text();
      if (!m.draft || !app.stats) app.stats = m.stats;
      // A "sliced" event of the simulated print has no filaments.
      if (m.filaments) setFilaments(m.filaments, m.filamentStats ?? null);
      paintTool?.refresh();
      labelTool?.refresh();
      labelTool?.reload();
      app.layers = m.layers;
      app.marks = m.marks;
      supportTool?.setAreas(m.areas);
      // A picked grid support names a line of the last slice: it ends.
      if (m.ms > 0 && supportTool?.lite && !supportTool.lite.tree) supportTool.clearLite();
      supportTool?.reloadTrees();
      // Support trees of the user that no longer fit their part.
      if (m.treeNote) toast(m.treeNote);
      app.parts = m.parts;
      app.fits = m.fits !== false;
      app.overhang = 0;
      app.issues = [];
      updateCheckCount();
      // A new slice: the simulated print was of the slice before. The
      // simulation sends its numbers for the Check, and a plate that
      // becomes active sends the numbers of its own simulation.
      app.simResult = m.ms > 0 ? null : m.sim ?? null;
      app.tiny = m.tiny ?? [];
      checkOverhang();
      // The selection, to find it again in the new slice.
      const key = refindKey();
      const first = !view.loaded;
      if (m.scene) {
        if (m.staged) {
          view.commitScene();
          gl.stageEnd(view.instancesGen(), view.lightGen());
        } else view.readScene(m.scene);
        if (m.sceneParts) selection.setScene(m.sceneParts);
        gl.setOutlines(view.outlines());
        // A live turn or move: the preview goes on from the pose of this
        // slice.
        gizmo.sliced(m);
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
      // A draft has no gap fill: its gaps are not the gaps of the print.
      if (!m.draft) gaps.refresh(layers.hi, true);
      requestFrame();
      keepSoon();
      refineSoon();
      break;
    }
    case "canceled":
      work.end("");
      break;
    case "history":
      history.refresh();
      break;
    case "fall":
      // A part lost what held it: it falls in the view.
      settleSelected(m.index);
      break;
    case "cleared":
      // An empty plate alone: nothing to keep. With other plates, the
      // session keeps the set (onPlates).
      if (app.plates.length <= 1) {
        clearTimeout(keepTimer);
        keepTimer = 0;
        clearPlate();
      }
      if (m.scene) {
        view.readScene(m.scene);
        selection.setScene(new ArrayBuffer(0));
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
      app.draft = false;
      work.end("");
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
  const before = app.shownPlate;
  // A plate added or removed: the session keeps the new list. A slice
  // keeps it too, but an empty plate has no slice.
  const ids = (p) => p.map((q) => q?.id).join(",");
  const listChanged = ids(app.plates ?? []) !== ids(m.plates);
  const grew = m.plates.length > (app.plates?.length ?? 0);
  app.plates = m.plates;
  app.shownPlate = m.active;
  selection.reportPlate(m.active, m.plates.length);
  showProjectTotals();
  if (grew && app.frameAdded) {
    selection.frame(m.active);
    app.frameAdded = false;
  }
  if (m.sync) {
    try {
      view.syncPlates(m.sync);
    } catch (e) {
      toast(e.message);
    }
  }
  if (m.active !== before) {
    // The selection and the tools are of the plate that was active.
    focusEnds();
  }
  applyFrame();
  project.showActive(m.active);
  updatePlateBar();
  requestFrame();
  // A plate added or removed: the session now, so a reload right after
  // keeps the change.
  if (listChanged) keepSoon(0);
  else if (m.active !== before) keepSoon();
}

// The selection and the tools are of the plate before.
function focusEnds() {
  stopReplay();
  select(-1, -1, false);
  tools.clear?.();
  tools.selectPart(null);
  view2d.fitted = false;
}

// The camera goes to the target of the model when it is due.
function applyFrame() {
  const t = selection.takeFrame();
  if (t === null) return;
  view.framePlate(t);
  requestFrame();
}

// Makes plate i the active plate; with `frame`, the camera goes to it.
// The model has the new plate at once. Only the reply of the last request
// changes the page.
async function activatePlate(i, frame) {
  if (i < 0 || i >= app.plates.length) return;
  if (frame) selection.frame(i);
  if (i === selection.plate) {
    applyFrame();
    return;
  }
  selection.requestPlate(i);
  focusEnds();
  updatePlateBar();
  // The labels of the Label tool are on a part of this plate.
  labelTool?.close();
  const r = await client.call("plateActivate", { index: i });
  applyFrame();
  if (selection.plate !== r.index) return;
  applySettings(r);
  const p = app.plates[r.index];
  const name = p?.name || "zslice";
  app.modelName = p?.name ?? "";
  $("title").textContent = name;
  document.title = p?.name ? `${name} · zslice` : "zslice";
  history.refresh();
}

async function addPlate() {
  app.frameAdded = true;
  const r = await client.call("plateAdd");
  app.frameAdded = false;
  applySettings(r);
  $("title").textContent = app.plates[r.index]?.name ?? "zslice";
  history.refresh();
}

// ---- copy and paste (clipboard.js) ----

var clipboard = new Clipboard({ // var: the menus can call it before this line
  client, canvas, tools, labelTool, supportTool, rangeCard, partCard, app, toast,
  menuOpen: () => menuOpen(),
  report: async () => (app.sel >= 0 ? (await client.call("report", { path: app.sel })).text ?? null : null),
  applySettings: (r) => applySettings(r),
  // Parts came onto the plate: an empty plate has a model now.
  pasted: () => {
    $("empty").hidden = true;
    if (app.state === "empty") app.state = "ready";
    history.refresh();
  },
  // A paste or a duplicate made a new plate, and it is the active plate.
  plateAdded: (r) => {
    applySettings(r);
    $("empty").hidden = true;
    if (app.state === "empty") app.state = "ready";
    $("title").textContent = app.plates[r.index]?.name ?? "zslice";
    history.refresh();
    toast(`Plate ${r.index + 1} is a copy.`);
  },
});

// Removes plate i, after a question if it has parts. The plates are not
// in the undo list, so a removal cannot be undone.
async function removePlate(i) {
  const p = app.plates[i];
  if (!p) return;
  if (p.parts > 0 && !confirm(`Remove plate ${i + 1} and its ${p.parts === 1 ? "part" : `${p.parts} parts`}? This cannot be undone.`)) return;
  const r = await client.call("plateRemove", { index: i });
  project.removed(i);
  app.refineIds?.splice(i, 1);
  applySettings(r);
  const q = app.plates[r.index];
  const name = q?.name || "zslice";
  app.modelName = q?.name ?? "";
  $("title").textContent = name;
  document.title = q?.name ? `${name} · zslice` : "zslice";
  history.refresh();
}

function updatePlateBar() {
  const n = app.plates.length;
  $("plate-name").textContent = `Plate ${app.activePlate + 1} of ${Math.max(n, 1)}`;
  $("plate-prev").disabled = app.activePlate <= 0;
  $("plate-next").disabled = app.activePlate >= n - 1;
  $("plate-all").hidden = n <= 1;
  updatePlateSigns();
}

// The signs of the plates (signs.js): drawn again when a plate, its name,
// its status, or the theme changes. The core view draws them on the bed.
// var: the project page can ask before this line.
var signKey = "";
var signTotals = [];
var signTotalsBusy = false;
function updatePlateSigns() {
  if (!view?.loaded && !app.plates?.length) return;
  const dark = isDark();
  const accent = getComputedStyle(document.documentElement).getPropertyValue("--accent-bg").trim() || "#3584e4";
  const signs = (app.plates ?? []).map((p, i) => ({
    ...signLines(p, i, signTotals[i], project?.printStatus(i)),
    active: i === app.activePlate && app.plates.length > 1,
  }));
  const key = JSON.stringify([signs, dark, accent, dpr()]);
  if (key !== signKey) {
    signKey = key;
    const d = drawSigns(signs, dark, dpr(), accent);
    try {
      view.setSigns(d.rects, d.width, d.height, d.rgba, d.scale);
    } catch (e) {
      console.warn(e);
    }
    requestFrame();
  }
  // The time and the filament of the plates with a slice: then again.
  const want = (app.plates ?? []).some((p, i) => p.status === "done" && !signTotals[i]);
  if (want && !signTotalsBusy) {
    signTotalsBusy = true;
    client
      .call("plateTotals", {})
      .then((r) => {
        signTotals = r?.totals ?? [];
        signTotalsBusy = false;
        updatePlateSigns();
      })
      .catch(() => {
        signTotalsBusy = false;
      });
  }
}
onThemeChange(() => updatePlateSigns());

// The Open button of an empty plate: small, on the middle of the active
// plate in the view, so it moves with the plate. It hides when another
// plate is in front of it or the plate is out of the view.
function placeOpenButton() {
  const box = $("empty");
  const btn = $("empty-open");
  if (box.hidden || app.page !== "3d") return;
  const k = dpr();
  const p = app.plates?.[app.activePlate];
  const bed = p?.bed?.[0] > 0 ? p.bed : (view.bedSize?.() ?? [220, 220]);
  const q = view.pixelOf(bed[0] / 2, bed[1] / 2, 0);
  const w = btn.offsetWidth;
  const h = btn.offsetHeight;
  let ok = !!q;
  if (ok) {
    const x = q[0] / k;
    const y = q[1] / k;
    ok = x - w / 2 > 4 && x + w / 2 < box.clientWidth - 4 && y - h / 2 > 4 && y + h / 2 < box.clientHeight - 4;
    // Another plate (or its parts) at the button: it hides.
    if (ok && app.plates?.length > 1) {
      for (const [dx, dy] of [[0, 0], [-w / 2, 0], [w / 2, 0], [0, -h / 2], [0, h / 2]]) {
        const i = view.plateAt((x + dx) * k, (y + dy) * k);
        if (i >= 0 && i !== app.activePlate) ok = false;
      }
    }
    if (ok) {
      btn.style.left = `${x}px`;
      btn.style.top = `${y}px`;
    }
  }
  btn.style.visibility = ok ? "" : "hidden";
}

$("plate-prev").onclick = () => activatePlate(app.activePlate - 1, true);
$("plate-next").onclick = () => activatePlate(app.activePlate + 1, true);
$("plate-all").onclick = () => {
  view.framePlate(-1);
  requestFrame();
};
$("plate-add").onclick = () => addPlate();
$("plate-remove").onclick = () => removePlate(app.activePlate);


// ---- the work across a refresh (keep.js) ----

// The session (zs_session_write): all plates, their last scenes, and the
// camera, in IndexedDB, after each change of the plates (when idle). The
// state of the page itself (the page, the panel, the scroll, the focus)
// is in localStorage (captureUi), written when it changes and when the
// page closes.
// The first change starts the timer, and later changes do not restart
// it: the plates of a project slice one after the other, and each slice
// is a change. So the session is at most 1.5 s old.
let keepTimer = 0;
let keepAgain = false;
let keepBusy = false;
// No write before the page has read the session of the last visit: the
// first plate list of the worker (an empty plate) is a change, and its
// write replaced the session before the read on some loads.
let keepOpen = false;
let keepWanted = false;
function keepSoon(delay = 1500) {
  if (!keepOpen) {
    keepWanted = true;
    return;
  }
  if (keepTimer && delay > 0) return;
  clearTimeout(keepTimer);
  keepTimer = setTimeout(async () => {
    keepTimer = 0;
    // One write at a time; a change during a write writes again after.
    if (keepBusy) {
      keepAgain = true;
      return;
    }
    keepBusy = true;
    try {
      // The tag and the map of the plates at the time of the write (the
      // write waits for a slice, and a plate can go meanwhile).
      const tag = project.sessionTag();
      const map = project.setMap ? [...project.setMap] : null;
      // The worker writes the session and keeps it: the bytes stay off
      // the main thread.
      await client.call("sessionKeep", { camera: cameraNow(), tag, map });
    } catch (e) {
      // The next change tries again.
      console.warn("zslice: the session was not saved:", e);
    } finally {
      keepBusy = false;
      if (keepAgain) {
        keepAgain = false;
        keepSoon(0);
      }
    }
  }, delay);
}

// The page goes away or hides: the session now, so a reload or a closed
// tab finds the last state.
addEventListener("pagehide", () => keepSoon(0));
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") keepSoon(0);
});

// The camera of the view: 8 floats (zs_view_get_camera).
function cameraNow() {
  const p = wasm.alloc(32);
  try {
    view.x.zs_view_get_camera(view.v, p);
    return Array.from(new Float32Array(wasm.x.memory.buffer, p, 8));
  } finally {
    wasm.free(p, 32);
  }
}

function setCamera(c) {
  if (!Array.isArray(c) || c.length !== 8) return;
  const p = wasm.alloc(32);
  try {
    new Float32Array(wasm.x.memory.buffer, p, 8).set(c);
    view.x.zs_view_set_camera(view.v, p);
  } finally {
    wasm.free(p, 32);
  }
  requestFrame();
}

// The state of the page, to come back exactly after a reload.
const UI_KEY = "zslice-ui";
// ---- refinements: the first slice is a guide ----
//
// The refinements of each plate (its changes from the first slice) go in a
// store in the browser, with the records of the past projects, and stay on
// the device. The core finds the refinements that the user made in two or
// more other projects with the same material and nozzle, and the card on
// the print card offers them.

const REFINE_KEY = "zslice-refine";
const REFINE_HIDDEN_KEY = "zslice-refine-hidden";

function loadText(key) {
  try {
    return localStorage.getItem(key) ?? "";
  } catch {
    return "";
  }
}

function saveText(key, text) {
  try {
    localStorage.setItem(key, text);
  } catch {
    // No storage: the store stays empty.
  }
}

// The id of the project of plate i in the store: one id for each plate,
// kept with the state of the page.
function refineId(i) {
  app.refineIds ??= [];
  app.refineIds[i] ??= `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  return app.refineIds[i];
}

function hiddenTips() {
  try {
    return new Set(JSON.parse(loadText(REFINE_HIDDEN_KEY) || "[]"));
  } catch {
    return new Set();
  }
}

let refineTimer = 0;
function refineSoon() {
  clearTimeout(refineTimer);
  refineTimer = setTimeout(refreshRefine, 800);
}

async function refreshRefine() {
  if (app.state !== "done") return;
  const project = refineId(app.activePlate);
  let r;
  try {
    r = await client.call("refine", { store: loadText(REFINE_KEY), project });
  } catch {
    return;
  }
  saveText(REFINE_KEY, r.store);
  const hidden = hiddenTips();
  showRefineTips(r.suggestions.filter((s) => !hidden.has(s.line)));
}

function showRefineTips(list) {
  const box = $("refine-tips");
  box.replaceChildren();
  box.hidden = list.length === 0;
  updateBadge();
  if (!list.length) return;
  const head = el("div", "refine-head");
  head.append(el("span", "", list.length === 1 ? "Your usual refinement" : `Your usual refinements: ${list.length}`));
  if (list.length > 1) {
    const all = el("button", "", "Apply all");
    all.title = "Apply each refinement (one undo step each)";
    all.onclick = async () => {
      for (const s of list) await applyRefine(s, false);
      refineSoon();
    };
    head.append(all);
  }
  box.append(head);
  for (const s of list) {
    const row = el("div", "refine-row");
    const text = el("div", "refine-text");
    text.append(document.createTextNode(`${s.where}: ${s.what}`));
    text.append(el("span", "dim", `You made this change in ${s.count} other prints.`));
    const apply = el("button", "", "Apply");
    apply.onclick = () => applyRefine(s, true);
    const hide = el("button", "", "×");
    hide.title = "Do not offer this again";
    hide.setAttribute("aria-label", "Do not offer this again");
    hide.onclick = () => {
      const h = hiddenTips();
      h.add(s.line);
      saveText(REFINE_HIDDEN_KEY, JSON.stringify([...h]));
      row.remove();
      if (!box.querySelector(".refine-row")) box.hidden = true;
      updateBadge();
    };
    row.append(text, apply, hide);
    box.append(row);
  }
  updateBadge();
}

async function applyRefine(s, refresh) {
  const r = await client.call("refineApply", { line: s.line });
  if (r.error) {
    toast(r.error);
    return;
  }
  applySettings(r);
  history.refresh();
  toast(`Applied: ${s.what}. Undo removes it.`);
  if (refresh) refineSoon();
}

function captureUi() {
  const col = (id) => $(id)?.scrollTop ?? 0;
  const f = document.activeElement;
  const focus = f && f !== document.body ? {
    id: f.id || "",
    setting: f.closest?.("[data-setting]")?.dataset.setting ?? "",
    start: typeof f.selectionStart === "number" ? f.selectionStart : null,
    end: typeof f.selectionEnd === "number" ? f.selectionEnd : null,
  } : null;
  return {
    camera: cameraNow(),
    page: app.page,
    tool: tools.tool,
    mode: app.mode,
    layers: { lo: layers.lo, hi: layers.hi, count: layers.count },
    panel: { selected: !$("page-selected").hidden, column: browser.column, group: browser.group, section: browser.section, search: browser.search, key: browser.key },
    scroll: { sections: col("col-sections"), settings: col("col-settings"), detail: col("col-detail"), selected: col("page-selected") },
    history: !$("history-pop").hidden,
    farm: !$("farm-view").hidden,
    part: tools.part?.index ?? -1,
    focus,
    refineIds: app.refineIds ?? [],
  };
}

let uiText = "";
function keepUi() {
  try {
    const t = JSON.stringify(captureUi());
    if (t === uiText) return;
    uiText = t;
    localStorage.setItem(UI_KEY, t);
  } catch {
    // No storage: no restore.
  }
}

function loadUi() {
  try {
    return JSON.parse(localStorage.getItem(UI_KEY) ?? "null");
  } catch {
    return null;
  }
}

// ---- open a model ----

// Saves all plates as one project file (zs_set_project_save): a 3MF file
// that zslice opens with its plates, and other slicers as its first plate.
async function saveProject() {
  try {
    const name = (app.plates[0]?.name || app.modelName || "project").replace(/.(stl|3mf|obj|step|stp)$/i, "");
    const r = await client.call("projectSave", { name });
    download(new Uint8Array(r.bytes), `${name}.3mf`, "model/3mf");
    history.markSaved();
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
  if (/\.zip$/i.test(file.name)) {
    await importZip(file);
    return;
  }
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
        history.markSaved();
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
    history.markSaved();
  } catch (e) {
    toast(e.message);
  }
}

// "Add models…": more parts on the plate (zs_app_add_stl).
async function addFiles(files) {
  for (const file of files) {
    if (/\.zip$/i.test(file.name)) {
      await importZip(file);
      continue;
    }
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

$("open").onclick = () => openMenu($("open"), [
  { label: "Open a model…", action: () => $("file").click() },
  { label: "Add models to this plate…", disabled: app.state === "empty", action: () => addModels() },
  { label: "Save project…", disabled: app.state === "empty", action: () => saveProject() },
  { label: "Import from a model page…", detail: "Printables or Thingiverse", action: () => askImportPage(new ImportRules(wasm)) },
  { label: "Open links from model sites here", detail: "web+zslice:// links", action: () => toast(registerLinks(), 9000) },
  ...projectItems(),
]);
// + adds models to the active plate; Open replaces the active plate.
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
  closed: () => noteFocus(),
  actions: () => [
    { label: "Open a model…", keys: "Ctrl+O", run: () => $("file").click() },
    { label: "Add models to the plate…", run: () => addModels() },
    { label: "Import from a model page…", hint: "Printables or Thingiverse: choose the files to load", run: () => askImportPage(new ImportRules(wasm)) },
    { label: "Export G-code…", keys: "Ctrl+E", run: () => exportGcode() },
    { label: "Test print the top layer", hint: "the layer alone, on the bed", run: () => debugPrint(true) },
    { label: "Test print the layers shown", hint: "the layers of the slider alone, on the bed", run: () => debugPrint(false) },
    { label: "Save the project…", keys: "Ctrl+S", hint: "all plates in one 3MF file", run: () => saveProject() },
    { label: "Print", hint: "send the G-code to the printer and start", run: () => sendGcode(true) },
    { label: "Arrange the plate", hint: "pack the parts on the bed", run: () => client.call("plate", { action: "arrange" }) },
    { label: "Smart placement", hint: "turn and arrange the parts", run: () => client.call("plate", { action: "smart" }) },
    { label: "Remove this plate", hint: "the plate and its parts", run: () => removePlate(app.activePlate) },
    { label: "Check the print", hint: "problems and advice", run: () => openCheck() },
    { label: "The print as it forms", hint: "simulated plastic: it sags and droops where nothing holds it", run: () => toggleSimulation() },
    { label: "Label tool", keys: "E", hint: "text and marks on the surface of a part, in another filament", run: () => labelTool.open() },
    { label: "Undo", keys: "Ctrl+Z", run: () => undoRedo("undo") },
    { label: "Redo", keys: "Ctrl+Shift+Z", run: () => undoRedo("redo") },
    { label: "2D layer view", keys: "2", run: () => showPage("2d") },
    { label: "3D view", keys: "3", run: () => showPage("3d") },
    { label: "Import a profile…", hint: "PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura settings", run: () => importProfile() },
    ...CALIBRATIONS.map((c) => ({ label: `Calibrate: ${c.label}`, hint: `${c.tip}, on a new plate`, run: () => calibrate(c.kind) })),
    { label: "Calibrate: use a value of this test…", hint: "how to read the test, and its values", run: () => showCalibration() },
    { label: "Manage printers…", run: () => managePrinters() },
    { label: project.openName() ? "The project" : "Open a project", hint: project.openName() ?? "printdeck.yml from GitHub or a folder", run: () => showTab("project") },
    ...(project.openName() ? [{ label: "Close the project", hint: `${project.openName()}: its plates stay`, run: () => closeProject() }] : []),
    { label: "History", hint: "the changes, undo one change", run: () => showTab("history") },
    { label: "Keyboard shortcuts", keys: "?", run: () => shortcuts.show() },
    { label: "All settings", keys: "N", hint: "the panel of the settings", run: () => showTab("settings") },
    { label: "Speed settings", hint: "faster slicing, fast offsets, resolution, gap fill: the print settings that change the time of a slice", run: () => showSpeed() },
    { label: "Preferences…", keys: PREFS_ACCEL, hint: "threads, draft slices, the print as it forms after each slice, theme, first view, printers", run: () => showPreferences() },
    { label: app.snapshot?.speed === "on" ? "Faster slicing off" : "Faster slicing on", hint: "speed, performance: faster offsets and outline tolerance 0.01 mm", run: () => setFasterSlicing(app.snapshot?.speed !== "on") },
    { label: "Printers", hint: "your printers, their jobs, and the plates to print", run: () => showFarm(true) },
  ],
});
const shortcuts = new ShortcutSheet();



// ---- the worker starts ----

// A printer that serves this page (for example a printdeck on the LAN) can
// put printer.json next to it: { "name", "kind", "url" (empty: this
// server), "profile" (a machine profile text, optional) }. The app adds
// that printer, and uses it when no printer is set up yet.
async function hostPrinter() {
  // The public site of zslice has no printer of its own: no request (it
  // only gave a 404 in the console at each start).
  if (location.hostname === "zslice.beetlebug.org") return;
  let p = null;
  try {
    const r = await fetch("printer.json", { cache: "no-store" });
    if (!r.ok) return;
    p = await r.json();
  } catch {
    return;
  }
  if (!plainName(p?.name) || !Object.hasOwn(KINDS, p.kind)) return;
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
  // A deck that drives more than one printer lists them: each one is a
  // printer of its own, at <base>/printers/<id> (the first at the base),
  // with its own API key, and its label and color, so the user sees which
  // is which.
  if (Array.isArray(p.printers) && p.printers.length > 1) {
    const base = (p.url || location.origin).replace(/\/$/, "");
    const httpsBase = (p.https || "").replace(/\/$/, "");
    for (const q of p.printers) {
      if (!plainName(q?.name) || q.kind === "resin") continue;
      const sub = typeof q.url === "string" ? q.url : "";
      // The first printer is at the base: the deck's own entry.
      if (sub === "") {
        Object.assign(store.printers[p.name], { color: q.color || "", label: q.label || "", deckName: q.name });
        continue;
      }
      const name = q.label && q.label !== q.name ? `${q.name} (${q.label})` : q.name;
      const had = store.printers[name];
      store.printers[name] = {
        profile: had?.profile ?? store.printers[p.name].profile,
        url: base + sub,
        kind: "printdeck",
        apiKey: had?.apiKey ?? "",
        https: httpsBase ? httpsBase + sub : "",
        color: q.color || had?.color || "",
        label: q.label || "",
        deckName: q.name,
        files: q.files || "",
        model: q.model || "",
      };
    }
  }
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

// Puts each saved printer of a deck on its own address. An older pairing
// at the address of one printer of the deck gave the printer at the root
// of the deck (url "") that same address, so two entries showed one
// printer (issue #24). The deck lists its printers: each saved printer
// with a deckName takes the path of the printer of that name. In the
// background, with no wait for the start.
async function repairDeckPrinters() {
  const decks = new Map();
  for (const [name, pr] of Object.entries(store.printers ?? {})) {
    if (pr?.kind !== "printdeck" || !pr.deckName || !pr.url) continue;
    const root = deckRoot(pr.url).replace(/\/$/, "");
    if (!decks.has(root)) decks.set(root, []);
    decks.get(root).push([name, pr]);
  }
  let changed = false;
  for (const [root, list] of decks) {
    if (list.length < 2) continue;
    const [, any] = list[0];
    const dp = await deckPrinters({ ...any, name: list[0][0] }).catch(() => null);
    if (!dp?.ok) continue;
    const hroot = (dp.https || deckRoot(any.https || "") || "").replace(/\/$/, "");
    for (const [, pr] of list) {
      const q = dp.printers.find((x) => x?.name === pr.deckName);
      if (!q) continue;
      const url = q.url ? deckAddress(root, q.url) : root + "/";
      const https = hroot ? (q.url ? deckAddress(hroot, q.url) : hroot + "/") : pr.https || "";
      if (url && url.replace(/\/$/, "") !== pr.url.replace(/\/$/, "")) {
        pr.url = url;
        changed = true;
      }
      if (https && https.replace(/\/$/, "") !== (pr.https || "").replace(/\/$/, "")) {
        pr.https = https;
        changed = true;
      }
    }
  }
  if (changed) {
    saveStore();
    toast("The printers of a deck pointed at one printer. Each one has its own address again.", 8000);
  }
}
repairDeckPrinters();

const init = await client.call("init", { module, saved: store.saved ?? null, mode: app.mode });
if (init.errors?.length) toast(`Some saved settings did not load: ${init.errors.join("; ")}`);
applySettings(init);
history.refresh();
updateSummary();
resize();


// The session of the last visit (keep.js), when the page has no model to
// open: the plates come back with their last scenes at once, then the
// camera, the layers, the panel, the scroll, and the focus.
const modelUrl = new URLSearchParams(location.search).get("model");
let restored = false;
if (!modelUrl) {
  // With a project, only a session of its plates (they keep the user's
  // changes); else the plates load from the project again.
  const s = await loadSession();
  const tag = project.sessionTag();
  if (s?.bytes && (!project.willRestore() || s.tag === tag)) {
    try {
      const r = await client.call("sessionRead", { bytes: s.bytes });
      applySettings(r);
      $("empty").hidden = true;
      app.state = "ready";
      restored = true;
      if (project.willRestore()) {
        // A plate removed after the last write of the session: the map
        // of the project has it no more (project.js keeps it at once).
        const want = project.state?.setMap;
        if (Array.isArray(want) && Array.isArray(s.map)) {
          for (let k = s.map.length - 1; k >= 0; k--) {
            if (!want.includes(s.map[k])) applySettings(await client.call("plateRemove", { index: k }));
          }
        }
        project.adopt();
      }
      const name = app.plates[r.index]?.name || app.plates[0]?.name || "";
      if (name) {
        app.modelName = name;
        $("title").textContent = name;
        document.title = `${name} · zslice`;
      }
      await restoreUi(r.camera);
    } catch {
      // A session of another version: the plate of keep.js below.
    }
  }
}
// The saved printdeck.yml project: its plan, and its plates again if no
// session of them came back.
project.start();
// The UI state of the page, after the plates are back.
async function restoreUi(camera) {
  const u = loadUi();
  if (Array.isArray(u?.refineIds)) app.refineIds = u.refineIds;
  if (u?.page && u.page !== app.page) showPage(u.page);
  if (u?.tool) tools.set(u.tool);
  setCamera(u?.camera ?? camera);
  if (u?.panel) {
    if (u.panel.key) browser.openSetting(u.panel.key);
    else if (u.panel.column > 0 && u.panel.group) browser.showColumn?.(u.panel.column);
  }
  if (u?.history) toggleHistory(true);
  if (u?.farm) showFarm(true);
  // The layers and the scroll after the first slice is shown.
  const later = () => {
    if (u?.layers && layers.count === u.layers.count) layers.set(u.layers.lo, u.layers.hi, false);
    for (const [k, id] of [["sections", "col-sections"], ["settings", "col-settings"], ["detail", "col-detail"], ["selected", "page-selected"]]) {
      if ($(id) && u?.scroll?.[k]) $(id).scrollTop = u.scroll[k];
    }
    const f = u?.focus;
    if (f) {
      const el = f.id ? $(f.id) : f.setting ? document.querySelector(`[data-setting="${CSS.escape(f.setting)}"] input, [data-setting="${CSS.escape(f.setting)}"] textarea, [data-setting="${CSS.escape(f.setting)}"] select`) : null;
      if (el) {
        el.focus({ preventScroll: true });
        if (f.start != null && el.setSelectionRange) try { el.setSelectionRange(f.start, f.end ?? f.start); } catch { /* not a text field */ }
      }
    }
  };
  requestAnimationFrame(() => requestAnimationFrame(later));
  setTimeout(later, 1500);
}
// The state of the page goes to localStorage when it changes, and when
// the page closes.
setInterval(keepUi, 1000);
addEventListener("pagehide", () => {
  keepUi();
  keepSoon();
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") keepUi();
});
if (!modelUrl && !restored) {
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
// The session of the last visit is back (or there was none): from now
// on, changes write the session. A change during the read writes now.
keepOpen = true;
if (keepWanted && (restored || modelUrl)) keepSoon();

// The first visit (no printer set up), and the test hook
// ?printers&q=<search>&pick=<model id>&step=2: the printer picker.
const params = new URLSearchParams(location.search);
if (params.has("printers") || (!restored && !store.printer && !stateHasChanges(store.saved?.machine) && !params.has("model"))) {
  showPrinterPicker({ query: params.get("q"), model: params.get("pick"), step: params.get("step"), welcome: !params.has("printers") });
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

// ---- a link that opens a model (openlink.js) ----
//
// ?open=<web+zslice:// link or https URL>: the dialog asks first. The
// file opens on a new plate if the plate has parts. It never prints.

async function openLinkFile(bytes, name) {
  const file = new File([bytes], name);
  if (app.state === "empty") {
    await openFile(file);
    return;
  }
  await addPlate();
  await addFiles([file]);
}

// ---- import a model from a model page or a ZIP file (modelimport.js) ----

// The files of a ZIP file: the user checks the files to load. They go on
// a new plate (if the plate has parts), and the parts that do not fit go
// on more plates. It never prints.
async function importZip(file) {
  const rules = new ImportRules(wasm);
  let list;
  try {
    list = rules.listZip(new Uint8Array(await file.arrayBuffer()));
  } catch (e) {
    toast(`${file.name}: ${e.message}`);
    return;
  }
  showImportList(list, file.name, loadImported);
}

async function loadImported(files, errors) {
  // A zslice project replaces the plates: the user opens it with Open.
  const good = [];
  for (const f of files) {
    if (wasm.withBytes(f.bytes, (p, n) => wasm.x.zs_project_file_is(p, n)) !== 0) errors.push(`${f.name}: ${new LinkRules(wasm).message(LINK.project)}`);
    else good.push(new File([f.bytes], f.name));
  }
  if (good.length) {
    if (app.state === "empty") {
      await openFile(good[0]);
      await addFiles(good.slice(1));
    } else {
      await addPlate();
      await addFiles(good);
    }
    const r = await client.call("spill");
    const plates = 1 + (r?.plates ?? 0);
    toast(`${good.length} ${good.length === 1 ? "file" : "files"} on ${plates} ${plates === 1 ? "plate" : "plates"}.`);
  }
  if (errors.length) toast(errors.join("\n"), 9000);
}

function askOpenLink(text) {
  const rules = new LinkRules(wasm);
  const link = rules.check(text);
  // A link to a model page: the page of the import says how to get its
  // files.
  if (link.ok) {
    const page = new ImportRules(wasm).page(link.url);
    if (page.ok) {
      askImportPage(new ImportRules(wasm), page.url);
      return;
    }
  }
  const d = document.createElement("dialog");
  d.className = "printers-dialog pair-dialog";
  const title = Object.assign(document.createElement("h3"), { textContent: link.ok ? "Open this model?" : "This link did not open" });
  const name = Object.assign(document.createElement("p"), { className: "pair-text", textContent: link.ok ? link.name || "A model file" : link.why });
  const from = Object.assign(document.createElement("p"), { className: "pair-count", textContent: link.ok ? `From ${link.host}` : "" });
  const note = Object.assign(document.createElement("p"), {
    className: "dim pair-count",
    textContent: link.ok ? "zslice downloads the file and opens it on a new plate. It does not start a print." : "",
  });
  const bar = Object.assign(document.createElement("div"), { className: "pair-actions" });
  const cancel = Object.assign(document.createElement("button"), { textContent: link.ok ? "Cancel" : "Close" });
  const go = Object.assign(document.createElement("button"), { className: "suggested", textContent: "Download and open" });
  const byHand = Object.assign(document.createElement("button"), { textContent: "Download the file" });
  byHand.hidden = true;
  go.hidden = !link.ok;
  bar.append(cancel, byHand, go);
  d.append(title, name, from, note, bar);
  document.body.append(d);
  let abort = null;
  const close = () => {
    abort?.abort();
    d.close();
    d.remove();
  };
  cancel.onclick = close;
  d.oncancel = (e) => {
    e.preventDefault();
    close();
  };
  // The browser downloads the file to the Downloads folder. The user
  // then drops it on the window or opens it with Open.
  byHand.onclick = () => {
    window.open(link.url, "_blank", "noopener,noreferrer");
    note.textContent = "Then drop the file on this window, or open it with Open.";
    byHand.hidden = true;
  };
  go.onclick = async () => {
    go.disabled = true;
    note.classList.remove("error");
    note.textContent = "Downloading…";
    abort = new AbortController();
    try {
      const got = await downloadModel(rules, link, {
        signal: abort.signal,
        onProgress: (f) => {
          note.textContent = `Downloading… ${Math.round(f * 100)}%`;
        },
      });
      abort = null;
      close();
      await openLinkFile(got.bytes, got.name);
    } catch (e) {
      abort = null;
      if (e?.name === "AbortError") return;
      go.disabled = false;
      go.hidden = !!e.cors;
      byHand.hidden = !e.cors;
      note.textContent = e.message;
      note.classList.add("error");
    }
  };
  d.showModal();
  // Enter must not start a download that the user did not read.
  cancel.focus();
}

const openParam = new URLSearchParams(location.search).get("open");
if (openParam) {
  // A reload must not ask again.
  const u = new URL(location.href);
  u.searchParams.delete("open");
  window.history.replaceState(null, "", u.pathname + u.search + u.hash);
  askOpenLink(openParam);
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
  wasm,
  project,
  clipboard,
  labelTool,
  camera: () => cameraNow(),
  rangeCard,
  search,
  shortcuts,
  partCard,
  paintTool,
  gizmo,
  supportTool,
  app, work, view, view2d, layers, browser, client, gl, inspector, gaps, history, undoRedo, tools, store, managePrinters, openPrinterSettings, loadProfile, setSetting, pickAt, topLayerPoint, openCheck, frameTimes,
  select, showPage, showTab, hitAt, showContextMenu, step, bench, benchPick, settleSelected,
  get frameCount() { return frameCount; },
  get pickMs() { return pickMs; },
  requestFrame,
  openFile, addPlate, activatePlate,
  drawNow: () => drawFrame(performance.now()),
};
