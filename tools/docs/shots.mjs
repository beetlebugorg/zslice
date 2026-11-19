// shots.mjs: makes the screenshots of the docs (docs/img/) from the web app.
//
// Run it after a change to the look of the app:
//
//   zig build web
//   DOCS_GPU=1 node tools/docs/shots.mjs            # all pictures
//   DOCS_GPU=1 node tools/docs/shots.mjs hero keys  # some pictures
//
// Each scene opens the app in a new headless Chromium (see cdp.mjs), adds
// the Prusa MK4S from the printer picker, opens a model, and saves one
// picture (or one animation) in docs/img/. The 3DBenchy comes from
// ../zslice-testparts/3DBenchy.stl (set BENCHY to use another path). The
// other parts are boxes that parts.mjs writes.
//
// The animations need img2webp (libwebp).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { execFileSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { ROOT, serve, open, openModel, sliced, sleep } from "./cdp.mjs";
import { writeParts } from "./parts.mjs";

const IMG = path.join(ROOT, "docs/img");
const BENCHY = process.env.BENCHY ?? path.resolve(ROOT, "../zslice-testparts/3DBenchy.stl");

// ---- helpers in the page ----

// Opens the app, adds the Prusa MK4S from the picker of the first start,
// and opens `model` (a file of the served folder).
async function start(srv, model, size = {}) {
  const page = await open(srv.url + "index.html?q=mk4s&pick=prusa-mk4s", size);
  await page.waitFor("window.zslice && document.querySelector('.picker-shade')");
  await sleep(1000);
  await button(page, "Next");
  await sleep(500);
  await button(page, "Add printer");
  await page.waitFor("!document.querySelector('.picker-shade')");
  await sleep(800);
  if (model) {
    await openModel(page, model);
    await sleep(800);
  }
  return page;
}

// Clicks the button with this text.
async function button(page, text, scope = "body") {
  const ok = await page.eval(`(() => {
    const b = [...document.querySelectorAll(${JSON.stringify(scope + " button")})].find((b) => b.textContent.trim() === ${JSON.stringify(text)} && b.offsetParent);
    if (b) b.click();
    return !!b;
  })()`);
  if (!ok) throw new Error(`no button "${text}"`);
}

// Picks an item of the menu that shows.
async function menuItem(page, text) {
  await sleep(250);
  await button(page, text, "#menu-layer");
  await sleep(300);
}

async function colors(page, mode) {
  await page.eval("document.getElementById('colors').click(); 1");
  await menuItem(page, mode);
  await sleep(600);
}

async function set(page, name, value) {
  await page.eval(`zslice.setSetting(${JSON.stringify(name)}, ${JSON.stringify(String(value))}).then(() => 1)`);
  await sliced(page);
}

// Moves the camera: an orbit of dx, dy pixels, then the part in the middle
// of the view, filling `fill` of its smaller side, then a pan of dx, dy
// pixels.
async function camera(page, { orbit = [0, 0], fill = 0.6, zoom = 1, pan = [0, 0] } = {}) {
  await page.eval(`(() => {
    const v = zslice.view;
    v.orbit(${orbit[0]}, ${orbit[1]});
    v.x.zs_view_frame_part(v.v, ${fill});
    if (${zoom} !== 1) v.x.zs_view_zoom(v.v, ${zoom});
    v.pan(${pan[0]}, ${pan[1]});
    zslice.requestFrame();
    return 1;
  })()`);
  await sleep(700);
}

// The pixel (CSS) of a point of the world in mm.
async function pixel(page, x, y, z) {
  return page.eval(`(() => {
    const p = zslice.view.pixelOf(${x}, ${y}, ${z});
    const r = window.devicePixelRatio || 1;
    const b = document.getElementById("gl").getBoundingClientRect();
    return p && [b.left + p[0] / r, b.top + p[1] / r];
  })()`);
}

// Clicks the 3D view at the pixel of a point of the world.
async function clickWorld(page, x, y, z, extra) {
  const p = await pixel(page, x, y, z);
  await page.click(p[0], p[1], extra);
  await sleep(700);
  return p;
}

