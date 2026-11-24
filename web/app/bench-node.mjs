// The time of each kind of edit in zslice.wasm (one thread), in Node.js.
// It uses the calls of core.js, as the web app does.
//
// Run: node web/app/bench-node.mjs <zslice.wasm> <part.stl> [slice_form]
//
// With "slice_form" as the third argument, the core keeps its work for
// each level (engine.slice_form=true). The script prints the first slice,
// the median and the least time of five slices of each kind, and the size
// of the wasm memory at the end.
//
// SPDX-License-Identifier: AGPL-3.0-or-later
import { readFile } from "node:fs/promises";
import { Wasm } from "./wasm.js";
import { Core, STATE } from "./core.js";

const [wasmPath, stlPath, mode] = process.argv.slice(2);
if (!wasmPath || !stlPath) {
  console.error("usage: node web/app/bench-node.mjs <zslice.wasm> <part.stl> [slice_form]");
  process.exit(2);
}
const module = await WebAssembly.compile(await readFile(wasmPath));
const wasm = await Wasm.create(module, () => {});
const core = new Core(wasm);
if (mode === "slice_form") {
  const e = core.set("engine.slice_form", "true");
  if (e !== "") throw new Error(e);
}
core.loadStl("part.stl", await readFile(stlPath));

function slice() {
  const t0 = performance.now();
  const r = core.slice();
  if (r.state !== STATE.done) throw new Error("slice failed: " + r.error);
  return performance.now() - t0;
}
function show(kind, a) {
  const s = [...a].sort((x, y) => x - y);
  console.log(`${kind.padEnd(16)} median ${s[s.length >> 1].toFixed(1)} ms  min ${s[0].toFixed(1)} ms`);
}

console.log(`first slice      ${slice().toFixed(1)} ms`);
const kinds = [
  ["noop", null, []],
  ["nozzle temp", "filament.nozzle_temp", ["211", "212", "213", "214", "215"]],
  ["wall speed", "project.outer_wall_speed", ["0.41", "0.42", "0.43", "0.44", "0.45"]],
  ["late (infill)", "project.infill_density", ["0.21", "0.22", "0.23", "0.24", "0.25"]],
  ["wall count", "project.wall_count", ["3", "4", "5", "6", "7"]],
  ["layer height", "project.layer_height", ["0.21", "0.22", "0.23", "0.24", "0.25"]],
];
for (const [kind, name, values] of kinds) {
  const times = [];
  for (let k = 0; k < 5; k++) {
    if (name) {
      const e = core.set(name, values[k]);
      if (e !== "") throw new Error(e);
    }
    times.push(slice());
  }
  show(kind, times);
}
// A z range: the infill of z 5 to 10 mm.
{
  const times = [];
  for (let k = 0; k < 5; k++) {
    core.setScoped("project.infill_density", (0.3 + 0.01 * k).toFixed(2), 5, 10, true);
    times.push(slice());
  }
  show("z range infill", times);
}
// A drag with drafts: three draft slices of the infill, then the exact
// slice. Only the exact slice is timed. With slice_form, the drafts use
// their own lane, and the exact slice keeps the work of the exact lane.
{
  const times = [];
  for (let k = 0; k < 5; k++) {
    wasm.x.zs_app_set_draft(core.app, 1);
    for (let d = 0; d < 3; d++) {
      const e = core.set("project.infill_density", (0.2 + 0.01 * k + 0.001 * d).toFixed(3));
      if (e !== "") throw new Error(e);
      slice();
    }
    wasm.x.zs_app_set_draft(core.app, 0);
    times.push(slice());
  }
  show("draft, exact", times);
}
const mem = wasm.x && wasm.x.memory ? wasm.x.memory.buffer.byteLength : 0;
console.log(`wasm memory ${(mem / 1048576).toFixed(0)} MB`);
