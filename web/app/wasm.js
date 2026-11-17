// wasm.js: the wasm instance of zslice, and the helpers to call its C API
// (include/zslice.h and include/zslice-app.h) from JavaScript.
//
// The page makes two instances of the same module: one in the worker
// (worker.js) for the app core and the slice, and one on the main thread
// for the 3D view (view.js). Both use this file. It needs no DOM, so the
// Node test (test-node.mjs) uses it too.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const statusNames = [
  "ok", "out of memory", "invalid argument", "invalid mesh", "empty mesh",
  "unknown setting", "invalid value", "invalid settings", "part too large",
  "write failed", "canceled", "busy", "no model", "no result", "out of range",
  "not supported", "GPU failed", "part too thin",
];

export function statusText(code) {
  return statusNames[code] ?? `status ${code}`;
}

const enc = new TextEncoder();
const dec = new TextDecoder();

export class Wasm {
  // module: a WebAssembly.Module. onEvent(event, progress, status): the
  // events of the app core (env.zs_web_event).
  static async create(module, onEvent = () => {}) {
    const instance = await WebAssembly.instantiate(module, {
      env: { zs_web_event: (e, p, s) => onEvent(e, p, s) },
    });
    return new Wasm(instance);
  }

  constructor(instance) {
    this.x = instance.exports;
    // A small scratch area for out parameters.
    this.cell = this.x.zs_alloc(256);
  }

  get u8() { return new Uint8Array(this.x.memory.buffer); }
  get dv() { return new DataView(this.x.memory.buffer); }

  alloc(n) {
    const p = this.x.zs_alloc(Math.max(n, 1));
    if (p === 0) throw new Error("zslice: out of memory");
    return p;
  }

  free(p, n) { this.x.zs_free(p, Math.max(n, 1)); }

  // Copies bytes into wasm memory, and calls fn(ptr, len). Frees them after.
  withBytes(bytes, fn) {
    const p = this.alloc(bytes.length);
    this.u8.set(bytes, p);
    try { return fn(p, bytes.length); } finally { this.free(p, bytes.length); }
  }

  // The same with a string and a NUL at the end. A null string is ptr 0.
  withString(s, fn) {
    if (s === null || s === undefined) return fn(0, 0);
    return this.withBytes(enc.encode(s + "\0"), (p, n) => fn(p, n - 1));
  }

  // Calls fn(ptr0, ptr1, ...) with each string in wasm memory.
  withStrings(list, fn) {
    const go = (i, ptrs) => i === list.length ? fn(...ptrs) : this.withString(list[i], (p) => go(i + 1, [...ptrs, p]));
    return go(0, []);
  }

  cstr(ptr) {
    if (!ptr) return "";
    const mem = this.u8;
    let end = ptr;
    while (mem[end] !== 0) end++;
    return dec.decode(mem.subarray(ptr, end));
  }

  text(ptr, len) {
    return ptr ? dec.decode(this.u8.subarray(ptr, ptr + len)) : "";
  }

  u32(p) { return this.dv.getUint32(p, true); }
  i32(p) { return this.dv.getInt32(p, true); }
  f64(p) { return this.dv.getFloat64(p, true); }

  // A call with the buffer convention of the C API (a text, its length):
  // fn(buf, cap, out_len) is called once for the length, then again with
  // a buffer. Returns the text, or null if the call fails.
  readText(fn) {
    const lenCell = this.cell;
    if (fn(0, 0, lenCell) !== 0) return null;
    const n = this.u32(lenCell);
    const buf = this.alloc(n + 1);
    try {
      if (fn(buf, n + 1, 0) !== 0) return null;
      return this.text(buf, n);
    } finally {
      this.free(buf, n + 1);
    }
  }

  // ---- static data of the core (no app needed) ----

  // The settings, in the order to show them (zs_setting_get_info).
  settingInfos() {
    const x = this.x;
    const n = x.zs_setting_count();
    // zs_setting_info on wasm32: 10 pointers and ints, then 5 doubles,
    // then 2 ints (see include/zslice-app.h).
    const size = 112;
    const p = this.alloc(size);
    const kinds = ["number", "integer", "boolean", "choice", "text"];
    const out = [];
    try {
      for (let i = 0; i < n; i++) {
        if (x.zs_setting_get_info(i, p) !== 0) continue;
        const s = (k) => this.cstr(this.u32(p + 4 * k));
        out.push({
          index: i,
          name: s(0),
          group: s(1),
          section: s(2),
          label: s(3),
          doc: s(4),
          kind: kinds[this.i32(p + 20)] ?? "text",
          multiline: this.i32(p + 24) !== 0,
          choices: s(7).split("\n").filter((c) => c !== ""),
          unit: s(8),
          defaultValue: s(9),
          sliderMin: this.f64(p + 40),
          sliderMax: this.f64(p + 48),
          limitMin: this.f64(p + 56),
          limitMax: this.f64(p + 64),
          sliderStep: this.f64(p + 72),
          perLayer: this.i32(p + 80) !== 0,
          perPart: this.i32(p + 84) !== 0,
        });
      }
    } finally {
      this.free(p, size);
    }
    return out;
  }

  // What a setting changes (zs_setting_get_effect): a bit for each
  // feature, the first layer only, and a note.
  settingEffect(name) {
    const p = this.cell;
    const rc = this.withString(name, (s) => this.x.zs_setting_get_effect(s, p));
    if (rc !== 0) return { features: 0, firstLayerOnly: false, note: "" };
    return { features: this.u32(p), firstLayerOnly: this.i32(p + 4) !== 0, note: this.cstr(this.u32(p + 8)) };
  }

  // The built-in profiles of a group (0 printer, 1 filament, 2 quality).
  builtinProfiles(group) {
    const n = this.x.zs_builtin_profile_count(group);
    const out = [];
    for (let i = 0; i < n; i++) out.push(this.cstr(this.x.zs_builtin_profile_name(group, i)));
    return out;
  }

  licenses() {
    const n = this.x.zs_license_count();
    const out = [];
    for (let i = 0; i < n; i++) {
      if (this.x.zs_license_get(i, this.cell) !== 0) continue;
      out.push({ name: this.cstr(this.u32(this.cell)), license: this.cstr(this.u32(this.cell + 4)), text: this.cstr(this.u32(this.cell + 8)) });
    }
    return out;
  }

  // A new 3D view in web mode (ZS_SURFACE_WEB): no GPU in the core.
  newView(width, height) {
    const surface = this.alloc(24);
    this.u8.fill(0, surface, surface + 24);
    this.dv.setInt32(surface, 3, true);
    try {
      const rc = this.x.zs_view_new(surface, width, height, this.cell);
      if (rc !== 0) throw new Error(`zslice: no view (${statusText(rc)})`);
      return this.u32(this.cell);
    } finally {
      this.free(surface, 24);
    }
  }
}