// A pixel (CSS) of the 3D view with a line of a layer from lo to hi under
// it, or null. It scans the view on a grid of `step` pixels, from the top.
async function findLine(page, lo, hi, step = 6) {
  return page.eval(`(() => {
    const v = zslice.view, c = document.getElementById("gl"), r = window.devicePixelRatio || 1;
    const b = c.getBoundingClientRect();
    for (let y = 0; y < b.height; y += ${step})
      for (let x = 0; x < b.width; x += ${step}) {
        if (!v.pickSegment(x * r, y * r)) continue;
        const l = v.pathLayer(v.hit[0]);
        if (l >= ${lo} && l <= ${hi}) return [b.left + x, b.top + y];
      }
    return null;
  })()`);
}

async function keyIn(page, key, extra) {
  await page.eval("document.getElementById('gl').focus(); 1");
  await page.key(key, extra);
  await sleep(500);
}

// The box of the beads: [min x, min y, max x, max y].
const bounds = (page) => page.eval("zslice.view.bounds()");

// Saves a picture of the page as docs/img/<name>.webp, made smaller to
// `width` pixels.
async function save(page, name, { width = 1400, clip, keepToast = false } = {}) {
  const raw = path.join(tmp, `${name}.raw.png`);
  await sleep(400);
  if (!keepToast) await page.eval("document.getElementById('toast').hidden = true; 1");
  await page.shot(raw, clip);
  const out = path.join(IMG, `${name}.webp`);
  execFileSync("magick", [raw, "-resize", `${width}x>`, "-strip", "-quality", "86", "-define", "webp:method=6", out]);
  console.log("wrote", path.relative(ROOT, out));
}

// Numbers on the page, as in a gamebook: an orange dot with a number at
// each point [x, y, n] (CSS pixels). The page draws them, so the picture
// needs no fonts of this machine.
async function badges(page, points) {
  await page.eval(`(() => {
    for (const [x, y, n] of ${JSON.stringify(points)}) {
      const b = document.createElement("div");
      b.textContent = n;
      b.style.cssText = "position:fixed;z-index:99999;width:34px;height:34px;border-radius:50%;display:flex;align-items:center;" +
        "justify-content:center;background:#ff5a1f;color:#fff;border:3px solid #171717;font:700 18px ui-monospace,monospace;" +
        "box-shadow:2px 2px 0 rgba(0,0,0,.35);left:" + (x - 17) + "px;top:" + (y - 17) + "px";
      document.body.append(b);
    }
    return 1;
  })()`);
}

// Writes docs/img/<name>.webp from [file, time ms] frames.
async function webp(name, frames, width, quality = 70) {
  const args = ["-loop", "0", "-lossy", "-q", String(quality), "-m", "6"];
  for (let i = 0; i < frames.length; i++) {
    const [f, t] = frames[i];
    const next = i + 1 < frames.length ? frames[i + 1][1] : t + 1500;
    const small = f.replace(/\.png$/, ".s.png");
    execFileSync("magick", [f, "-resize", `${width}x>`, small]);
    args.push("-d", String(Math.max(20, Math.round(next - t))), small);
  }
  const out = path.join(IMG, `${name}.webp`);
  execFileSync("img2webp", [...args, "-o", out], { stdio: "ignore" });
  console.log("wrote", path.relative(ROOT, out), `(${frames.length} frames)`);
}

// ---- the scenes ----

