// Test of the wasm module with Node.js.
// Run: zig build wasm && node web/test.mjs zig-out/web/zslice.wasm part.stl
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { readFile } from "node:fs/promises";
import { load } from "./zslice.mjs";

const [wasmPath, stlPath] = process.argv.slice(2);
if (!wasmPath || !stlPath) {
  console.error("usage: node web/test.mjs <zslice.wasm> <part.stl>");
  process.exit(2);
}

const zslice = await load(await readFile(wasmPath));
console.log(`zslice ${zslice.version}, ${zslice.settingNames.length} settings`);

const t0 = performance.now();
const { gcode, stats } = zslice.sliceStl(await readFile(stlPath), {
  "project.wall_count": 3,
  "filament.nozzle_temp": 220,
});
const ms = performance.now() - t0;

if (!gcode.includes(";LAYER:0\n")) throw new Error("no layer 0");
if (!gcode.includes("M104 S220")) throw new Error("nozzle_temp not set");

let threw = false;
try {
  zslice.sliceStl(await readFile(stlPath), { "project.no_such_setting": 1 });
} catch (e) {
  threw = e.status === 5;
}
if (!threw) throw new Error("an unknown setting did not throw");

console.log(`${stats.layerCount} layers, ${(stats.filamentMm / 1000).toFixed(2)} m, ${gcode.length} bytes of G-code, ${ms.toFixed(0)} ms`);
console.log("ok");
