#!/usr/bin/env node
// zslice: slice a model to G-code in Node.js, with the zslice core in
// WebAssembly (the same core as the web app). It needs no native binary,
// so it runs on each platform that has Node 20 or later.
//
//   zslice slice <model.stl|model.3mf> [options]
//   zslice version
//
// Options (as in the native zslice command):
//   -m, --machine NAME   a machine profile: a built-in name or a .toml path
//   -f, --filament NAME  a filament profile
//   -p, --project NAME   a project profile (the quality)
//   -c key=value         change one setting with its Cura key
//                        (support_enable=false), after the profiles
//                        (repeat it). A key that zslice cannot use stops
//                        the command with the reason.
//   -s group.name=value  change one zslice setting, after the -c settings
//                        (repeat it)
//   -o FILE              the G-code file (default: stdout)
//   --stats FILE         write the print time, the plastic, the layers,
//                        and the bounds as JSON ("-": stderr)
//   --bambu FILE         write the .gcode.3mf file of a Bambu Lab printer
//
// A 3MF file is a plate: each object prints at the place of its build
// item. The command stops if a part is not on the bed. Each object can
// have its own settings in its metadata: Cura keys ("cura:infill_sparse_
// density") or zslice settings ("zslice:project.wall_count"). The command
// stops on a setting that a part cannot have (a setting that zslice keeps
// for the whole plate, such as the brim).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, extname, basename } from "node:path";
import { Wasm } from "../app/wasm.js";
import { Core, STATE } from "../app/core.js";

const here = dirname(fileURLToPath(import.meta.url));
const GROUPS = { machine: 0, filament: 1, project: 2 };

function usage(code) {
  const out = code === 0 ? console.log : console.error;
  out(`usage:
  zslice slice <model.stl|plate.3mf> [-m machine] [-f filament] [-p project] [-c cura_key=value]... [-s group.name=value]... [-o out.gcode] [--stats file] [--bambu out.gcode.3mf]
  zslice version
A profile is a built-in name (zslice profiles lists them in the native command) or a path to a .toml file.`);
  process.exit(code);
}

async function core() {
  const bytes = await readFile(join(here, "../app/zslice.wasm"));
  const wasm = await Wasm.create(await WebAssembly.compile(bytes), () => {});
  return new Core(wasm);
}

// A profile option: a .toml path, or a built-in name.
async function profileText(value) {
  if (extname(value) === ".toml") return readFile(value, "utf8");
  return `extends = "${value}"\n`;
}

async function slice(args) {
  let model = null;
  let out = null;
  let statsOut = null;
  let bambuOut = null;
  const profiles = [];
  const sets = [];
  const cura = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = () => {
      if (i + 1 >= args.length) throw new Error(`${a} needs a value`);
      return args[++i];
    };
    if (a === "-m" || a === "--machine") profiles.push(["machine", next()]);
    else if (a === "-f" || a === "--filament") profiles.push(["filament", next()]);
    else if (a === "-p" || a === "--project") profiles.push(["project", next()]);
    else if (a === "-s" || a === "--set") sets.push(next());
    else if (a === "-c" || a === "--cura") {
      const kv = next();
      const eq = kv.indexOf("=");
      if (eq <= 0) throw new Error(`-c ${kv}: use cura_key=value`);
      cura[kv.slice(0, eq).trim()] = kv.slice(eq + 1).trim();
    }
    else if (a === "-o") out = next();
    else if (a === "--stats") statsOut = next();
    else if (a === "--bambu") bambuOut = next();
    else if (a === "-h" || a === "--help") usage(0);
    else if (a.startsWith("-")) throw new Error(`unknown option ${a}`);
    else if (model === null) model = a;
    else throw new Error(`one model only (${a})`);
  }
  if (!model) usage(2);
  const c = await core();
  for (const [group, value] of profiles) {
    const e = c.loadProfile(GROUPS[group], await profileText(value));
    if (e) throw new Error(`the ${group} profile ${value}: ${e}`);
  }
  if (Object.keys(cura).length > 0) {
    const r = c.curaSettings(cura);
    if (r.unused.length > 0) {
      throw new Error(`zslice cannot use these Cura settings:\n${r.unused.map(([k, v, why]) => `  ${k} = ${v}: ${why}`).join("\n")}`);
    }
    for (const [k, v, why] of r.near) console.error(`zslice: ${k} = ${v}: ${why}`);
    for (const [name, value] of r.sets) {
      const e = c.set(name, value);
      if (e) throw new Error(`-c: ${name} = ${value}: ${e}`);
    }
  }
  for (const s of sets) {
    const eq = s.indexOf("=");
    if (eq < 0) throw new Error(`-s ${s}: use group.name=value`);
    const e = c.set(s.slice(0, eq), s.slice(eq + 1));
    if (e) throw new Error(`-s ${s}: ${e}`);
  }
  // The parts of a 3MF plate stay at their places.
  c.setKeepPlaces(true);
  c.loadStl(basename(model), new Uint8Array(await readFile(model)));
  checkPlate(c);
  const r = c.slice();
  if (r.state !== STATE.done) throw new Error(`the slice failed${r.error ? `: ${r.error}` : ""}`);
  const gcode = c.gcode();
  if (out) await writeFile(out, gcode);
  else if (!bambuOut) process.stdout.write(gcode);
  if (bambuOut) {
    const file = c.bambuFile(basename(model).replace(/\.(stl|3mf)$/i, ""));
    if (!file) throw new Error("the slice has no .gcode.3mf file");
    await writeFile(bambuOut, file);
  }
  if (statsOut) {
    const st = c.stats();
    const fil = c.filamentStats();
    const stats = {
      ...st,
      filamentM: st.filamentMm / 1000,
      filamentGrams: fil ? fil.grams : [],
      filamentChanges: fil ? fil.changes : 0,
      flushG: fil ? fil.flushG : 0,
      layerHeight: Number(c.get("project.layer_height")),
      firstLayerHeight: Number(c.get("project.first_layer_height")),
      parts: c.w.x.zs_app_part_count(c.app),
      bounds: gcodeBounds(typeof gcode === "string" ? gcode : new TextDecoder().decode(gcode)),
    };
    const text = JSON.stringify(stats, null, 2) + "\n";
    if (statsOut === "-") process.stderr.write(text);
    else await writeFile(statsOut, text);
  }
}