const SCENES = {
  // The home page and the README: the Benchy in the colors of its features.
  async hero(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { orbit: [-120, 30], zoom: 0.5 });
    await save(p, "hero");
    await p.close();
  },

  // The printer picker of the first start.
  async picker(srv) {
    const p = await open(srv.url + "index.html?q=mk4s&pick=prusa-mk4s");
    await p.waitFor("window.zslice && document.querySelector('.picker-shade')");
    await sleep(2000);
    await save(p, "start-picker");
    await p.close();
  },

  // The window, with a number on each of its areas.
  async window(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { fill: 0.5 });
    await badges(p, [[560, 23, 1], [80, 240, 2], [1330, 300, 3], [330, 810, 4], [1000, 810, 5]]);
    await save(p, "start-window");
    await p.close();
  },

  // A click on a line of the chimney: the card of the line.
  async linecard(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { zoom: 0.55, pan: [-200, 0] });
    // The chimney: the only lines of the top layers. A line a few
    // pixels under the top edge of the chimney.
    const at = await findLine(p, 200, 215, 4);
    await p.click(at[0] + 6, at[1] + 8);
    await sleep(800);
    await save(p, "line-card");
    await p.close();
  },

  // The search, with infill density.
  async search(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { zoom: 0.55, pan: [300, 0] });
    await keyIn(p, "/");
    await p.eval("document.activeElement.value = 'infill density'; document.activeElement.dispatchEvent(new Event('input', {bubbles: true})); 1");
    await sleep(1200);
    await save(p, "search");
    await p.close();
  },

  // The settings panel, pinned, at one setting: the preview shows only
  // the lines of the setting.
  async panel(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { fill: 0.6 });
    await keyIn(p, "n");
    await button(p, "Pin");
    await p.eval("zslice.browser.openSetting('project.top_thickness'); 1");
    await sleep(1500);
    await save(p, "settings-panel");
    await p.close();
  },
  // The Move tool and the card of the part.
  async partcard(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { zoom: 0.6, pan: [-150, 0] });
    await keyIn(p, "m");
    const b = await bounds(p);
    await clickWorld(p, (b[0] + b[2]) / 2, (b[1] + b[3]) / 2, 12);
    await save(p, "part-card");
    await p.close();
  },

  // The Turn tool: the three rings of the part.
  async turn(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { zoom: 0.8 });
    await keyIn(p, "r");
    const b = await bounds(p);
    await clickWorld(p, (b[0] + b[2]) / 2, (b[1] + b[3]) / 2, 12);
    await save(p, "turn-rings");
    await p.close();
  },

  // A board on its thin edge: a turn tips it, and it falls onto a face.
  // The scene steps the rigid body of the core itself (as runFall in
  // app.js does), 1/30 s for each frame, so the animation is smooth.
  async fall(srv) {
    const p = await start(srv, "board.stl");
    await colors(p, "Feature");
    await camera(p, { orbit: [-60, 0], zoom: 0.9 });
    const clip = { x: 250, y: 150, width: 900, height: 560 };
    const dir = path.join(tmp, "fall");
    execFileSync("mkdir", ["-p", dir]);
    const frames = [];
    const shot = async (ms) => {
      const f = path.join(dir, `f${String(frames.length).padStart(3, "0")}.png`);
      await p.shot(f, clip);
      frames.push([f, ms]);
    };
    await shot(1200);
    await p.eval("zslice.client.call('partTurn', { index: 0, axis: 0, degrees: 25, hold: true }).then(() => 1)");
    await sleep(800);
    await p.eval("zslice.requestFrame(); 1");
    await sleep(300);
    await shot(700);
    const started = await p.eval("zslice.client.call('fallStart', { index: 0 }).then((r) => r.started)");
    if (!started) throw new Error("the board did not fall");
    for (let i = 0; i < 300; i++) {
      const done = await p.eval(`zslice.client.call('fallStep', { dt: 1 / 30 }).then((f) => {
        const v = zslice.view;
        if (f.none) return true;
        if (!f.done) v.x.zs_view_part_preview(v.v, 0, f.q[0], f.q[1], f.q[2], f.q[3], f.pivot[0], f.pivot[1], f.pivot[2], f.move[0], f.move[1], f.move[2], 0);
        zslice.drawNow();
        return !!f.done;
      })`);
      if (done) break;
      await shot(33);
    }
    await p.eval("zslice.client.call('sliceHeld').then(() => 1)");
    await sliced(p);
    await shot(2000);
    // Frames as [file, ms]: webp() wants the times of the frames.
    let t = 0;
    await webp("fall", frames.map(([f, ms]) => [f, (t += ms) - ms]), 720);
    await p.close();
  },

  // The Support tool on a shelf: a click under the shelf puts a support
  // area there.
  async support(srv) {
    const p = await start(srv, "shelf.stl");
    await colors(p, "Feature");
    await camera(p, { orbit: [-80, 0], zoom: 0.8 });
    await keyIn(p, "s");
    const b = await bounds(p);
    const at = await pixel(p, b[0] + 8, b[1], 40.5);
    await p.move(at[0], at[1]);
    await sleep(800);
    await p.click(at[0], at[1]);
    await sliced(p);
    await save(p, "support-area");
    await p.close();
  },

  // Tree support on the shelf: the Support tool shows the nodes of the
  // trees as dots, to drag.
  async tree(srv) {
    const p = await start(srv, "shelf.stl");
    await colors(p, "Feature");
    await set(p, "project.support", "everywhere");
    await set(p, "project.support_style", "tree");
    await camera(p, { orbit: [-80, 0], zoom: 0.7 });
    await keyIn(p, "s");
    await sleep(1000);
    // The trees solid, with their dots.
    await p.eval("[...document.querySelectorAll('label')].find((l) => l.textContent.includes('See through'))?.click(); 1");
    await sleep(1500);
    await save(p, "support-tree");
    await p.close();
  },

  // The gaps of layer 50 of the Benchy, with gap fill off.
  async gaps(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await set(p, "project.gap_fill", "false");
    await p.eval("zslice.layers.set(0, 49); 1");
    await sleep(800);
    await keyIn(p, "g");
    await p.eval("document.getElementById('view-2d').click(); 1");
    await sleep(1000);
    // Zoom the 2D view to the bow, where the gaps are.
    for (let i = 0; i < 2; i++) {
      await p.send("Input.dispatchMouseEvent", { type: "mouseWheel", x: 860, y: 640, deltaX: 0, deltaY: -240 });
      await sleep(200);
    }
    await sleep(1000);
    await save(p, "gaps");
    await p.close();
  },

  // Check on the shelf with support off.
  async check(srv) {
    const p = await start(srv, "shelf.stl");
    await colors(p, "Feature");
    await camera(p, { orbit: [-80, 0], zoom: 0.9 });
    await p.eval("document.getElementById('check').click(); 1");
    await sleep(1500);
    await save(p, "check");
    await p.close();
  },

  // The measure tape across the shelf.
  async measure(srv) {
    const p = await start(srv, "shelf.stl");
    await colors(p, "Feature");
    await camera(p, { orbit: [-80, 0], zoom: 0.9 });
    await keyIn(p, "t");
    const b = await bounds(p);
    await clickWorld(p, b[0] + 0.2, b[1] + 0.2, 43);
    await clickWorld(p, b[2] - 0.2, b[1] + 0.2, 43);
    await sleep(800);
    await save(p, "measure");
    await p.close();
  },

  // Two plates, side by side.
  async plates(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await button(p, "+ Plate");
    await sleep(1000);
    await openModel(p, "shelf.stl");
    await sleep(1000);
    await button(p, "All");
    await sleep(2000);
    await save(p, "plates");
    await p.close();
  },

  // The history: three changes, and the list of them.
  async history(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { zoom: 0.6 });
    await set(p, "project.wall_count", "3");
    await set(p, "project.infill_density", "0.35");
    await set(p, "project.infill_pattern", "gyroid");
    await button(p, "History");
    await sleep(1200);
    await save(p, "history");
    await p.close();
  },

  // The sheet of the keyboard shortcuts.
  async keys(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await keyIn(p, "?");
    await sleep(800);
    await save(p, "keys");
    await p.close();
  },

  // The details of the print card.
  async printcard(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { zoom: 0.6, pan: [-200, 0] });
    await p.eval("document.getElementById('sum-more').click(); 1");
    await sleep(1000);
    await save(p, "print-card");
    await p.close();
  },

  // The 2D view of a layer.
  async view2d(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await p.eval("zslice.layers.set(0, 70); document.getElementById('view-2d').click(); 1");
    await sleep(1500);
    await save(p, "view-2d");
    await p.close();
  },

  // The Project dialog: Open a project… in the main menu.
  async project(srv) {
    const p = await start(srv, "3DBenchy.stl");
    await colors(p, "Feature");
    await camera(p, { zoom: 0.6 });
    await p.eval("document.getElementById('main-menu').click(); 1");
    await menuItem(p, "Open a project…");
    await sleep(800);
    await save(p, "project");
    await p.close();
  },

  // The web app on a phone.
  async phone(srv) {
    const p = await start(srv, "3DBenchy.stl", { w: 390, h: 844, scale: 2 });
    await colors(p, "Feature");
    await camera(p, { zoom: 0.7 });
    await save(p, "phone", { width: 780 });
    await p.close();
  },
};

const tmp = await mkdtemp(path.join(tmpdir(), "zslice-shots-"));
const parts = await writeParts(tmp);
const srv = await serve({ "3DBenchy.stl": BENCHY, ...parts });
try {
  const names = process.argv.slice(2);
  for (const name of names.length ? names : Object.keys(SCENES)) {
    if (!SCENES[name]) throw new Error(`no scene ${name}: ${Object.keys(SCENES).join(", ")}`);
    console.log("scene", name);
    await SCENES[name](srv);
  }
} finally {
  await srv.close();
  await rm(tmp, { recursive: true, force: true });
}
