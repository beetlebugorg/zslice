// format.js: the text of setting values, as the GTK shell shows them
// (linux/src/ui/setting-editor.c): a ratio as a percentage, a line width of
// 0 as "auto", and the unit after the value.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

export const FEATURE_TITLES = ["Outer wall", "Inner wall", "Skin", "Sparse infill",
  "Ironing", "Skirt or brim", "Support", "Support interface",
  "Slope smoothing", "Slope ironing", "Bridge",
  "Seams", "Travel moves", "Retractions"];

// The feature and mark colors (feature_rgb in src/render/view.zig).
export const FEATURE_COLORS = ["#d9480f", "#f59f00", "#1c7ed6", "#2b8a3e", "#ae3ec9", "#8d6e63",
  "#adb5bd", "#495057", "#0ca6ae", "#82c91e", "#66ccf2", "#e01a26", "#3373f2", "#f240bf"];

export const FEATURE_COUNT = 11;
export const ALL_FEATURES = (1 << FEATURE_COUNT) - 1;

// The groups of the settings browser, in order, with their titles.
export const GROUP_TITLES = { project: "Part", filament: "Filament", machine: "Printer", engine: "Engine" };

export function parsesAsNumber(text) {
  return text.trim() !== "" && Number.isFinite(Number(text));
}

// A number with no more digits than it needs (%.6g).
export function formatNumber(v) {
  return String(Number(v.toPrecision(6)));
}

// The text of a setting value comes from the core (zs_setting_display,
// zs_setting_parse, zs_setting_source_text: src/app/setting_text.zig), so
// all apps show the same text. app.js gives the wasm instance of the page;
// until then, the rules below give the same text.
let core = null;
export function useCore(wasm) {
  core = wasm;
}

function coreText(fn) {
  try {
    return core.readText(fn);
  } catch {
    return null;
  }
}

// A change line of a history step that can be undone alone
// (zs_history_revertible): not the quality, and not a move, turn,
// orientation, or scale of a part.
export function revertible(line) {
  if (core) {
    try {
      return core.withString(line, (p, n) => core.x.zs_history_revertible(p, n)) === 1;
    } catch {
      // The rule below.
    }
  }
  if (line.includes("\tquality\t")) return false;
  if (!line.startsWith("part:")) return true;
  const key = line.split("\t")[1] ?? "";
  return !/^(\(part\)|position|rotation|orientation|scale)/.test(key);
}

// The settings that match a search query, best first (zs_setting_search):
// [{ index, score }], or null with no core (the caller ranks then).
export function searchSettings(query, partOnly, max) {
  if (!core) return null;
  try {
    const p = core.alloc(12 * max);
    try {
      // The scores first: f64 needs 8-byte alignment.
      const n = core.withString(query, (q) => core.x.zs_setting_search(q, partOnly ? 1 : 0, p + 8 * max, p, max));
      const out = [];
      for (let i = 0; i < n; i++) out.push({ index: core.u32(p + 8 * max + 4 * i), score: core.f64(p + 8 * i) });
      return out;
    } finally {
      core.free(p, 12 * max);
    }
  } catch {
    return null;
  }
}

// The kinds of zs_printer_status: 1 OctoPrint, 2 printdeck, 3 Moonraker.
const STATUS_KIND = { octoprint: 1, printdeck: 2, moonraker: 3 };

// The paths of the status of a printer kind (zs_printer_status_paths), or
// [] with no core.
export function printerStatusPaths(kind) {
  const k = STATUS_KIND[kind];
  if (!core || !k) return [];
  return core.cstr(core.x.zs_printer_status_paths(k)).split("\n").filter(Boolean);
}

// The paths of the camera of a printer kind (zs_printer_camera_paths).
export function printerCameraPaths(kind) {
  const k = STATUS_KIND[kind];
  if (!core || !k) return [];
  return core.cstr(core.x.zs_printer_camera_paths(k)).split("\n").filter(Boolean);
}

// The temperatures (zs_printer_heat, 5 doubles): null for not known.
function readHeat(x, st) {
  const p = core.alloc(40);
  try {
    if (x.zs_printer_status_heat(st, p) !== 0) return {};
    const f = (o) => {
      const v = core.f64(p + o);
      return Number.isNaN(v) ? null : v;
    };
    return { nozzle: f(0), nozzleTarget: f(8), bed: f(16), bedTarget: f(24), chamber: f(32) };
  } finally {
    core.free(p, 40);
  }
}

// The camera (zs_printer_camera on wasm32: two pointers, three ints).
function readCamera(x, st) {
  const p = core.alloc(20);
  try {
    if (x.zs_printer_status_camera(st, p) !== 0) return null;
    return {
      stream: core.cstr(core.u32(p)), snapshot: core.cstr(core.u32(p + 4)),
      flipH: core.i32(p + 8) !== 0, flipV: core.i32(p + 12) !== 0, rotation: core.i32(p + 16),
    };
  } finally {
    core.free(p, 20);
  }
}

