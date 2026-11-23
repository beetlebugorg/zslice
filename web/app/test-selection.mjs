// test-selection.mjs: the acceptance tests of the selection model in a real
// browser (docs/internals/selection.md, issue #36).
//
// Run, in a memory cap:
//   zig build web
//   PLAYWRIGHT=/path/to/node_modules/playwright-core \
//     node web/app/test-selection.mjs zig-out/web/app part.stl [only]
//
// The test serves the build with serve.py on a free port, and drives
// Chromium with real pointer events. It stops the browser and the server
// by their handles. part.stl is a large part, so that a slice runs for a
// while. `only` runs the tests whose name has that text.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [appDir, bigPart, only] = process.argv.slice(2);
if (!appDir || !bigPart) {
  console.error("usage: node test-selection.mjs <app folder> <part.stl> [only]");
  process.exit(2);
}
const pw = process.env.PLAYWRIGHT ?? "playwright-core";
const { chromium } = createRequire(import.meta.url)(pw);

// A binary STL of a box, sx by sy by sz mm.
function boxStl(sx, sy, sz) {
  const v = [[0, 0, 0], [sx, 0, 0], [sx, sy, 0], [0, sy, 0], [0, 0, sz], [sx, 0, sz], [sx, sy, sz], [0, sy, sz]];
  const f = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]];
  const b = Buffer.alloc(84 + 50 * f.length);
  b.writeUInt32LE(f.length, 80);
  f.forEach((t, i) => {
    let o = 84 + 50 * i + 12;
    for (const k of t) for (const c of v[k]) {
      b.writeFloatLE(c, o);
      o += 4;
    }
  });
  return b;
}

const freePort = () => new Promise((res) => {
  const s = net.createServer();
  s.listen(0, "127.0.0.1", () => {
    const { port } = s.address();
    s.close(() => res(port));
  });
});

const port = await freePort();
const server = spawn("python3", ["-I", path.join(here, "serve.py"), appDir, "--port", String(port)], { stdio: "ignore" });
let browser = null;
const stopAll = async () => {
  if (browser) await browser.close().catch(() => {});
  server.kill();
};
for (let i = 0; i < 100; i++) {
  try {
    await fetch(`http://127.0.0.1:${port}/`);
    break;
  } catch {
    await new Promise((r) => setTimeout(r, 100));
  }
}

const cube = boxStl(25, 25, 12);
// Wide enough on the screen to leave room between the handles of the gizmo.
const wide = boxStl(50, 50, 10);
const big = readFileSync(bigPart);

async function newPage(model, copies) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.route("**/test-cube.stl", (r) => r.fulfill({ body: cube, contentType: "model/stl" }));
  await page.route("**/test-wide.stl", (r) => r.fulfill({ body: wide, contentType: "model/stl" }));
  await page.route("**/test-big.stl", (r) => r.fulfill({ body: big, contentType: "model/stl" }));
  await page.goto(`http://127.0.0.1:${port}/?model=${model}&copies=${copies}`);
  await page.waitForFunction((n) => window.zslice?.app?.parts >= n, copies, { timeout: 180000 });
  await idle(page);
  return { page, ctx, errors };
}

const idle = (page) => page.waitForFunction(() => {
  const z = window.zslice;
  return z && z.app.state === "done" && !z.app.slicing && !z.app.draft;
}, null, { timeout: 180000, polling: 50 });

// The selected ids, the primary id, and the ids of the plate now.
const state = (page) => page.evaluate(() => {
  const z = window.zslice;
  const s = z.tools.sel;
  const n = z.app.parts;
  const ids = [];
  for (let i = 0; i < n; i++) ids.push(s.idAt(i));
  return { selected: s.ids(), primary: s.primary, ids, plate: s.plate, plates: z.app.plates.length };
});

