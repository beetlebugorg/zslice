// sim_anim.mjs: the animation of "The print as it forms" in the docs
// (docs/img/sim-forms.webp, with docs/img/sim-bridge.webp and
// docs/img/sim-slab.webp as stills).
//
// It slices two parts with support off, turns on the simulation of the
// plastic, and replays the print layer by layer:
//
// 1. bridge80 of tools/stress/gen.py: a deck 80 mm long between two
//    piers. The bridge sags.
// 2. tee.stl of parts.mjs: a slab that sticks out 20 mm into the air on
//    each side of a post. The plastic over the air falls, and the next
//    layers print on it. (The cantilever of gen.py hangs out on one
//    side only. The bond of its post to the bed holds it up.)
//
// Each clip ends on a still frame. Run it again after a change of the
// physics (src/print_sim.zig):
//
//   zig build web
//   DOCS_GPU=1 node tools/docs/sim_anim.mjs
//
// It needs python3, ImageMagick (magick), and img2webp (libwebp).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { execFileSync } from "node:child_process";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { ROOT, serve, open, openModel, sliced, sleep } from "./cdp.mjs";
import { writeParts } from "./parts.mjs";

const IMG = path.join(ROOT, "docs/img");
const W = 1200, H = 720;
// The frames of each clip, and the time of one frame (ms).
const FRAMES = 48, FRAME_MS = 90, HOLD_MS = 2200;

const tmp = await mkdtemp(path.join(tmpdir(), "zslice-sim-"));
execFileSync("python3", ["-I", path.join(ROOT, "tools/stress/gen.py"), path.join(tmp, "parts"), "--quick"], { stdio: "ignore" });
const parts = await writeParts(tmp);
const srv = await serve({
  "bridge80.stl": path.join(tmp, "parts/bridge80__t0_s1.stl"),
  "tee.stl": parts["tee.stl"],
});

// The 3D view of the page at the time t (s) of the print.
async function showTime(page, t) {
  await page.eval(`(() => {
    const z = zslice, v = z.view;
    v.setTime(${t});
    z.app.time = ${t};
    const l = v.layerAtTime(${t});
    z.layers.set(0, l, true);
    z.drawNow();
    return 1;
  })()`);
}

// One clip: the frames of the print of `model` from the height z0 (mm) to
// the end, in the simulation. Returns [file, ms] frames.
async function clip(name, model, z0, look) {
  const page = await open(srv.url + "index.html", { w: W, h: H });
  await page.waitFor("window.zslice && window.zslice.client");
  await sleep(800);
  await page.eval("document.querySelector('.picker-shade')?.remove(); 1");
  await openModel(page, model);
  await page.eval("zslice.client.call('mode', { value: 1 }).then(() => (zslice.app.mode = 1))");
  await page.eval("zslice.setSetting('project.support', 'off').then(() => 1)");
  await sliced(page);
  const r = await page.eval("zslice.client.call('simulate', { on: true })");
  if (r.error) throw new Error(r.error);
  await page.waitFor("zslice.app.simulated === true");
  await sliced(page);
  // The camera: a look at the middle of the part from the front, a little
  // from above. Then the UI hides, so the frames show only the print.
  const b = await page.eval("zslice.view.bounds()");
  const [cx, cy] = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2];
  await page.eval(`(() => { const v = zslice.view; v.x.zs_view_look_at(v.v, ${cx}, ${cy}, ${look.z}, ${look.n.join(", ")}, ${look.dist}); return 1; })()`);
  for (let i = 0; i < 60; i++) {
    await page.eval("zslice.view.animate(0.05); zslice.drawNow(); 1");
  }
  await page.eval(`(() => {
    for (const s of ['.headerbar', '.toolstrip', '#dock', '#layers', '#toast', '#legend']) {
      const e = document.querySelector(s);
      if (e) e.style.visibility = 'hidden';
    }
    return 1;
  })()`);
  const times = await page.eval(`(() => {
    const L = zslice.app.layers;
    let i = L.z.findIndex((z) => z >= ${z0});
    return [i > 0 ? L.endTime[i - 1] : 0, zslice.view.duration()];
  })()`);
  const frames = [];
  const dir = path.join(tmp, name);
  execFileSync("mkdir", ["-p", dir]);
  for (let i = 0; i <= FRAMES; i++) {
    const t = times[0] + (times[1] - times[0]) * (i / FRAMES) ** 1.3;
    await showTime(page, i === FRAMES ? times[1] : t);
    await sleep(60);
    const f = path.join(dir, `f${String(i).padStart(3, "0")}.png`);
    await page.shot(f, { x: 0, y: 48, width: W, height: H - 48 });
    frames.push([f, i === FRAMES ? HOLD_MS : FRAME_MS]);
  }
  // The still: the end of the print.
  execFileSync("magick", [frames.at(-1)[0], "-resize", "1000x", "-strip", "-quality", "86", path.join(IMG, `sim-${name}.webp`)]);
  console.log("wrote", `docs/img/sim-${name}.webp`);
  await page.close();
  return frames;
}

try {
  const frames = [
    ...(await clip("bridge", "bridge80.stl", 9.6, { z: 8, n: [0, -1, 0.25], dist: 80 })),
    ...(await clip("slab", "tee.stl", 19.6, { z: 14, n: [0.2, -1, 0.3], dist: 70 })),
  ];
  const args = ["-loop", "0", "-lossy", "-q", "60", "-m", "6"];
  for (const [f, ms] of frames) {
    const small = f.replace(/\.png$/, ".s.png");
    execFileSync("magick", [f, "-resize", "720x", small]);
    args.push("-d", String(ms), small);
  }
  const out = path.join(IMG, "sim-forms.webp");
  execFileSync("img2webp", [...args, "-o", out], { stdio: "ignore" });
  console.log("wrote docs/img/sim-forms.webp", Math.round((await stat(out)).size / 1024), "KB");
} finally {
  await srv.close();
  await rm(tmp, { recursive: true, force: true });
}
