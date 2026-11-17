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
import { Client } from "./client.js";
import { View3D, MODES } from "./view.js";
import { GlRenderer } from "./gl.js";
import { View2D } from "./view2d.js";
import { LayerRange } from "./layers.js";
import { SettingsBrowser } from "./settings.js";
import { Inspector } from "./inspector.js";
import { contextItems } from "./context-menu.js";
import { openMenu, openMenuAt, menuOpen } from "./menus.js";
import { formatClock, formatTime } from "./format.js";
import { openPrinterPicker } from "./printers.js";

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
function toast(text) {
  const t = $("toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 5000);
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

async function compileModule() {
  const url = new URL("zslice.wasm", import.meta.url);
  try {
    return await WebAssembly.compileStreaming(fetch(url));
  } catch {
    // A server with another MIME type for .wasm.
    const r = await fetch(url);
    return WebAssembly.compile(await r.arrayBuffer());
  }
}

const module = await compileModule();
const wasm = await Wasm.create(module);
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
};

const client = new Client(onWorkerEvent);

// ---- the 3D view ----

const canvas = $("gl");
const gl = new GlRenderer(canvas);
const view = new View3D(wasm, 16, 16);
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
  const f = view.frame();
  if (app.page === "2d") {
    gl.sync(f);
    const dim = (app.isolate && app.sel >= 0) || (app.focus2d && app.focusFirst && layers.hi !== 0) ? 1 : 0;
    view2d.draw(f.width, f.height, layers.hi, app.sel, app.seg, app.focus2d, dim);
  } else {
    gl.draw(f);
  }
  frameTimes[frameCount++ % frameTimes.length] = performance.now() - t0;
  if (more) requestFrame();
  else lastFrameTime = 0;
}

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
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
  view.resize(w, h);
  requestFrame();
}
new ResizeObserver(resize).observe(canvas);

// The mouse, as in Cura and Tinkercad. In 3D: a left or a right drag
// orbits, a middle drag (or Shift and a drag) pans, and the wheel zooms
// toward the pointer (linux/src/ui/view3d.c); a trackpad pinch zooms too.
// In 2D: a drag pans, and the wheel zooms (preview.c). In both: a click (a
// release within 4 pixels of the press) selects the line under the
// pointer, and a right click opens the context menu there.
let drag = null;
const dpr = () => window.devicePixelRatio || 1;

