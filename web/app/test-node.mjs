// A test of the web app core in Node.js: the same code as the worker
// (core.js) and the view of the main thread (view.js), with no browser.
//
// Run: zig build web && node web/app/test-node.mjs zig-out/web/app/zslice.wasm part.stl
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

// The 2D view and the selection: the beads of a layer, a pick in mm, the
// outlines, and the steps along the print, from the view alone.
view.setLayerRange(0, layers.z.length - 1);
const mid = Math.floor(layers.z.length / 2);
const range = new Uint32Array(2);
view.layerBeads(mid, range);
check(range[1] > range[0], "the beads of a layer");
const o = view.outlines();
check(o.layerEnds.length === layers.z.length && o.points.length > 0, "the outlines of the layers");
const b = view.bounds();
check(b && b[2] > b[0] && b[3] > b[1], "the box of the beads");
const p0 = view.beadPoint(range[0]);
t0 = performance.now();
check(view.pickLayer(mid, p0.x, p0.y), "a pick in mm on a layer");
const pickMs = performance.now() - t0;
const path = view.hit[0];
check(view.pathLayer(path) === mid, "the layer of the picked path");
check(view.step(path, 0, 1, false) && view.hit[0] >= path, "a step along the print");
check(view.nearestOnLayer(path, mid + 1) >= 0, "the nearest path on the layer above");
const info = core.inspect(path, 0);
check(info && info.layer === mid && info.title.length > 0 && Object.keys(info.values).length > 0, "the Selected page of the path");
check((core.lineReport(path) ?? "").includes("## The line"), "the report of Copy for AI");
// A 3D pick in the middle of the view.
t0 = performance.now();
const hit3d = view.pickSegment(400, 300);
console.log(`2D pick: ${pickMs.toFixed(2)} ms; 3D pick: ${(performance.now() - t0).toFixed(2)} ms (${hit3d ? "a hit" : "no hit"}); ${info.title}, layer ${info.layer + 1}`);
// The printer library (printers.txt, next to the wasm file): the layout
// of zs_printer_model on wasm32, a search, and the profile of a model.
const { loadLibrary, model, search, brands, profileText } = await import("./printers.js");
loadLibrary(wasm2, await readFile(wasmPath.replace(/[^/]*$/, "printers.txt")));
const found = search(wasm2, "lulzbot taz 6", -1);
check(found.total > 0, "a search of the printer library");
const taz = model(wasm2, found.idx[0]);
check(taz.brand === "LulzBot" && taz.title === "LulzBot Taz 6" && taz.bedX === 280 && taz.filament === 2.85 && taz.nozzle === 0.5, `the model of the search (${taz.brand} ${taz.name})`);
check(brands(wasm2).length > 100, "the brands of the library");
check((profileText(wasm2, taz.index, 0.5) ?? "").includes("bed_size_x = 280"), "the machine profile of the model");
console.log(`printers: ${found.total} for "lulzbot taz 6"; first: ${taz.brand} ${taz.name}, ${taz.bedX} x ${taz.bedY} x ${taz.height} mm, ${taz.firmware}`);
console.log("ok");