// Stops if a part is not on the bed, or has a setting that it cannot use.
function checkPlate(c) {
  const bedX = Number(c.get("machine.bed_size_x"));
  const bedY = Number(c.get("machine.bed_size_y"));
  const n = c.w.x.zs_app_part_count(c.app);
  const problems = [];
  for (let i = 0; i < n; i++) {
    const p = c.part(i);
    if (!p) continue;
    const eps = 1e-6;
    if (p.x - p.sizeX / 2 < -eps || p.y - p.sizeY / 2 < -eps || p.x + p.sizeX / 2 > bedX + eps || p.y + p.sizeY / 2 > bedY + eps) {
      problems.push(`the part "${p.name}" is not on the bed (${bedX} x ${bedY} mm): its footprint is x ${(p.x - p.sizeX / 2).toFixed(2)} to ${(p.x + p.sizeX / 2).toFixed(2)}, y ${(p.y - p.sizeY / 2).toFixed(2)} to ${(p.y + p.sizeY / 2).toFixed(2)}`);
    }
    for (const [k, v, why] of c.partUnused(i)) problems.push(`the part "${p.name}": ${k} = ${v}: ${why}`);
  }
  if (problems.length > 0) throw new Error(`the plate cannot slice as it is:\n${problems.map((t) => `  ${t}`).join("\n")}`);
}

// The box of the extrusions of a G-code text: { min: [x, y, z], max:
// [x, y, z] } in mm, or null with no extrusion. An arc (G2, G3) counts
// with its end points only.
function gcodeBounds(gcode) {
  const pos = { X: 0, Y: 0, Z: 0, E: 0 };
  let absXYZ = true;
  let absE = true;
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  const add = (x, y, z) => {
    const v = [x, y, z];
    for (let k = 0; k < 3; k++) {
      if (v[k] < min[k]) min[k] = v[k];
      if (v[k] > max[k]) max[k] = v[k];
    }
  };
  for (const raw of gcode.split("\n")) {
    const semi = raw.indexOf(";");
    const line = (semi >= 0 ? raw.slice(0, semi) : raw).trim().toUpperCase();
    if (!line) continue;
    const words = line.split(/\s+/);
    const cmd = words[0];
    const arg = {};
    for (const w of words.slice(1)) {
      const v = Number(w.slice(1));
      if (Number.isFinite(v)) arg[w[0]] = v;
    }
    if (cmd === "G90") absXYZ = absE = true;
    else if (cmd === "G91") absXYZ = absE = false;
    else if (cmd === "M82") absE = true;
    else if (cmd === "M83") absE = false;
    else if (cmd === "G92") {
      for (const k of "XYZE") if (k in arg) pos[k] = arg[k];
    } else if (cmd === "G0" || cmd === "G1" || cmd === "G2" || cmd === "G3") {
      const from = [pos.X, pos.Y, pos.Z];
      for (const k of "XYZ") if (k in arg) pos[k] = absXYZ ? arg[k] : pos[k] + arg[k];
      let extrudes = false;
      if ("E" in arg) {
        const e = absE ? arg.E : pos.E + arg.E;
        extrudes = e > pos.E + 1e-9;
        pos.E = e;
      }
      if (extrudes) {
        add(...from);
        add(pos.X, pos.Y, pos.Z);
      }
    }
  }
  if (min[0] === Infinity) return null;
  const r = (v) => v.map((x) => Math.round(x * 1000) / 1000);
  return { min: r(min), max: r(max) };
}

const [cmd, ...rest] = process.argv.slice(2);
try {
  if (cmd === "slice") await slice(rest);
  else if (cmd === "version") {
    const pkg = JSON.parse(await readFile(join(here, "../package.json"), "utf8"));
    console.log(pkg.version);
  } else usage(cmd ? 2 : 0);
} catch (e) {
  console.error(`zslice: ${e.message}`);
  process.exit(1);
}
