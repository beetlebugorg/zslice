// zslice for JavaScript: a small wrapper around zslice.wasm.
//
// Use:
//   import { load } from "./zslice.mjs";
//   const zslice = await load(wasmBytes);   // an ArrayBuffer or Uint8Array
//   const { gcode, stats } = zslice.sliceStl(stlBytes, {
//     "project.wall_count": 3,
//     "filament.nozzle_temp": 220,
//   });
//
// The wasm module has no threads, so a slice blocks its thread. In a browser,
// run it in a Web Worker.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const statusNames = [
  "ok", "out_of_memory", "invalid_argument", "invalid_mesh", "empty_mesh",
  "unknown_setting", "invalid_value", "invalid_settings", "part_too_large",
  "write_failed",
];

export class ZsliceError extends Error {
  constructor(status, detail) {
    super(`zslice: ${statusNames[status] ?? status}${detail ? ` (${detail})` : ""}`);
    this.status = status;
  }
}

export async function load(wasmBytes) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  const x = instance.exports;
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  const u8 = () => new Uint8Array(x.memory.buffer);
  const view = () => new DataView(x.memory.buffer);
  const check = (status, detail) => {
    if (status !== 0) throw new ZsliceError(status, detail);
  };

  // Copies bytes into wasm memory. Returns [ptr, len].
  function put(bytes) {
    const ptr = x.zs_alloc(bytes.length);
    if (ptr === 0 && bytes.length > 0) throw new ZsliceError(1);
    u8().set(bytes, ptr);
    return [ptr, bytes.length];
  }

  function putString(s) {
    return put(enc.encode(s + "\0"));
  }

  function cString(ptr) {
    const mem = u8();
    let end = ptr;
    while (mem[end] !== 0) end++;
    return dec.decode(mem.subarray(ptr, end));
  }

  return {
    version: cString(x.zs_version()),
    settingNames: cString(x.zs_setting_names()).trim().split("\n"),

    // Slices an STL file (binary or ASCII). settings is an object of
    // "group.name": value. Returns { gcode, stats }.
    sliceStl(stlBytes, settings = {}) {
      const bytes = stlBytes instanceof Uint8Array ? stlBytes : new Uint8Array(stlBytes);
      // One 4-byte cell for each out pointer, and 40 bytes for the stats.
      const scratch = x.zs_alloc(8 + 8 + 40);
      const meshOut = scratch;
      const settingsOut = scratch + 4;
      const bufOut = scratch + 8;
      const lenOut = scratch + 12;
      const statsOut = scratch + 16;
      let mesh = 0;
      let st = 0;
      let buf = 0;
      let len = 0;
      try {
        const [sp, sl] = put(bytes);
        try {
          check(x.zs_mesh_load_stl(sp, sl, meshOut));
        } finally {
          x.zs_free(sp, sl);
        }
        mesh = view().getUint32(meshOut, true);

        check(x.zs_settings_new(settingsOut));
        st = view().getUint32(settingsOut, true);
        for (const [key, value] of Object.entries(settings)) {
          const [kp, kl] = putString(key);
          const [vp, vl] = putString(String(value));
          try {
            check(x.zs_settings_set(st, kp, vp), `${key}=${value}`);
          } finally {
            x.zs_free(kp, kl);
            x.zs_free(vp, vl);
          }
        }

        check(x.zs_slice_to_buffer(mesh, st, bufOut, lenOut, statsOut));
        buf = view().getUint32(bufOut, true);
        len = view().getUint32(lenOut, true);
        const gcode = dec.decode(u8().subarray(buf, buf + len));
        const v = view();
        const stats = {
          layerCount: v.getUint32(statsOut, true),
          retractions: v.getUint32(statsOut + 4, true),
          filamentMm: v.getFloat64(statsOut + 8, true),
          filamentG: v.getFloat64(statsOut + 16, true),
          printTimeS: v.getFloat64(statsOut + 24, true),
          travelMm: v.getFloat64(statsOut + 32, true),
        };
        return { gcode, stats };
      } finally {
        if (buf) x.zs_buffer_free(buf, len);
        if (st) x.zs_settings_free(st);
        if (mesh) x.zs_mesh_free(mesh);
        x.zs_free(scratch, 8 + 8 + 40);
      }
    },
  };
}
