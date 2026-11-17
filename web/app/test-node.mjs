// A test of the web app core in Node.js: the same code as the worker
// (core.js) and the view of the main thread (view.js), with no browser.
//
// Run: zig build web && node web/app/test-node.mjs zig-out/web/zslice.wasm part.stl
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { readFile } from "node:fs/promises";
import { Wasm } from "./wasm.js";
import { Core, STATE } from "./core.js";
import { View3D } from "./view.js";

const [wasmPath, stlPath] = process.argv.slice(2);
if (!wasmPath || !stlPath) {
  console.error("usage: node web/app/test-node.mjs <zslice.wasm> <part.stl>");
  process.exit(2);
}

function check(ok, what) {
  if (!ok) throw new Error(`failed: ${what}`);
}

const bytes = await readFile(wasmPath);
const module = await WebAssembly.compile(bytes);
console.log(`zslice.wasm: ${(bytes.length / 1e6).toFixed(2)} MB`);

// The worker side.
let progressEvents = 0;
let core = null;
const wasm = await Wasm.create(module, (event) => {
  if (event === 1) progressEvents++;
});
core = new Core(wasm);
check(core.infos.length > 100, "the setting infos");
check(core.state() === STATE.empty, "the empty state");

// A setting, its source, and the saved state.
check(core.set("project.wall_count", "5") === "", "set wall_count");
check(core.get("project.wall_count") === "5", "get wall_count");
check(core.source("project.wall_count").level === 5, "the source of a change is this print");
check(core.set("project.wall_count", "nope") !== "", "a bad value fails");
check(core.setQuality("fine", true) === "", "the quality profile");
check(core.qualityName() === "fine", "the quality name");
const saved = core.savedState();
check(saved.project.includes("wall_count = 5"), "the saved state has the change");

// A second core restores the state.
const wasm2 = await Wasm.create(module);
const core2 = new Core(wasm2);
check(core2.restore(saved).length === 0, "restore");
check(core2.get("project.wall_count") === "5" && core2.qualityName() === "fine", "the restored state");

core.loadStl("part.stl", await readFile(stlPath));
check(core.state() === STATE.ready, "the ready state");

let t0 = performance.now();
const r = core.slice();
const sliceMs = performance.now() - t0;
check(r.state === STATE.done, `the slice is done (${r.error})`);
check(progressEvents > 0, "progress events");
const st = core.stats();
console.log(`slice: ${sliceMs.toFixed(0)} ms, ${st.layerCount} layers, ${(st.filamentMm / 1000).toFixed(2)} m, ${st.filamentG.toFixed(1)} g, ${(st.printTimeS / 60).toFixed(0)} min`);

// A second slice after a change reuses the outlines of the first.
core.set("project.infill_density", "0.3");
t0 = performance.now();
core.slice();
console.log(`second slice (infill density): ${(performance.now() - t0).toFixed(0)} ms`);

const layers = core.layers();
check(layers.z.length === st.layerCount, "the layer list");
const fs = core.featureStats();
check(fs[0].paths > 0, "the feature stats");

t0 = performance.now();
const scene = core.scene(1);
console.log(`scene: ${(scene.byteLength / 1e6).toFixed(1)} MB in ${(performance.now() - t0).toFixed(0)} ms`);

const gcode = new TextDecoder().decode(core.gcode());
check(gcode.includes(";LAYER:0\n"), "the G-code has layer 0");

// The main thread side: a second instance reads the scene and draws.
const view = new View3D(wasm2, 800, 600);
t0 = performance.now();
view.readScene(scene);
console.log(`scene read: ${(performance.now() - t0).toFixed(0)} ms`);
let f = view.frame();
check(f.instanceCount > 1000, "the instances");
check(f.meshIndex.length > 0 && f.gridVertices > 0, "the mesh and the grid");
check(f.boxCount > 0 && f.boxCount <= f.instanceCount, "the beads of all layers show");
const all = f.boxCount;
view.setLayerRange(0, 10);
f = view.frame();
check(f.boxCount < all, "the layer range");
view.orbit(30, 10);
view.zoomAt(0.8, 400, 300);
while (view.animate(1 / 60));
f = view.frame();
check(Number.isFinite(f.box[0]), "the camera matrix");
view.setTime(view.duration() / 2);
f = view.frame();
check(f.headCount > 0, "the toolhead of a replay");
console.log(`frame: ${f.boxCount} beads, ${f.markCount} marks, ${f.headCount} toolhead beads`);
console.log("ok");
