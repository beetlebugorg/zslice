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
import { LayerRange } from "./layers.js";
import { SettingsBrowser } from "./settings.js";
import { openMenu } from "./menus.js";
import { formatClock, formatTime } from "./format.js";

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
};

const client = new Client(onWorkerEvent);

// ---- the 3D view ----

const canvas = $("gl");
const gl = new GlRenderer(canvas);
const view = new View3D(wasm, 16, 16);
let frameQueued = false;
let lastFrameTime = 0;

function requestFrame() {
  if (frameQueued) return;
  frameQueued = true;
  requestAnimationFrame(drawFrame);
}

function drawFrame(now) {
  frameQueued = false;
  const dt = lastFrameTime ? Math.min(0.1, (now - lastFrameTime) / 1000) : 1 / 60;
  lastFrameTime = now;
  let more = view.animate(dt);
  if (replay.playing) {
    stepReplay(dt);
    more = more || replay.playing;
  }
  gl.draw(view.frame());
  if (more) requestFrame();
  else lastFrameTime = 0;
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

// The mouse, as in Cura and Tinkercad: a left or a right drag orbits, a
// middle drag (or Shift and a drag) pans, and the wheel zooms toward the
// pointer (linux/src/ui/view3d.c). A trackpad pinch zooms too.
let drag = null;
canvas.addEventListener("pointerdown", (e) => {
  canvas.setPointerCapture(e.pointerId);
  drag = { button: e.button, x: e.clientX, y: e.clientY, moved: false };
  canvas.style.cursor = "grabbing";
});
canvas.addEventListener("pointermove", (e) => {
  if (!drag) return;
  const dx = e.clientX - drag.x;
  const dy = e.clientY - drag.y;
  drag.x = e.clientX;
  drag.y = e.clientY;
  if (dx === 0 && dy === 0) return;
  drag.moved = true;
  const dpr = window.devicePixelRatio || 1;
  if (drag.button === 1 || e.shiftKey) view.pan(dx * dpr, dy * dpr);
  else view.orbit(dx, dy);
  requestFrame();
});
const endDrag = () => {
  drag = null;
  canvas.style.cursor = "";
};
canvas.addEventListener("pointerup", endDrag);
canvas.addEventListener("pointercancel", endDrag);
canvas.addEventListener("contextmenu", (e) => e.preventDefault());
canvas.addEventListener("dblclick", () => {
  view.resetSmooth();
  requestFrame();
});
canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  const dpr = window.devicePixelRatio || 1;
  const r = canvas.getBoundingClientRect();
  // One wheel step is about 100 pixels (deltaMode 0) or 3 lines.
  // A pinch on a trackpad comes as a wheel event with Ctrl and small
  // steps, so it counts more for each pixel.
  const px = e.ctrlKey ? 25 : 100;
  const steps = e.deltaMode === 1 ? e.deltaY / 3 : e.deltaMode === 2 ? e.deltaY : e.deltaY / px;
  view.zoomAt(Math.pow(1.15, steps), (e.clientX - r.left) * dpr, (e.clientY - r.top) * dpr);
  requestFrame();
}, { passive: false });

// ---- the layer slider and the replay ----

const layers = new LayerRange($("layers"), (lo, hi) => {
  stopReplay();
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
  if (f >= 1) view.setLayerRange(layers.lo, layer);
  else view.setTime(t0 + f * (t1 - t0));
  showScrub(layer, t0 + f * (t1 - t0));
  requestFrame();
});

function setPlayIcon(playing) {
  $("play-icon").setAttribute("d", playing ? "M4 2.5h3v11H4z M9 2.5h3v11H9z" : "M4 2.5v11l9-5.5z");
}

function startReplay() {
  if (!view.loaded) return;
  const d = view.duration();
  if (replay.t <= 0 || replay.t >= d) replay.t = 0;
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
    client.call("mode", { value: i });
  },
})));

// ---- the settings ----

function updateFocus() {
  const settingsVisible = !$("page-settings").hidden;
  const mask = settingsVisible ? app.focusMask : 0;
  const zmax = app.focusFirst && app.layers?.z?.length ? app.layers.z[0] : -1;
  view.focus(mask, zmax);
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

$("printer-menu").onclick = () => {
  const items = [{ title: "Built-in" }];
  for (const n of wasm.builtinProfiles(0)) {
    items.push({ label: n, checked: n === (store.printer || "generic"), action: () => loadProfile(0, n, `extends = "${n}"\n`) });
  }
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
    case "sliced":
      app.slicing = false;
      $("busy").hidden = true;
      $("sum-progress").hidden = true;
      app.state = "done";
      if (m.ms > 0) app.sliceMs = m.ms;
      app.stats = m.stats;
      app.layers = m.layers;
      if (m.scene) view.readScene(m.scene);
      layers.setLayers(m.layers.z.length, m.layers.slowed, m.layers.z);
      if (!replay.playing) view.setLayerRange(layers.lo, layers.hi);
      showScrub(layers.hi, null);
      $("scrub").hidden = false;
      browser.setFeatureStats(m.featureStats);
      showLegend();
      updateFocus();
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
    app.modelName = file.name;
    $("title").textContent = file.name;
    document.title = `${file.name} · zslice`;
    $("empty").hidden = true;
    app.state = "ready";
  } catch (e) {
    toast(e.message);
  }
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

// A test hook: ?model=<url> opens a model at the start.
const modelUrl = new URLSearchParams(location.search).get("model");
if (modelUrl) {
  const r = await fetch(modelUrl);
  const name = decodeURIComponent(modelUrl.split("/").pop() || "model.stl");
  await openFile(new File([await r.arrayBuffer()], name));
}

// For tests: the state of the page.
window.zslice = { app, view, layers, browser, client, gl };