// The page point of the top middle of part `id`.
const pointOf = (page, id) => page.evaluate((pid) => {
  const z = window.zslice;
  const b = z.tools.sel.box(pid);
  // The middle of the box: a part with a free top (a boat) has beads here
  // or its footprint behind.
  const q = z.view.pixelOf((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, (b.z0 + b.z1) / 2);
  const r = document.getElementById("gl").getBoundingClientRect();
  const k = window.devicePixelRatio || 1;
  return [r.left + q[0] / k, r.top + q[1] / k];
}, id);

async function clickPart(page, id) {
  const [x, y] = await pointOf(page, id);
  await page.mouse.click(x, y);
  return page.evaluate(() => window.zslice.tools.sel.primary);
}

// A real drag of the part body from its top middle by (dx, dy) pixels.
async function dragPart(page, id, dx, dy, steps = 6) {
  // A point of the part with no gizmo handle on it: a press on a handle
  // is a drag of that handle.
  const [x, y] = await page.evaluate((pid) => {
    const z = window.zslice;
    z.drawNow();
    const b = z.tools.sel.box(pid);
    const r = document.getElementById("gl").getBoundingClientRect();
    const k = window.devicePixelRatio || 1;
    for (let u = 0.1; u < 1; u += 0.1) for (let v = 0.1; v < 1; v += 0.1) {
      const q = z.view.pixelOf(b.x0 + u * (b.x1 - b.x0), b.y0 + v * (b.y1 - b.y0), b.z1);
      if (!q) continue;
      const px = r.left + q[0] / k;
      const py = r.top + q[1] / k;
      const on = document.elementFromPoint(px, py);
      if (on?.id !== "gl") continue;
      if (z.tools.sel.pick(z.view, q[0], q[1]) === pid && z.view.x.zs_view_gizmo_at(z.view.v, q[0], q[1], 10 * k) < 0) return [px, py];
    }
    const m = z.view.pixelOf((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, b.z1);
    throw new Error(`no free point on part ${pid}: pick ${z.tools.sel.pick(z.view, m[0], m[1])}, handle ${z.view.x.zs_view_gizmo_at(z.view.v, m[0], m[1], 10 * k)}, on ${document.elementFromPoint(r.left + m[0] / k, r.top + m[1] / k)?.className}, size ${JSON.stringify(z.view.pixelOf(b.x1, b.y1, b.z1))} ${JSON.stringify(m)}`);
  }, id);
  await page.mouse.move(x, y);
  await page.mouse.down();
  for (let i = 1; i <= steps; i++) await page.mouse.move(x + (dx * i) / steps, y + (dy * i) / steps);
  await page.mouse.up();
}

const movePartTo = (page, index, x, y) => page.evaluate(async ([i, px, py]) => {
  await window.zslice.client.call("partMove", { index: i, x: px, y: py });
}, [index, x, y]);

const check = (ok, text) => {
  if (!ok) throw new Error(text);
};

const tests = {
  async "select a part after a move of another part, 100 times"() {
    const { page, ctx, errors } = await newPage("test-cube.stl", 2);
    await movePartTo(page, 0, 165, 165);
    await idle(page);
    const { ids } = await state(page);
    const [a, b] = ids;
    await page.keyboard.press("m");
    let right = 0;
    for (let k = 0; k < 100; k++) {
      check((await clickPart(page, a)) === a, `round ${k}: the click on the moved part missed`);
      const sign = k % 2 ? -1 : 1;
      await dragPart(page, a, 14 * sign, -6 * sign);
      // No wait for the slice: the click comes right after the drag.
      const got = await clickPart(page, b);
      check(got === b, `round ${k}: the click on the other part gave ${got}`);
      right++;
    }
    await idle(page);
    const at = await page.evaluate(async (id) => {
      const z = window.zslice;
      const i = z.tools.sel.indexOf(id);
      const p = (await z.client.call("partGet", { index: i })).part;
      const q = z.tools.sel.box(id);
      return { dx: Math.abs(p.x - (q.x0 + q.x1) / 2), dy: Math.abs(p.y - (q.y0 + q.y1) / 2) };
    }, a);
    check(at.dx < 0.01 && at.dy < 0.01, "the model and the worker differ on the place of the moved part");
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `${right}/100 clicks`;
  },

  async "Grab after 50 random selects and deselects, with two plates"() {
    const { page, ctx, errors } = await newPage("test-wide.stl", 2);
    await movePartTo(page, 0, 160, 160);
    await idle(page);
    const { ids } = await state(page);
    await page.evaluate(async () => {
      const z = window.zslice;
      await z.addPlate();
      const r = await fetch("test-wide.stl");
      await z.openFile(new File([await r.arrayBuffer()], "test-wide.stl"));
    });
    await page.waitForFunction(() => window.zslice.app.plates.length === 2 && window.zslice.app.plates[1].parts === 1);
    await idle(page);
    await page.evaluate(() => window.zslice.activatePlate(0, true));
    await page.waitForFunction(() => window.zslice.tools.sel.idAt(0) !== 0 && window.zslice.app.shownPlate === 0);
    await idle(page);
    await page.waitForTimeout(600); // The camera move ends.
    await page.keyboard.press("g");
    let seed = 50;
    const rnd = (n) => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % n;
    };
    for (let k = 0; k < 50; k++) {
      const c = rnd(3);
      if (c === 2) {
        await page.keyboard.press("Escape");
        await page.evaluate(() => window.zslice.tools.selectPart(null));
      } else {
        const got = await clickPart(page, ids[c]);
        if (got !== ids[c]) {
          const [x, y] = await pointOf(page, ids[c]);
          const d = await page.evaluate(([px, py]) => {
            const z = window.zslice;
            const r = document.getElementById("gl").getBoundingClientRect();
            const q = [px - r.left, py - r.top];
            return { pick: z.tools.sel.pick(z.view, q[0], q[1]), handle: z.view.x.zs_view_gizmo_at(z.view.v, q[0], q[1], 9), tool: z.tools.tool, at: document.elementFromPoint(px, py)?.id || document.elementFromPoint(px, py)?.className, plate: z.tools.sel.plate , card: (() => { const c = document.querySelector(".part-card")?.getBoundingClientRect(); return c && [c.left, c.top, c.right, c.bottom].map(Math.round); })(), view: [Math.round(r.width), Math.round(r.height)], avoid: z.partCard.otherBoxes(1).map((b) => b.map(Math.round)), user: z.partCard.userAt ?? null };
          }, [x, y]);
          throw new Error(`select ${k}: got ${got}, want ${ids[c]}: ${JSON.stringify(d)}`);
        }
      }
    }
    let grabbed = 0;
    for (const id of ids) {
      const before = await page.evaluate((p) => window.zslice.tools.sel.box(p), id);
      await dragPart(page, id, 12, 5);
      const after = await page.evaluate((p) => window.zslice.tools.sel.box(p), id);
      check(Math.abs(after.x0 - before.x0) + Math.abs(after.y0 - before.y0) > 0.5, `Grab missed part ${id}`);
      grabbed++;
    }
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `${grabbed}/2 grabs`;
  },

  async "add a plate after a full plate, go to each plate, select a part on it"() {
    const { page, ctx, errors } = await newPage("test-cube.stl", 12);
    await page.evaluate(async () => {
      const z = window.zslice;
      await z.client.call("plate", { action: "arrange" });
      await z.addPlate();
      const r = await fetch("test-cube.stl");
      await z.openFile(new File([await r.arrayBuffer()], "test-cube.stl"));
    });
    await page.waitForFunction(() => window.zslice.app.plates.length === 2 && window.zslice.app.plates[1].parts === 1);
    await idle(page);
    await page.keyboard.press("m");
    for (let round = 0; round < 3; round++) {
      for (const i of [0, 1]) {
        await page.evaluate((p) => window.zslice.activatePlate(p, true), i);
        await page.waitForFunction((p) => window.zslice.app.shownPlate === p && window.zslice.tools.sel.plate === p, i);
        await idle(page);
        await page.waitForTimeout(500);
        const s = await state(page);
        check(s.plate === i, `the focus is on plate ${s.plate}, want ${i}`);
        const id = s.ids[s.ids.length - 1];
        const got = await clickPart(page, id);
        check(got === id, `plate ${i}: the click gave ${got}, want ${id}`);
      }
    }
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "3 rounds on 2 plates";
  },

  async "plate focus: fast keys, buttons, and All while a slice runs"() {
    const { page, ctx, errors } = await newPage("test-big.stl", 1);
    await page.evaluate(async () => {
      const z = window.zslice;
      await z.addPlate();
      const r = await fetch("test-cube.stl");
      await z.openFile(new File([await r.arrayBuffer()], "test-cube.stl"));
      await z.addPlate();
      const q = await fetch("test-cube.stl");
      await z.openFile(new File([await q.arrayBuffer()], "test-cube.stl"));
    });
    await page.waitForFunction(() => window.zslice.app.plates.length === 3 && window.zslice.app.plates[2].parts === 1, null, { timeout: 60000 });
    await idle(page);
    await page.evaluate(() => {
      const z = window.zslice;
      window.__slices = 0;
      const old = z.work.start;
      z.work.start = function (...args) {
        window.__slices++;
        return old.apply(this, args);
      };
    });
    const go = async (i) => {
      await page.evaluate((p) => window.zslice.activatePlate(p, true), i);
    };
    // Many requests with no wait: the last one wins.
    for (const target of [0, 2, 1, 0]) {
      await page.evaluate(() => window.zslice.client.call("set", { name: "project.infill_density", value: String(0.1 + Math.random() * 0.3) }).then((r) => { if (r.error) throw new Error(r.error); }));
      await page.click("#plate-next", { force: true, timeout: 2000 }).catch(() => {});
      await page.keyboard.press("]");
      await page.keyboard.press("[");
      await page.click("#plate-all", { force: true, timeout: 2000 }).catch(() => {});
      await go(2);
      await go(1);
      await go(target);
      await page.waitForFunction((t) => window.zslice.app.shownPlate === t && window.zslice.tools.sel.plate === t, target, { timeout: 120000 });
    }
    await idle(page);
    const s = await state(page);
    check(s.plate === 0, `the focus ended on plate ${s.plate}`);
    const slices = await page.evaluate(() => window.__slices);
    check(slices > 0, "no slice ran during the test");
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `no stuck focus, ${slices} slices ran`;
  },

  async "drag the rotation ring while a slice runs: each frame follows the pointer"() {
    const { page, ctx, errors } = await newPage("test-big.stl", 1);
    const id = (await state(page)).ids[0];
    await page.keyboard.press("m");
    await clickPart(page, id);
    await page.waitForTimeout(200);
    // A pixel on the blue ring (handle 2).
    const ring = await page.evaluate(() => {
      const z = window.zslice;
      z.drawNow();
      const c = z.view;
      const w = document.getElementById("gl");
      const r = w.getBoundingClientRect();
      const k = window.devicePixelRatio || 1;
      const p = z.tools.part;
      if (!p) return null;
      const m = c.pixelOf(p.x, p.y, p.sizeZ / 2);
      for (let rad = 20; rad < 500; rad += 1) {
        for (let a = 0; a < 360; a += 3) {
          const px = m[0] + rad * Math.cos((a * Math.PI) / 180);
          const py = m[1] + rad * Math.sin((a * Math.PI) / 180);
          if (c.x.zs_view_gizmo_at(c.v, px, py, 3 * k) === 2) return { x: r.left + px / k, y: r.top + py / k, cx: r.left + m[0] / k, cy: r.top + m[1] / k };
        }
      }
      return null;
    });
    check(ring, "no pixel on the ring");
    // A slice runs first, and the press comes while it runs.
    await page.evaluate(() => { window.zslice.client.call("set", { name: "project.infill_density", value: "0.37" }); });
    await page.waitForFunction(() => window.zslice.app.slicing, null, { timeout: 20000, polling: 5 });
    await page.mouse.move(ring.x, ring.y);
    await page.mouse.down();
    const r0 = Math.hypot(ring.x - ring.cx, ring.y - ring.cy);
    const a0 = Math.atan2(ring.y - ring.cy, ring.x - ring.cx);
    let followed = 0;
    let during = 0;
    let last = null;
    const steps = 40;
    for (let i = 1; i <= steps; i++) {
      const a = a0 + (i / steps) * 1.5;
      await page.mouse.move(ring.cx + r0 * Math.cos(a), ring.cy + r0 * Math.sin(a));
      const f = await page.evaluate(() => {
        const z = window.zslice;
        const d = z.gizmo.drag;
        return { on: !!d, want: d?.want ?? null, slicing: z.app.slicing };
      });
      check(f.on, `step ${i}: the drag ended`);
      if (f.slicing) during++;
      if (last === null || f.want !== last) followed++;
      last = f.want;
    }
    await page.mouse.up();
    check(last !== 0, "the ring did not turn");
    check(followed >= 4, `the ring followed ${followed} steps of 15 degrees`);
    check(during > 0, "no move came during the slice");
    await idle(page);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `angle ${last} degrees, ${followed} changes, ${during} moves during a slice`;
  },

  async "undo and redo keep a valid selection, never a wrong part"() {
    const { page, ctx, errors } = await newPage("test-cube.stl", 3);
    const { ids } = await state(page);
    const [a, b, c] = ids;
    await page.keyboard.press("m");
    await page.evaluate((id) => {
      const t = window.zslice.tools;
      t.selectPart(t.factsOf(id));
    }, b);
    // Delete part a: part b gets a new index.
    await page.evaluate(async () => {
      await window.zslice.client.call("partAction", { index: 0, action: "remove" });
    });
    await page.waitForFunction((id) => window.zslice.tools.sel.indexOf(id) === 0, b);
    let s = await state(page);
    check(s.primary === b, "the delete of another part changed the selected part");
    // Select c, undo the delete, and c stays c.
    await page.evaluate((id) => {
      const t = window.zslice.tools;
      t.selectPart(t.factsOf(id));
    }, c);
    await page.evaluate(() => window.zslice.client.call("undo"));
    await page.waitForFunction((id) => window.zslice.tools.sel.indexOf(id) === 2, c);
    s = await state(page);
    check(s.primary === c, "undo changed the selected part");
    check(s.ids.includes(a), "undo did not bring the part back with its id");
    // Select a, redo its delete: no part stays selected.
    await page.evaluate((id) => {
      const t = window.zslice.tools;
      t.selectPart(t.factsOf(id));
    }, a);
    await page.evaluate(() => window.zslice.client.call("redo"));
    await page.waitForFunction((id) => window.zslice.tools.sel.indexOf(id) < 0, a);
    s = await state(page);
    check(s.selected.length === 0, `redo left ${s.selected} selected`);
    await idle(page);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "ids stay";
  },

  async "a selected line stays selected after a new slice"() {
    const { page, ctx, errors } = await newPage("test-cube.stl", 2);
    const line = await page.evaluate(async () => {
      const z = window.zslice;
      // A line far above the first layer: more skirt loops give it
      // another number, and its geometry stays.
      const b = z.tools.sel.box(z.tools.sel.idAt(0));
      const q = z.view.pixelOf((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, b.z1);
      if (!z.hitAt(q[0], q[1])) return { path: -1, key: "0" };
      const path = z.view.hit[0];
      z.select(path, 0, false);
      for (let i = 0; i < 100 && !(z.app.info && z.app.info.path === path); i++) await new Promise((r) => setTimeout(r, 20));
      return { path, key: String(z.tools.sel.line().key), info: z.app.info?.layer };
    });
    check(line.key !== "0", "the line has no key");
    // More skirt lines: the paths get other numbers, and the line stays.
    await page.evaluate(() => window.zslice.client.call("set", { name: "project.skirt_loops", value: "4" }));
    await page.waitForTimeout(200);
    await idle(page);
    await page.waitForFunction((k) => {
      const l = window.zslice.tools.sel.line();
      return l.path >= 0 && String(l.key) === k && window.zslice.app.info?.path === l.path;
    }, line.key, { timeout: 20000 });
    const after = await page.evaluate(() => window.zslice.tools.sel.line().path);
    check(after !== line.path, `the slice did not renumber the line (path ${after})`);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `path ${line.path} is path ${after} now`;
  },
};

let failed = 0;
try {
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM ?? "/usr/bin/chromium", headless: true, args: ["--enable-unsafe-swiftshader", "--use-angle=swiftshader", "--ignore-gpu-blocklist"] });
  for (const [name, fn] of Object.entries(tests)) {
    if (only && !name.includes(only)) continue;
    const t0 = Date.now();
    try {
      const note = await fn();
      console.log(`ok    ${name}: ${note} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
    } catch (e) {
      failed++;
      console.log(`FAIL  ${name}: ${e.message}`);
      for (const c of browser.contexts()) await c.close().catch(() => {});
    }
  }
} finally {
  await stopAll();
}
process.exit(failed ? 1 : 0);
