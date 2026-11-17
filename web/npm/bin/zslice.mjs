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
//   -s group.name=value  change one setting, after the profiles (repeat it)
//   -o FILE              the G-code file (default: stdout)
//   --stats FILE         write the print time, the plastic, and the layers
//                        as JSON ("-": stderr)
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
  zslice slice <model.stl|model.3mf> [-m machine] [-f filament] [-p project] [-s group.name=value]... [-o out.gcode] [--stats file]
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
  const profiles = [];
  const sets = [];
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
    else if (a === "-o") out = next();
    else if (a === "--stats") statsOut = next();
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
  for (const s of sets) {
    const eq = s.indexOf("=");
    if (eq < 0) throw new Error(`-s ${s}: use group.name=value`);
    const e = c.set(s.slice(0, eq), s.slice(eq + 1));
    if (e) throw new Error(`-s ${s}: ${e}`);
  }
  c.loadStl(basename(model), new Uint8Array(await readFile(model)));
  const r = c.slice();
  if (r.state !== STATE.done) throw new Error(`the slice failed${r.error ? `: ${r.error}` : ""}`);
  const gcode = c.gcode();
  if (out) await writeFile(out, gcode);
  else process.stdout.write(gcode);
  if (statsOut) {
    const text = JSON.stringify(c.stats(), null, 2) + "\n";
    if (statsOut === "-") process.stderr.write(text);
    else await writeFile(statsOut, text);
  }
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