canvas.addEventListener("pointerdown", (e) => {
  canvas.setPointerCapture(e.pointerId);
  drag = { button: e.button, x: e.clientX, y: e.clientY, x0: e.clientX, y0: e.clientY, moved: false };
  canvas.style.cursor = "grabbing";
  canvas.focus({ preventScroll: true });
});
canvas.addEventListener("pointermove", (e) => {
  if (!drag) return;
  const dx = e.clientX - drag.x;
  const dy = e.clientY - drag.y;
  drag.x = e.clientX;
  drag.y = e.clientY;
  if (dx === 0 && dy === 0) return;
  if (Math.abs(e.clientX - drag.x0) > 4 || Math.abs(e.clientY - drag.y0) > 4) drag.moved = true;
  if (app.page === "2d") {
    if (drag.button !== 2) view2d.pan(dx * dpr(), dy * dpr());
  } else if (drag.button === 1 || e.shiftKey) view.pan(dx * dpr(), dy * dpr());
  else view.orbit(dx, dy);
  requestFrame();
});
canvas.addEventListener("pointerup", (e) => {
  const d = drag;
  endDrag();
  if (!d || d.moved || !view.loaded) return;
  const r = canvas.getBoundingClientRect();
  const px = (e.clientX - r.left) * dpr();
  const py = (e.clientY - r.top) * dpr();
  if (d.button === 0) pickAt(px, py, true);
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
canvas.addEventListener("dblclick", () => {
  if (app.page === "2d") {
    view2d.fit(canvas.width, canvas.height);
  } else {
    view.resetSmooth();
  }
  requestFrame();
});
canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  const r = canvas.getBoundingClientRect();
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

// A click: the line there (its segment too), or no selection.
function pickAt(px, py, picked) {
  if (hitAt(px, py)) select(view.hit[0], view.hit[1], picked);
  else select(-1, -1, false);
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
  const mask = settingsVisible ? app.focusMask : 0;
  const zmax = app.focusFirst && app.layers?.z?.length ? app.layers.z[0] : -1;
  view.focus(mask, zmax);
  app.focus2d = mask;
  requestFrame();
}

async function setSetting(name, value) {
  try {
    const r = await client.call("set", { name, value });
    applySettings(r);
    return r.error;
  } catch (e) {
    return e.message;
  }
}

const browser = new SettingsBrowser({
  infos,
  effect: (name) => wasm.settingEffect(name),
  set: setSetting,
  reset: async (name) => applySettings(await client.call("reset", { name })),
  focus: (mask, first) => {
    app.focusMask = mask;
    app.focusFirst = first;
    updateFocus();
  },
});

// The answer of the worker to a change: the values, and the state to keep.
function applySettings(r) {
  if (!r?.values) return;
  app.snapshot = r;
  browser.setValues(r);
  if (r.saved) {
    store.saved = r.saved;
    saveStore();
  }
  updateMenus();
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
  if (group === 0) store.printer = name;
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
  items.push({ sep: true }, { label: "Add a printer…", action: () => showPrinterPicker() });
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
  { label: "Export G-code…", disabled: app.state !== "done", action: exportGcode },
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

// ---- the panel tabs ----

function showTab(name) {
  $("tab-settings").classList.toggle("checked", name === "settings");
  $("tab-selected").classList.toggle("checked", name === "selected");
  $("page-settings").hidden = name !== "settings";
  $("page-selected").hidden = name !== "selected";
  updateFocus();
}
$("tab-settings").onclick = () => showTab("settings");
$("tab-selected").onclick = () => showTab("selected");
$("panel-back").onclick = () => browser.back();

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
$("view-3d").title = "3D: the layers up to the slider. A left or right drag orbits, a middle drag pans, scroll to zoom, double-click to reset.";
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
  $("isolate").hidden = path < 0;
  requestFrame();
  if (picked && path >= 0) showTab("selected");
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
  app.info = r.info;
  if (refind) {
    // The same line in the new slice, or none.
    const path = r.info ? r.info.path : -1;
    app.sel = path;
    if (path < 0) app.seg = -1;
    else app.seg = Math.min(app.seg, view.pathSegments(path) - 1);
    view.highlight(app.sel, app.seg, app.isolate);
    $("isolate").hidden = app.sel < 0;
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

$("isolate").onclick = () => {
  app.isolate = !app.isolate;
  store.isolate = app.isolate;
  saveStore();
  $("isolate").classList.toggle("checked", app.isolate);
  view.highlight(app.sel, app.seg, app.isolate);
  requestFrame();
};
$("isolate").classList.toggle("checked", app.isolate);

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

function onPreviewKey(e) {
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
    case "c": case "C":
      if (e.key === "C" || e.shiftKey) showAllLayers();
      else if (app.sel >= 0) cutToSelection();
      else return;
      e.preventDefault();
      return;
    case "Escape":
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

// ---- the print card ----

function updateSummary() {
  const card = $("summary");
  card.classList.toggle("stale", app.slicing);
  $("export").disabled = app.state !== "done";
  if (app.slicing) return;
  if (app.state !== "done" || !app.stats) {
    $("sum-time").textContent = app.state === "failed" ? "Slice failed" : "—";
    $("sum-detail").textContent = "";
    $("sum-took").textContent = "";
    return;
  }
  const st = app.stats;
  $("sum-time").textContent = formatTime(st.printTimeS);
  const perG = Number(value("filament.price_per_kg")) / 1000;
  const cost = perG > 0 ? ` · ${(st.filamentG * perG).toFixed(2)}` : "";
  $("sum-detail").textContent = `${st.filamentG.toFixed(1)} g · ${(st.filamentMm / 1000).toFixed(2)} m${cost} · ${st.layerCount} layers`;
  $("sum-took").textContent = app.sliceMs < 1000 ? `Sliced in ${app.sliceMs.toFixed(0)} ms` : `Sliced in ${(app.sliceMs / 1000).toFixed(1)} s`;
}

async function exportGcode() {
  if (app.state !== "done") return;
  const r = await client.call("gcode");
  if (!r.bytes) {
    toast("No G-code: slice first.");
    return;
  }
  const base = (r.name || "part").replace(/\.(stl|3mf)$/i, "");
  download(r.bytes, `${base}.gcode`, "text/x-gcode");
}
$("export").onclick = exportGcode;

// ---- the worker events ----

function onWorkerEvent(m) {
  switch (m.event) {
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
      inspector.setStale(false);
      $("busy").hidden = true;
      $("sum-progress").hidden = true;
      app.state = "done";
      if (m.ms > 0) app.sliceMs = m.ms;
      app.stats = m.stats;
      app.layers = m.layers;
      app.marks = m.marks;
      app.parts = m.parts;
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
      requestFrame();
      break;
    }
    case "cleared":
      // An empty plate.
      if (m.scene) {
        view.readScene(m.scene);
        gl.setOutlines(view.outlines());
      }
      app.state = "empty";
      app.stats = null;
      layers.setLayers(0, null, null);
      $("scrub").hidden = true;
      $("empty").hidden = false;
      $("title").textContent = "zslice";
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

// ---- open a model ----

async function openFile(file) {
  if (!file) return;
  stopReplay();
  const bytes = await file.arrayBuffer();
  try {
    await client.call("load", { name: file.name, bytes }, [bytes]);
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
$("add").onclick = () => $("file").click();
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
  }
});

// ---- the worker starts ----

const init = await client.call("init", { module, saved: store.saved ?? null, mode: app.mode });
if (init.errors?.length) toast(`Some saved settings did not load: ${init.errors.join("; ")}`);
applySettings(init);
updateSummary();
resize();

// The first visit (no printer set up), and the test hook
// ?printers&q=<search>&pick=<model id>&step=2: the printer picker.
const params = new URLSearchParams(location.search);
if (params.has("printers") || (!store.printer && !stateHasChanges(store.saved?.machine) && !params.has("model"))) {
  showPrinterPicker({ query: params.get("q"), model: params.get("pick"), step: params.get("step"), welcome: !params.has("printers") });
}

// A test hook: ?model=<url> opens a model at the start.
const modelUrl = new URLSearchParams(location.search).get("model");
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
  app, view, view2d, layers, browser, client, gl, inspector, frameTimes,
  select, showPage, showTab, hitAt, showContextMenu, step, bench, benchPick,
  get frameCount() { return frameCount; },
  get pickMs() { return pickMs; },
  requestFrame,
  drawNow: () => drawFrame(performance.now()),
};