// The status of a printer from the replies of its API ([[path, text]]),
// read by the core (zs_printer_status): { state, bedX, bedY, height,
// nozzle, material, diameter, spool, rolls, job, progress, timeLeft,
// layer, layers, limits, heat, camera }, or null with no core. heat:
// { nozzle, nozzleTarget, bed, bedTarget, chamber } in °C, null when not
// known. camera: { stream, snapshot, flipH, flipV, rotation } from the
// camera paths, when the replies have them.
export function readPrinterStatus(kind, replies) {
  const k = STATUS_KIND[kind];
  if (!core || !k) return null;
  const x = core.x;
  const st = x.zs_printer_status_new();
  if (!st) return null;
  try {
    for (const [path, text] of replies) {
      const bytes = new TextEncoder().encode(text);
      core.withString(path, (pp) => core.withBytes(bytes, (b, n) => x.zs_printer_status_feed(st, k, pp, b, n)));
    }
    // zs_printer_info on wasm32 (pointers 4 bytes, doubles 8-aligned).
    const size = 176;
    const p = core.alloc(size + 24);
    try {
      if (x.zs_printer_status_get(st, p) !== 0) return null;
      const s = (o) => core.cstr(core.u32(p + o));
      const f = (o) => core.f64(p + o);
      const roll = (o) => ({ id: s(o), name: s(o + 4), material: s(o + 8), color: s(o + 12), left: f(o + 16) });
      const n = core.u32(p + 96);
      const rolls = [];
      for (let i = 0; i < n; i++) {
        if (x.zs_printer_status_roll(st, i, p + size) === 0) rolls.push(roll(size));
      }
      return {
        state: s(0), bedX: f(8), bedY: f(16), height: f(24), nozzle: f(32),
        material: s(40), diameter: f(48), spool: roll(56), spoolPrice: f(80), spoolFull: f(88), rolls,
        limits: { velocity: f(104), accel: f(112), corner: f(120), zVelocity: f(128), zAccel: f(136) },
        job: s(144), progress: f(152), timeLeft: f(160), layer: core.i32(p + 168), layers: core.i32(p + 172),
        heat: readHeat(x, st), camera: readCamera(x, st),
        // 0 offline, 1 idle, 2 printing, 3 paused, 4 finished, 5 failed.
        farm: x.zs_printer_status_farm_state(st), message: core.cstr(x.zs_printer_status_message(st)),
      };
    } finally {
      core.free(p, size + 24);
    }
  } catch {
    return null;
  } finally {
    x.zs_printer_status_free(st);
  }
}

function isAuto(info) { return info.name.endsWith("line_width"); }
export function isRatio(info) { return (info.kind === "number" || info.kind === "integer") && info.unit === "%"; }
export function isNumber(info) { return info.kind === "number" || info.kind === "integer"; }

// The value as an editor shows it.
export function displayValue(info, value) {
  if (core) {
    const t = coreText((b, c, l) => core.withStrings([info.name, String(value)], (n, v) => core.x.zs_setting_display(n, v, 0, b, c, l)));
    if (t !== null) return t;
  }
  if (isAuto(info) && parsesAsNumber(value) && Number(value) === 0) return "auto";
  if (isRatio(info) && parsesAsNumber(value)) return formatNumber(Number(value) * 100);
  if (info.kind === "text" && info.multiline) {
    const nl = value.indexOf("\n");
    return nl >= 0 ? `${value.slice(0, nl)} …` : value;
  }
  return value;
}

// The value with its unit: "0.8 mm", "1 layer", "auto".
export function valueWithUnit(info, value) {
  if (core) {
    const t = coreText((b, c, l) => core.withStrings([info.name, String(value)], (n, v) => core.x.zs_setting_display(n, v, 1, b, c, l)));
    if (t !== null) return t;
  }
  const shown = displayValue(info, value);
  const n = info.unit.length;
  const one = shown === "1" && n > 1 && info.unit.endsWith("s") && info.kind === "integer";
  if (!info.unit || shown === "auto") return shown;
  return `${shown} ${one ? info.unit.slice(0, n - 1) : info.unit}`;
}

// The core value of the text of an editor.
export function toCore(info, text) {
  if (core) {
    // A text that is not a number goes to the core as it is: the core
    // refuses it with its own message.
    const t = coreText((b, c, l) => core.withStrings([info.name, String(text)], (n, v) => core.x.zs_setting_parse(n, v, b, c, l)));
    if (t !== null) return t;
    return text.trim();
  }
  const t = text.trim();
  if (isAuto(info) && t.toLowerCase() === "auto") return "0";
  if (!isRatio(info) || !parsesAsNumber(t)) return t;
  return String(Number((Number(t) / 100).toPrecision(10)));
}

// The level of a value (enum zs_level) as a source tag, or "".
export function sourceText(entry) {
  if (!entry) return "";
  if (entry.formula !== null && entry.formula !== undefined) return `= ${entry.formula}`;
  switch (entry.level) {
    case 1: return "Global";
    case 2: return entry.profile || "Printer";
    case 3: return entry.profile || "Filament";
    case 4: return entry.profile || "Quality";
    case 5: return "This print";
    case 6: return "This part";
    default: return "";
  }
}

// "50 min", "1 h 5 min".
export function formatTime(seconds) {
  const minutes = Math.round(seconds / 60);
  return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

// "0:06", "1:02:03".
export function formatClock(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const pad = (n) => String(n).padStart(2, "0");
  if (s >= 3600) return `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  return `${Math.floor(s / 60)}:${pad(s % 60)}`;
}
