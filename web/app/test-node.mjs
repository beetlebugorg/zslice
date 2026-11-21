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
import { clipText, parseClipText } from "./clipboard.js";
import { outlineOf, placeAt, newItem, scaleLabel, withAngle, angleOf, turned, nextFilament, changeShape, labelName } from "./label.js";

const [wasmPath, stlPath] = process.argv.slice(2);
if (!wasmPath || !stlPath) {
  console.error("usage: node web/app/test-node.mjs <zslice.wasm> <part.stl>");
  process.exit(2);
}

// The box of the model on the bed: x0, y0, x1, y1 (mm).
function view0Bounds(c) {
  const info = c.modelInfo();
  const s = info ? info.size : [20, 20, 20];
  return [100 - s[0] / 2, 100 - s[1] / 2, 100 + s[0] / 2, 100 + s[1] / 2];
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

// A second filament for some layers: a filament change, and the grams of
// each filament.
{
  check(core.filaments().length === 1, "one filament at first");
  const i = core.filamentAdd();
  check(i === 1, "a second filament");
  check(core.filamentSet(1, "filament.color", "#ff0000") === "", "the color of the second filament");
  check(core.filaments()[1].color === "#ff0000", "the color reads back");
  check(core.setScoped("project.filament", "2", 2, 4, true) === "", "the filament of some layers");
  check(core.slice().state === STATE.done, "the slice with two filaments");
  const fs = core.filamentStats();
  check(fs && fs.changes === 2 && fs.grams[0] > 0 && fs.grams[1] > 0, `the filament stats (${JSON.stringify(fs)})`);
  console.log(`two filaments: ${fs.changes} changes, ${fs.grams[0].toFixed(1)} g and ${fs.grams[1].toFixed(1)} g`);
  core.resetScoped("project.filament", 2, 4, 3);
  // Paint: the triangles over z 40 (the chimney) with filament 2.
  const m = core.partMesh(0);
  check(m && m.faces.length > 0, "the mesh of the part");
  let text = "";
  for (let t = 0; t < m.faces.length / 3; t++) {
    let top = true;
    for (let k = 0; k < 3; k++) if (m.verts[3 * m.faces[3 * t + k] + 2] < 40) top = false;
    if (top) text += `${t} 8\n`;
  }
  check(core.setPartPaint(0, text), "set the paint");
  check(core.partPaint(0).length === text.length, "the paint reads back");
  t0 = performance.now();
  check(core.slice().state === STATE.done, "the slice of a painted part");
  const ps = core.filamentStats();
  check(ps.grams[1] > 0, `the painted filament prints (${JSON.stringify(ps)})`);
  console.log(`paint: ${(performance.now() - t0).toFixed(0)} ms, ${ps.grams[1].toFixed(2)} g of filament 2, ${ps.changes} changes`);
  check(core.setPartPaint(0, ""), "clear the paint");
  check(core.filamentRemove(1), "remove the second filament");
  check(core.filaments().length === 1, "one filament again");
  core.slice();
}

// A label (label.js, labelcard.js): the JSON of the card, the pick on the
// mesh, the outline, the facts, a slice in two filaments, and the removal.
{
  check(nextFilament(1, 1) === 1 && nextFilament(1, 3) === 2 && nextFilament(3, 3) === 1 && nextFilament(2, 2) === 1, "the filament of a new label");
  check(core.filamentAdd() === 1, "a second filament for the label");
  const m = core.partMesh(0);
  let x0 = Infinity, x1 = -Infinity, y0 = Infinity;
  for (let i = 0; i < m.verts.length; i += 3) {
    x0 = Math.min(x0, m.verts[i]);
    x1 = Math.max(x1, m.verts[i]);
    y0 = Math.min(y0, m.verts[i + 1]);
  }
  const vp = wasm.alloc(m.verts.byteLength);
  const fp = wasm.alloc(m.faces.byteLength);
  new Float32Array(wasm.x.memory.buffer, vp, m.verts.length).set(m.verts);
  new Uint32Array(wasm.x.memory.buffer, fp, m.faces.length).set(m.faces);
  check(wasm.x.zs_paint_new(vp, m.verts.length / 3, fp, m.faces.length / 3, wasm.cell) === 0, "a paint session for the pick");
  wasm.free(vp, m.verts.byteLength);
  wasm.free(fp, m.faces.byteLength);
  const s = wasm.u32(wasm.cell);
  // A ray at the side of the hull, along +y.
  const at = placeAt(wasm, s, [(x0 + x1) / 2, y0 - 50, 8, 0, 1, 0]);
  wasm.x.zs_paint_free(s);
  check(at && at.normal[1] < -0.5, `the pick of the hull (${JSON.stringify(at)})`);
  let label = { origin: at.origin, normal: at.normal, right: at.right, filament: 2, depth: 0, items: [newItem("text")] };
  check(Math.abs(angleOf(label)) < 1, `a new label is level (${angleOf(label)})`);
  label = withAngle(label, 30);
  check(Math.abs(angleOf(label) - 30) < 1e-6 && Math.abs(angleOf(turned(label, -30))) < 1e-6, "the turn of a label");
  const o = outlineOf(wasm, label);
  check(o && o.ends.length >= 5 && Math.abs(o.box[3] - o.box[1] - 5) < 0.3, `the outline of LABEL (${o && o.box})`);
  const big = outlineOf(wasm, scaleLabel(label, 2));
  check(Math.abs((big.box[3] - big.box[1]) - 2 * (o.box[3] - o.box[1])) < 0.05, "a scale of the label");
  check(outlineOf(wasm, { items: [{ kind: "bar", width: 4 }] }) === null, "a bad shape has no outline");
  for (const k of ["line", "bar", "ring", "ticks", "polyline"]) check(outlineOf(wasm, { items: [newItem(k)] }), `the outline of a new ${k}`);
  check(changeShape(newItem("text"), "ticks").kind === "ticks", "a change of shape");
  label = withAngle(label, 0);
  const id = core.labelAdd(0, label);
  check(id >= 1, "the core accepts the label");
  const back = core.partLabels(0);
  check(back.length === 1 && back[0].id === id && back[0].items[0].text === "LABEL" && labelName(back[0]) === "“LABEL”", `the label reads back (${JSON.stringify(back)})`);
  const info = core.labelInfo(0, id);
  check(info && info.kind === "side" && info.estimate_changes > 0 && info.clean_size > 3 && typeof info.advice === "string", `the facts of the label (${JSON.stringify(info)})`);
  back[0].items.push({ ...newItem("ticks"), at: [0, -12] });
  check(core.labelUpdate(0, id, back[0]), "an update of the label");
  check(core.partLabels(0)[0].items.length === 2, "the ticks are in the label");
  t0 = performance.now();
  check(core.slice().state === STATE.done, "the slice of a label");
  const ls = core.filamentStats();
  const after = core.labelInfo(0, id);
  check(ls.grams[1] > 0 && after.sliced && after.changes > 0, `the label prints (${JSON.stringify(ls)}, ${JSON.stringify(after)})`);
  console.log(`label: ${(performance.now() - t0).toFixed(0)} ms, ${ls.grams[1].toFixed(2)} g of filament 2, ${after.changes} changes, ${after.minutes.toFixed(0)} min`);
  check(core.labelRemove(0, id) && core.partLabels(0).length === 0, "remove the label");
  check(core.filamentRemove(1), "remove the filament of the label");
  core.slice();
}

// A support area: the core keeps it, gives it back, and slices with it.
{
  const b = view0Bounds(core);
  const pts = [[b[0], b[1], 1], [b[2], b[1], 1], [b[2], b[3], 3], [b[0], b[3], 3]];
  const i = core.supportAreaAdd(1, pts);
  check(i === 0, "a support area");
  const areas = core.supportAreas();
  check(areas.length === 1 && areas[0].kind === 1 && areas[0].zLo === 1 && areas[0].zHi === 3, "the support area comes back");
  check(core.supportAreaSet(0, pts.slice(0, 3)), "the support area moves");
  check(core.supportAreas()[0].pts.length === 3, "the moved area has 3 points");
  check(core.supportAreaAdd(0, pts.slice(0, 2)) === -1, "an area needs 3 points");
  t0 = performance.now();
  check(core.slice().state === STATE.done, "a slice with a support area");
  console.log(`slice with a support area: ${(performance.now() - t0).toFixed(0)} ms`);
  check(core.w.x.zs_app_support_area_remove(core.app, 0) === 0, "the support area goes");
  core.slice();
}

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

// The print as it forms: the simulation of the plastic, in a new scene.
check(!core.showSimulated(true), "no simulation before one runs");
t0 = performance.now();
const sim = core.simulatePrint();
check(sim !== null && sim.masses > 1000 && sim.massG > 0, "the simulated print");
console.log(`simulated print: ${(performance.now() - t0).toFixed(0)} ms, ${sim.masses} masses, ${sim.moved} moved in ${sim.movedPaths} paths, max move ${sim.maxMove.toFixed(2)} mm, ${sim.massG.toFixed(2)} g`);
check(core.scene(1).byteLength > 0, "a scene of the simulated print");
check(core.showSimulated(false), "the slice shows again");

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
// The measurements of the line (zs_app_measure).
if (!info.measure || !(info.measure.path > 0) || !(info.measure.segment > 0)) throw new Error("no measurements: " + JSON.stringify(info.measure));
console.log(`measure: segment ${info.measure.segment.toFixed(2)} mm, path ${info.measure.path.toFixed(2)} mm, shape ${info.measure.shape}`);
check(info && info.layer === mid && info.title.length > 0 && Object.keys(info.values).length > 0, "the Selected page of the path");
check((core.lineReport(path) ?? "").includes("## The line"), "the report of Copy for AI");
// A 3D pick in the middle of the view.
t0 = performance.now();
const hit3d = view.pickSegment(400, 300);
console.log(`2D pick: ${pickMs.toFixed(2)} ms; 3D pick: ${(performance.now() - t0).toFixed(2)} ms (${hit3d ? "a hit" : "no hit"}); ${info.title}, layer ${info.layer + 1}`);
// The printer library (printers.txt, next to the wasm file): the layout
// of zs_printer_model on wasm32, a search, and the profile of a model.
const { loadLibrary, model, search, brands, profileText } = await import("./printers.js");
const lib = loadLibrary(wasm2, await readFile(wasmPath.replace(/[^/]*$/, "printers.txt")));
const found = search(wasm2, "lulzbot taz 6", -1);
check(found.total > 0, "a search of the printer library");
const taz = model(wasm2, found.idx[0]);
check(taz.brand === "LulzBot" && taz.title === "LulzBot Taz 6" && taz.bedX === 280 && taz.filament === 2.85 && taz.nozzle === 0.5, `the model of the search (${taz.brand} ${taz.name})`);
check(brands(wasm2).length > 100, "the brands of the library");
check((profileText(wasm2, taz.index, 0.5) ?? "").includes("bed_size_x = 280"), "the machine profile of the model");
console.log(`printers: ${found.total} for "lulzbot taz 6"; first: ${taz.brand} ${taz.name}, ${taz.bedX} x ${taz.bedY} x ${taz.height} mm, ${taz.firmware}`);
// The bed model of a printer (beds/, next to the wasm file): the model of a
// machine profile, the names of its files, and the bed in a frame.
const mk4 = wasm2.withStrings(["prusa-mk4s", ""], (a, b) => wasm2.x.zs_printers_find_machine(lib, a, b));
check(mk4 >= 0, "the model of a machine profile");
check((profileText(wasm2, mk4, 0) ?? "").includes('model = "prusa-mk4s"'), "the model id in the machine profile");
const bp = wasm2.alloc(12);
check(wasm2.x.zs_printers_bed(lib, mk4, bp) === 0, "the bed of the model");
const bedNames = [wasm2.cstr(wasm2.u32(bp)), wasm2.cstr(wasm2.u32(bp + 4)), wasm2.cstr(wasm2.u32(bp + 8))];
wasm2.free(bp, 12);
const bedDir = wasmPath.replace(/[^/]*$/, "beds/");
const bedRc = view.setBed(lib, mk4, await readFile(bedDir + bedNames[0]), await readFile(bedDir + bedNames[1]));
check(bedRc === 0, `the bed model loads (${bedNames.join(", ")})`);
const bf = view.frame();
check(bf.bedVertices > 0 && bf.bedVertices === bf.bedVertexCount && bf.bedVerts.length === 8 * bf.bedVertexCount, "the bed vertices in the frame");
check(bf.bedTexWidth > 0 && bf.bedTex.length === 4 * bf.bedTexWidth * bf.bedTexHeight, "the bed texture in the frame");
const bedTris = bf.bedVertexCount / 3;
const bedTex = `${bf.bedTexWidth} x ${bf.bedTexHeight}`;
view.clearBed();
check(view.frame().bedVertices === 0, "no bed after zs_view_clear_bed");
console.log(`bed: ${bedNames[0]} and ${bedNames[1]} (${bedNames[2]}): ${bedTris} triangles, texture ${bedTex}`);

// The plate set: three plates in a row, plate 0 active, the scene on
// plates 1 and 2. From far, the plates draw light beads (fewer than the
// full beads of the scene).
view.setTime(-1);
view.setLayerRange(0, 100000);
view.setPlates([[220, 220], [220, 220], [250, 210]], 0);
view.plateScene(1, scene);
view.plateScene(2, scene);
view.plateFlags(2, 1);
view.framePlate(-1);
while (view.animate(1 / 60));
f = view.frame();
check(f.platesCount >= 2, `the other plates in the frame (${f.platesCount})`);
let plateBeads = 0;
for (let i = 0; i < f.plateDrawsCount; i++) plateBeads += f.plateDraws[3 * i + 1];
check(plateBeads > 0 && plateBeads < all, `light beads far from the camera (${plateBeads} of ${all})`);
check(f.plateGridVertices > 0, "the grids of the other plates");
const o2 = view.plateOrigin(2);
check(o2[0] > 440, "plate 2 is right of plate 1");
const q = view.pixelOf(o2[0] + 125, o2[1] + 105, 0);
check(q && view.plateAt(q[0], q[1]) === 2, "a pick of plate 2");
// Plate 2 active: the camera moves with the world.
view.setPlates([[220, 220], [220, 220], [250, 210]], 2);
check(Math.abs(view.plateOrigin(0)[0] + o2[0]) < 1e-3, "the world of the active plate");
const q2 = view.pixelOf(125, 105, 0);
check(q2 && Math.abs(q2[0] - q[0]) < 0.5 && Math.abs(q2[1] - q[1]) < 0.5, "the picture stays still");
console.log(`plates: ${f.platesCount} in the frame, ${plateBeads} light beads of ${all}`);

// The plate set of the core (zs_set, as in worker.js): two plates, the
// active plate slices first, and a sync as bytes to the view of the
// other instance.
const sliced = [];
const wasm3 = await Wasm.create(module, () => {}, (plate, event) => {
  if (event === 2) sliced.push(plate);
});
const x3 = wasm3.x;
check(x3.zs_set_new_web(wasm3.cell) === 0, "a plate set");
const set = wasm3.u32(wasm3.cell);
const stl = await readFile(stlPath);
const setCore = (i) => new Core(wasm3, null, x3.zs_set_app(set, i));
setCore(0).loadStl("part.stl", stl);
x3.zs_set_changed(set, 0);
check(x3.zs_set_add(set) === 1, "a second plate");
setCore(1).loadStl("part.stl", stl);
x3.zs_set_changed(set, 1);
check(x3.zs_set_next(set) === 1, "the active plate slices first");
while (x3.zs_set_step(set) === 1);
check(sliced.join(",") === "1,0", `the order of the slices (${sliced.join(",")})`);
check(x3.zs_set_sync_write(set, wasm3.cell, wasm3.cell + 4) === 0, "the sync bytes");
const sp = wasm3.u32(wasm3.cell);
const sn = wasm3.u32(wasm3.cell + 4);
const syncBytes = wasm3.u8.slice(sp, sp + sn).buffer;
x3.zs_buffer_free(sp, sn);
view.syncPlates(syncBytes);
check(Math.abs(view.plateOrigin(0)[0]) > 100, "plate 1 is the active plate of the view");
// The clipboard of parts (clipboard.js, zs_app_parts_copy): a copy of
// part 0 of plate 0 pastes on plate 1 at a point, and a copy of plate 0
// pastes on a new empty plate at the same place.
const c0 = setCore(0);
const one = wasm3.alloc(4);
new Uint32Array(x3.memory.buffer, one, 1)[0] = 0;
check(x3.zs_app_parts_copy(c0.app, one, 1, 0) === 0 && x3.zs_clipboard_parts() === 1, "a copy of a part");
wasm3.free(one, 4);
const c1 = setCore(1);
const before = x3.zs_app_part_count(c1.app);
const first = Number(x3.zs_app_parts_paste(c1.app, 1, 60, 70));
check(first === before && x3.zs_app_part_count(c1.app) === before + 1, "a paste on another plate");
const pasted = c1.part(first);
check(Math.abs(pasted.x - 60) < 1e-6 && Math.abs(pasted.y - 70) < 1e-6, "the paste at the point");
check(x3.zs_app_parts_copy(c0.app, 0, 0, 1) === 0 && x3.zs_clipboard_is_plate() === 1, "a copy of the plate");
check(x3.zs_set_add(set) === 2, "a third plate");
const c2 = setCore(2);
check(Number(x3.zs_app_parts_paste(c2.app, 0, 0, 0)) === 0, "a paste on the empty plate");
check(Math.abs(c2.part(0).x - c0.part(0).x) < 1e-9 && Math.abs(c2.part(0).y - c0.part(0).y) < 1e-9, "the plate keeps its places");
check(Number(x3.zs_app_plate_copy_to(c0.app, c2.app)) === 1 && x3.zs_clipboard_is_plate() === 1, "a duplicate keeps the clipboard");
x3.zs_clipboard_clear();
check(Number(x3.zs_app_parts_paste(c2.app, 0, 0, 0)) < 0, "an empty clipboard");
x3.zs_set_free(set);
console.log(`plate set: slices ${sliced.join(", ")}, sync ${(sn / 1e6).toFixed(2)} MB; the clipboard`);
// The text of a copy on the system clipboard (clipboard.js).
const lc = parseClipText(clipText({ kind: "label", id: "a1", data: { label: { filament: 2 } } }));
check(lc.kind === "label" && lc.id === "a1" && lc.data.label.filament === 2, "a label through the system clipboard");
check(parseClipText(clipText({ kind: "parts", id: "p", count: 3 })).count === 3, "a mark of parts");
check(parseClipText("grid").kind === "text" && parseClipText("{oops").kind === "text", "plain text");
check(clipText({ kind: "setting", id: "s", data: { value: "0.2" } }) === "0.2", "a value is plain text");
console.log("ok");
