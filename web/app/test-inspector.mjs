// test-inspector.mjs: the tests of the docked Inspector in a real browser
// (docs/internals/one-view.md). The main test selects each kind of object
// at many camera positions and window sizes. It proves that no element of
// the selection UI intersects the canvas, and that the canvas and the
// camera do not change.
//
// Run, in a memory cap:
//   zig build web
//   PLAYWRIGHT=/path/to/node_modules/playwright-core \
//     node web/app/test-inspector.mjs zig-out/web/app [only]
//
// The test serves the build with serve.py on a free port. It stops the
// browser and the server by their handles.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [appDir, only] = process.argv.slice(2);
if (!appDir) {
  console.error("usage: node test-inspector.mjs <app folder> [only]");
  process.exit(2);
}
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT ?? "playwright-core");

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
for (let i = 0; i < 100; i++) {
  try {
    await fetch(`http://127.0.0.1:${port}/`);
    break;
  } catch {
    await new Promise((r) => setTimeout(r, 100));
  }
}

const cube = boxStl(30, 30, 12);
let browser = null;

const idle = (page) => page.waitForFunction(() => {
  const z = window.zslice;
  return z && z.app.state === "done" && !z.app.slicing && !z.app.draft;
}, null, { timeout: 120000, polling: 50 });

async function newPage(width, height, copies = 2, scale = 1) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: scale });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.route("**/test-cube.stl", (r) => r.fulfill({ body: cube, contentType: "model/stl" }));
  await page.goto(`http://127.0.0.1:${port}/?model=test-cube.stl&copies=${copies}`);
  await page.waitForFunction((n) => window.zslice?.app?.parts >= n, copies, { timeout: 120000 });
  await idle(page);
  return { page, ctx, errors };
}

const check = (ok, text) => {
  if (!ok) throw new Error(text);
};

// The canvas, the camera, and each element of the selection UI that
// draws. An element counts if it has a size and is not hidden.
const measure = (page) => page.evaluate(() => {
  const c = document.getElementById("gl").getBoundingClientRect();
  const box = [c.left, c.top, c.right, c.bottom];
  const ui = [...document.querySelectorAll("#panel, #panel *, .part-card, .part-card *, .line-card, .line-card *, .support-card, .support-card *, .paint-card, .paint-card *")];
  const over = [];
  let drawn = 0;
  for (const n of ui) {
    const r = n.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0 || getComputedStyle(n).visibility === "hidden") continue;
    drawn++;
    if (r.left < box[2] - 0.5 && r.right > box[0] + 0.5 && r.top < box[3] - 0.5 && r.bottom > box[1] + 0.5) over.push(n.className || n.tagName);
  }
  const inView = document.querySelectorAll("#preview .part-card, #preview .line-card, #preview .support-card, #preview .paint-card").length;
  return { box, camera: window.zslice.camera(), over: over.slice(0, 5), drawn, inView };
});

const same = (a, b, eps = 1e-3) => a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= eps);

function assertClear(m, base, what) {
  check(m.inView === 0, `${what}: a card is inside the view`);
  check(m.over.length === 0, `${what}: UI over the canvas: ${m.over.join(", ")}`);
  check(same(m.box, base.box, 0.01), `${what}: the canvas moved: ${base.box} to ${m.box}`);
  check(same(m.camera, base.camera), `${what}: the camera moved`);
}

// Each kind of selection: makes it, and waits for its page.
const KINDS = {
  part: async (page) => {
    await page.evaluate(() => {
      const z = window.zslice;
      if (z.tools.tool !== "move") z.tools.set("move");
      z.tools.selectPart(z.tools.factsOf(z.tools.sel.idAt(0)));
    });
    await page.waitForSelector("#insp-slot .part-card", { state: "attached" });
  },
  many: async (page) => {
    await page.evaluate(() => {
      const z = window.zslice;
      if (z.tools.tool !== "move") z.tools.set("move");
      z.tools.selectPart(z.tools.factsOf(z.tools.sel.idAt(0)));
      z.tools.togglePart(z.tools.factsOf(z.tools.sel.idAt(1)));
    });
    await page.waitForFunction(() => document.querySelector("#insp-slot .part-card .lc-title")?.textContent === "2 parts");
  },
  line: async (page) => {
    await page.evaluate(() => {
      const z = window.zslice;
      z.tools.set("select");
      z.select(0, 0, true);
    });
    await page.waitForSelector("#insp-slot .line-card", { state: "attached" });
  },
  range: async (page) => {
    await page.evaluate(() => {
      const z = window.zslice;
      z.tools.set("select");
      z.rangeCard.show(2, 5);
    });
    await page.waitForSelector("#insp-slot .range-card", { state: "attached" });
  },
  label: async (page) => {
    await page.evaluate(async () => {
      const z = window.zslice;
      const r = await z.client.call("labelsGet", { index: 0 });
      await z.labelTool.open(0, r.labels[0].id);
    });
    await page.waitForSelector("#insp-slot .label-card", { state: "attached" });
  },
  paint: async (page) => {
    await page.evaluate(() => window.zslice.paintTool.open());
    await page.waitForSelector("#insp-slot .paint-card", { state: "attached" });
  },
  support: async (page) => {
    await page.evaluate(() => window.zslice.tools.set("support"));
    await page.waitForSelector("#insp-slot .support-card", { state: "attached" });
  },
};

// Puts one label on the first part, from the first camera.
async function addLabel(page) {
  await page.evaluate(async () => {
    const z = window.zslice;
    const b = z.tools.sel.box(z.tools.sel.idAt(0));
    const q = z.view.pixelOf((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, b.z1);
    await z.labelTool.open(0, -1);
    await z.labelTool.addAt(q[0], q[1]);
    await z.labelTool.flush();
    z.labelTool.close();
  });
  await page.waitForFunction(async () => (await window.zslice.client.call("labelsGet", { index: 0 })).labels.length > 0);
  await idle(page);
}

const clear = (page) => page.evaluate(() => {
  const z = window.zslice;
  z.paintTool.close();
  z.labelTool.close();
  z.rangeCard.close();
  z.tools.set("select");
  z.select(-1, -1, false);
  z.tools.selectPart(null);
});

const cameras = (c) => {
  const turn = (a, b) => {
    const q = [...c];
    q[0] += a;
    q[1] += b;
    return q;
  };
  return [c, turn(0.7, 0.2), turn(-0.9, 0.35), turn(1.8, -0.25), turn(3.1, 0.5)];
};

const SIZES = [[1920, 1080], [1280, 800], [1024, 700], [800, 600], [760, 900], [390, 844], [844, 390]];

const tests = {
  "a line picked while a slice starts stays selected, and one chip click colors it": async () => {
    const { page, ctx, errors } = await newPage(1440, 900, 2, 1);
    await page.evaluate(async () => {
      const z = window.zslice;
      await z.browser.ctx.addFilament();
      const b = z.tools.sel.box(z.tools.sel.idAt(1));
      const L = Math.floor(z.layers.count / 2);
      z.view.pickLayer(L, b.x0 + 0.2, (b.y0 + b.y1) / 2);
      z.app.pickPoint = [b.x0 + 0.2, (b.y0 + b.y1) / 2];
      z.select(z.view.hit[0], 0, true);
    });
    await page.waitForTimeout(500);
    await idle(page);
    await page.waitForTimeout(200);
    check(await page.evaluate(() => window.zslice.app.sel >= 0), "the slice dropped the line");
    const chip = page.locator(".lc-filament:visible .fil-chip:not(.fil-add)").nth(1);
    await chip.waitFor({ timeout: 5000 });
    await chip.click();
    await page.waitForTimeout(300);
    await idle(page);
    await page.waitForTimeout(150);
    const f = await page.evaluate(async () => {
      const z = window.zslice;
      return z.app.sel < 0 ? -2 : (await z.client.call("inspect", { path: z.app.sel, seg: 0 }))?.info?.filament ?? -1;
    });
    check(f === 2, `the line has filament ${f} after one click`);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "kept, and colored on the first click";
  },
  "one click on a line's filament chip colors its layer": async () => {
    const { page, ctx, errors } = await newPage(1440, 900, 1, 1);
    await page.evaluate(() => window.zslice.browser.ctx.addFilament());
    await page.waitForTimeout(500);
    await idle(page);
    await page.locator("#gl").focus();
    await page.keyboard.press("v");
    const out = [];
    const fil = (x, y, layer) => page.evaluate(async ([px, py, l]) => {
      const z = window.zslice;
      if (!z.view.pickLayer(l, px, py)) return -1;
      return (await z.client.call("inspect", { path: z.view.hit[0], seg: 0 }))?.info?.filament ?? -1;
    }, [x, y, layer]);
    for (let round = 0; round < 8; round++) {
      const at = await page.evaluate((r) => {
        const z = window.zslice;
        const b = z.tools.sel.box(z.tools.sel.idAt(0));
        const layer = 8 + r * 5;
        const q = z.view.pixelOf(b.x0, (b.y0 + b.y1) / 2, z.app.layers.z[layer] - 0.1);
        const c = document.getElementById("gl").getBoundingClientRect();
        const k = window.devicePixelRatio || 1;
        return { x: c.left + q[0] / k, y: c.top + q[1] / k, bx: b.x0 + 0.2, by: (b.y0 + b.y1) / 2 };
      }, round);
      await page.mouse.click(at.x, at.y);
      await page.waitForFunction(() => window.zslice.app.sel >= 0 && document.querySelector(".lc-filament .fil-chip"), null, { timeout: 5000 });
      if (round % 2) await page.waitForTimeout(400);
      const layer = await page.evaluate(() => window.zslice.view.pathLayer(window.zslice.app.sel));
      const chip = page.locator(".lc-filament:visible .fil-chip:not(.fil-add)").nth(1);
      await chip.click();
      await page.waitForTimeout(250);
      await idle(page);
      out.push({ layer, got: await fil(at.bx, at.by, layer), on: await page.evaluate(() => document.querySelector(".lc-filament .fil-chip.on")?.textContent ?? null) });
      await page.keyboard.press("Escape");
      await page.waitForTimeout(120);
    }
    const bad = out.filter((o) => o.got !== 2);
    check(bad.length === 0, `first click failed in ${bad.length} of ${out.length}: ${JSON.stringify(out).slice(0, 500)}`);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `${out.length} lines took on the first click`;
  },
  "one click on a filament chip colors a selected layer": async () => {
    const { page, ctx, errors } = await newPage(1440, 900, 1, 1);
    await page.evaluate(() => window.zslice.browser.ctx.addFilament());
    await page.waitForTimeout(500);
    await idle(page);
    const out = [];
    for (let round = 0; round < 6; round++) {
      const L = await page.evaluate((r) => {
        const z = window.zslice;
        const b = z.tools.sel.box(z.tools.sel.idAt(0));
        const layer = 5 + r * 4;
        z.view.pickLayer(layer, b.x0 + 0.2, (b.y0 + b.y1) / 2);
        z.app.pickPoint = [b.x0 + 0.2, (b.y0 + b.y1) / 2];
        z.select(z.view.hit[0], 0, true);
        return layer;
      }, round);
      await page.waitForFunction(() => window.zslice.app.sel >= 0, null, { timeout: 5000 });
      await page.locator("#gl").focus();
      await page.keyboard.press("Shift+K");
      await page.waitForTimeout(80);
      const st = await page.evaluate(() => {
        const z = window.zslice;
        const rows = [...document.querySelectorAll(".range-body")];
        return { sel: z.app.sel, light: z.app.rangeLight ? { path: z.app.rangeLight.path, lo: z.app.rangeLight.lo, hi: z.app.rangeLight.hi } : null, open: z.rangeCard.open, body: z.rangeCard.body, rows: rows.map((r) => ({ hidden: r.hidden, h: r.offsetHeight, card: r.closest(".range-card")?.hidden ?? null, disp: getComputedStyle(r).display })), top: document.querySelector("#inspector-slot > :not([hidden])")?.className ?? null };
      });
      if (!st.rows.some((r) => r.h > 0)) throw new Error(`round ${round}: ${JSON.stringify(st)}`);
      const chip = page.locator(".range-body:visible .fil-chip:not(.fil-add)").nth(1);
      await chip.waitFor({ timeout: 5000 });
      await chip.click();
      await page.waitForTimeout(250);
      await idle(page);
      const got = await page.evaluate(async (layer) => {
        const z = window.zslice;
        const b = z.tools.sel.box(z.tools.sel.idAt(0));
        if (!z.view.pickLayer(layer, b.x0 + 0.2, (b.y0 + b.y1) / 2)) return -1;
        return (await z.client.call("inspect", { path: z.view.hit[0], seg: 0 }))?.info?.filament ?? -1;
      }, L);
      out.push(got);
      await page.keyboard.press("Escape");
      await page.waitForTimeout(100);
    }
    check(out.every((f) => f === 2), `the filament after one click, by round: ${out}`);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `${out.length} rounds took on the first click`;
  },
  "the view fills the space above the bottom bar": async () => {
    const notes = [];
    for (const [w, h, k] of [[1000, 640, 2], [1200, 760, 2], [1440, 900, 2], [1728, 1000, 2], [1000, 900, 1], [860, 700, 2]]) {
      const { page, ctx, errors } = await newPage(w, h, 2, k);
      const measure = (what) => page.evaluate((name) => {
        const r = (id) => document.getElementById(id).getBoundingClientRect();
        const gl = r("gl"), dock = r("dock"), pv = r("preview");
        const c = document.getElementById("gl");
        return { name, glB: Math.round(gl.bottom), glH: Math.round(gl.height), dockT: Math.round(dock.top), dockH: Math.round(dock.height), glBar: Math.round(parseFloat(getComputedStyle(document.getElementById("preview")).getPropertyValue("--dock-h")) || 0), pvB: Math.round(pv.bottom), bufH: c.height, want: Math.round(gl.height * devicePixelRatio), var: getComputedStyle(document.getElementById("preview")).getPropertyValue("--dock-h") };
      }, what);
      const report = [await measure("start")];
      await page.evaluate(() => {
        const z = window.zslice;
        const b = z.tools.sel.box(z.tools.sel.idAt(0));
        const L = Math.floor(z.layers.count / 2);
        if (z.view.pickLayer(L, b.x0 + 0.2, (b.y0 + b.y1) / 2)) z.select(z.view.hit[0], 0, true);
      });
      await page.waitForTimeout(300);
      report.push(await measure("line"));
      await page.setViewportSize({ width: w - 60, height: h - 40 });
      await page.waitForFunction(() => {
        const c = document.getElementById("gl");
        return c.height === Math.round(c.getBoundingClientRect().height * devicePixelRatio);
      }, null, { timeout: 5000, polling: 100 }).catch(async () => {
        const st = await page.evaluate(() => {
          const c = document.getElementById("gl");
          const r = c.getBoundingClientRect();
          return { buf: c.height, css: r.height, k: devicePixelRatio, want: r.height * devicePixelRatio, attrW: c.width, cssW: r.width, dock: document.getElementById("dock").offsetHeight, v: getComputedStyle(document.getElementById("preview")).getPropertyValue("--dock-h") };
        });
        throw new Error(`${w}x${h}@${k}: ${JSON.stringify(st)}`);
      });
      report.push(await measure("resized"));
      for (const m of report) {
        check(Math.abs(m.glB - (m.pvB - m.glBar)) <= 1, `${w}x${h}@${k} ${m.name}: the view ends at ${m.glB}, and the bar starts at ${m.pvB - m.glBar}`);
        check(m.bufH === m.want, `${w}x${h}@${k} ${m.name}: buffer ${m.bufH}, view ${m.want}`);
        notes.push(`${w}x${h}@${k} ${m.name}: gl bottom ${m.glB} dock top ${m.dockT} dock h ${m.dockH} preview bottom ${m.pvB} buf ${m.bufH}/${m.want} var ${m.var}`);
      }
      check(errors.length === 0, errors.join("; "));
      await ctx.close();
    }
    return `${notes.length} states`;
  },
  async "no selection UI intersects the canvas, at each size and camera"() {
    let checks = 0;
    for (const [w, h] of SIZES) {
      const { page, ctx, errors } = await newPage(w, h);
      await addLabel(page);
      // The column is open on a wide window. In a narrow window, the test
      // runs with the sheet closed, then open.
      const states = w <= 760 ? [false, true] : [true];
      for (const open of states) {
        if (w <= 760 && open) await page.click("#panel-toggle");
        await page.waitForTimeout(60);
        const start = await page.evaluate(() => window.zslice.camera());
        for (const cam of cameras(start)) {
          await page.evaluate((q) => window.zslice.setCamera(q), cam);
          await page.waitForTimeout(40);
          const base = await measure(page);
          for (const [kind, make] of Object.entries(KINDS)) {
            await make(page);
            await page.waitForTimeout(30);
            assertClear(await measure(page), base, `${w}x${h} ${open ? "open" : "closed"} ${kind}`);
            await clear(page);
            await page.waitForTimeout(10);
            assertClear(await measure(page), base, `${w}x${h} after ${kind}`);
            checks++;
          }
        }
      }
      check(errors.length === 0, errors.join("; "));
      await ctx.close();
    }
    return `${checks} selections`;
  },

  async "a selection does not open the sheet on a phone"() {
    const { page, ctx, errors } = await newPage(390, 844);
    await addLabel(page);
    check(await page.evaluate(() => document.querySelector(".window").classList.contains("panel-hidden")), "the sheet starts open");
    for (const make of Object.values(KINDS)) {
      await make(page);
      await page.waitForTimeout(30);
      check(await page.evaluate(() => document.querySelector(".window").classList.contains("panel-hidden")), "a selection opened the sheet");
      await clear(page);
    }
    await KINDS.part(page);
    await page.waitForFunction(() => document.getElementById("panel-toggle").classList.contains("has-selection"));
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "the sheet stays closed, and the header shows a mark";
  },

  async "a drag of the width keeps the camera and does not slice"() {
    const { page, ctx, errors } = await newPage(1280, 800);
    const before = await page.evaluate(() => {
      const z = window.zslice;
      window.__slices = 0;
      const old = z.work.start;
      z.work.start = function (...a) {
        window.__slices++;
        return old.apply(this, a);
      };
      const b = z.tools.sel.box(z.tools.sel.idAt(0));
      window.__mid = [(b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, (b.z0 + b.z1) / 2];
      const q = z.view.pixelOf(...window.__mid);
      const c = document.getElementById("gl");
      return { cam: z.camera(), frames: z.frameCount, at: [q[0] / c.width, q[1] / c.height] };
    });
    const b = await page.locator("#splitter").boundingBox();
    await page.mouse.move(b.x + 2, b.y + 200);
    await page.mouse.down();
    for (let i = 1; i <= 30; i++) await page.mouse.move(b.x + 2 - i * 6, b.y + 200);
    await page.mouse.up();
    await page.waitForTimeout(150);
    const after = await page.evaluate((first) => {
      const z = window.zslice;
      const t = [];
      for (let i = Math.max(first, z.frameCount - z.frameTimes.length); i < z.frameCount; i++) t.push(z.frameTimes[i % z.frameTimes.length]);
      t.sort((x, y) => x - y);
      const q = z.view.pixelOf(...window.__mid);
      const c = document.getElementById("gl");
      return { cam: z.camera(), at: [q[0] / c.width, q[1] / c.height], frames: t.length, slices: window.__slices, width: document.getElementById("panel").offsetWidth, p95: t[Math.floor(t.length * 0.95)] ?? 0 };
    }, before.frames);
    check(same(after.cam, before.cam), "the camera moved");
    check(Math.abs(after.at[0] - before.at[0]) < 0.02 && Math.abs(after.at[1] - before.at[1]) < 0.02, `the model moved in the view: ${before.at} to ${after.at}`);
    check(after.frames > 0, "no frame drew during the drag");
    check(after.slices === 0, `${after.slices} slices ran`);
    check(after.width > 500, `the column is ${after.width} px wide`);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return `width ${after.width} px, no slice, ${after.frames} frames, draw call p95 ${after.p95.toFixed(1)} ms, model at ${after.at.map((v) => v.toFixed(3))} of the view`;
  },

  async "an edit keeps the selection and the focus across a slice"() {
    const { page, ctx, errors } = await newPage(1280, 800);
    await KINDS.part(page);
    const id = await page.evaluate(() => window.zslice.tools.sel.primary);
    const field = page.locator("#insp-slot .pc-pose-n").first();
    await field.click();
    await page.keyboard.press("Control+A");
    await page.keyboard.type("120");
    await page.keyboard.press("Enter");
    await page.waitForTimeout(100);
    await idle(page);
    const s = await page.evaluate(() => ({ id: window.zslice.tools.sel.primary, focus: document.activeElement?.className }));
    check(s.id === id, "the edit lost the selection");
    check(String(s.focus).includes("pc-pose-n"), `the slice took the focus: ${s.focus}`);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "the field keeps the focus";
  },

  async "the scale shows no sign, and the mirror has a clear mark"() {
    const { page, ctx, errors } = await newPage(1280, 800);
    await KINDS.part(page);
    await page.click('#insp-slot .pc-action:text-is("Mirror X")');
    await page.waitForSelector("#insp-slot .pc-mirrored:not([hidden])");
    await idle(page);
    const read = () => page.evaluate(async () => {
      const i = document.querySelector("#insp-slot .pc-scale-n");
      const z = window.zslice;
      const part = (await z.client.call("partGet", { index: z.tools.part.index })).part;
      return { value: i.value, fits: i.scrollWidth <= i.clientWidth, mark: !document.querySelector("#insp-slot .pc-mirrored").hidden, scale: part.scale };
    });
    const a = await read();
    check(a.value === "100" && a.mark && a.fits && a.scale[0] < 0, `mirrored: ${JSON.stringify(a)}`);
    const input = page.locator("#insp-slot .pc-scale-n");
    await input.fill("150");
    await input.press("Enter");
    await page.waitForFunction(() => document.activeElement && Math.abs(window.zslice.tools.part?.sizeX - 45) < 0.5, null, { timeout: 20000 });
    await idle(page);
    const b = await read();
    check(b.scale[0] < 0 && Math.abs(Math.abs(b.scale[0]) - 1.5) < 1e-6 && b.mark, `a new scale lost the mirror: ${JSON.stringify(b)}`);
    await page.click('#insp-slot .pc-action:text-is("Mirror X")');
    await page.waitForSelector("#insp-slot .pc-mirrored", { state: "hidden" });
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "100 with the mark; 150 stays mirrored; a second mirror clears it";
  },

  async "the dock does not overlap itself with the column open"() {
    for (const w of [1920, 1440, 1280, 1100, 900]) {
      const { page, ctx, errors } = await newPage(w, 800);
      const hit = await page.evaluate(() => {
        const box = (n) => n.getBoundingClientRect();
        const list = ["#plate-bar", "#hist-tools", "#scrub", "#summary"].map((s) => document.querySelector(s)).filter((n) => n && !n.hidden);
        for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) {
          const a = box(list[i]);
          const b = box(list[j]);
          if (a.left < b.right - 1 && a.right > b.left + 1 && a.top < b.bottom - 1 && a.bottom > b.top + 1) return `${list[i].id} and ${list[j].id}`;
        }
        const s = document.getElementById("scrub-label");
        const t = document.getElementById("sum-time");
        const p = box(s);
        const q = box(t);
        return p.left < q.right && p.right > q.left && p.top < q.bottom && p.bottom > q.top ? "the layer text and the time" : null;
      });
      check(!hit, `${w} px: ${hit}`);
      check(errors.length === 0, errors.join("; "));
      await ctx.close();
    }
    return "5 widths";
  },

  async "body regions do not show as repeated settings of the part"() {
    const { page, ctx, errors } = await newPage(1280, 800, 1);
    const r = await page.evaluate(async () => {
      const z = window.zslice;
      const b = z.tools.sel.box(z.tools.sel.idAt(0));
      for (const L of [10, 30, 50]) {
        z.view.pickLayer(L, b.x0 + 0.2, (b.y0 + b.y1) / 2);
        const beads = z.view.connectedBeads(z.view.hit[0], L, L + 3);
        const q = await z.client.call("regionSet", { beads, region: 0, name: "project.infill_density", value: String(0.2 + L / 200) });
        if (q.error) return { error: q.error };
        await new Promise((res) => setTimeout(res, 200));
        for (let i = 0; i < 400 && (z.app.state !== "done" || z.app.slicing || z.app.draft); i++) await new Promise((res) => setTimeout(res, 25));
      }
      return z.client.call("partSettings", { index: 0 });
    });
    check(!r.error, r.error);
    check(r.list.length === 0, `the part lists ${JSON.stringify(r.list)}`);
    check(r.volumes.length === 3 && r.volumes.every((v) => v.list.length === 1 && v.list[0][0] === "project.infill_density"), JSON.stringify(r.volumes));
    await KINDS.part(page);
    await page.waitForFunction(() => document.querySelectorAll("#insp-slot .pc-volume-row").length === 3);
    const text = await page.evaluate(() => document.querySelector("#insp-slot .part-card").textContent);
    check(!text.includes("Wall count"), "the page shows Wall count");
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "3 regions, each with its one value, and no Wall count row";
  },

  async "each action of the old cards is in the Inspector"() {
    const { page, ctx, errors } = await newPage(1280, 800);
    await KINDS.part(page);
    const text = await page.evaluate(() => document.querySelector("#insp-slot .part-card").textContent);
    for (const a of ["Duplicate", "Split to parts", "Cut…", "Best orientation", "Less support", "Mirror X", "Mirror Y", "Reset", "To a new plate", "Remove", "Make", "Scale", "Filament", "+ Add a setting for this part"]) check(text.includes(a), `the part page has no ${a}`);
    await clear(page);
    await KINDS.line(page);
    const line = await page.evaluate(() => document.querySelector("#insp-slot .line-card").textContent);
    for (const a of ["Fade the others", "All settings…", "Don't print", "plastic", "Filament"]) check(line.includes(a), `the line page has no ${a}`);
    await clear(page);
    await KINDS.many(page);
    const many = await page.evaluate(() => document.querySelector("#insp-slot .part-card").textContent);
    for (const a of ["Duplicate", "Arrange the plate", "To a new plate", "Remove"]) check(many.includes(a), `the page of many parts has no ${a}`);
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "part, line, and many parts";
  },

  async "large text wraps and does not cut a label or leave the column"() {
    const { page, ctx, errors } = await newPage(1280, 800);
    await page.addStyleTag({ content: "html { font-size: 150%; } body { font-size: 150%; }" });
    for (const k of ["part", "line", "range"]) {
      await KINDS[k](page);
      await page.waitForTimeout(60);
      const bad = await page.evaluate(() => {
        const p = document.getElementById("page-inspect");
        const r = p.getBoundingClientRect();
        const out = [];
        for (const n of p.querySelectorAll("button, label, .lc-name, .lc-title, summary, span")) {
          const b = n.getBoundingClientRect();
          if (b.width <= 0) continue;
          const cs = getComputedStyle(n);
          if (cs.textOverflow === "ellipsis" && n.scrollWidth > n.clientWidth) out.push(`cut: ${n.textContent}`);
          if (b.right > r.right + 1) out.push(`out: ${n.textContent.slice(0, 30)}`);
        }
        return out.slice(0, 4);
      });
      check(bad.length === 0, `${k}: ${bad.join("; ")}`);
      await clear(page);
    }
    check(errors.length === 0, errors.join("; "));
    await ctx.close();
    return "part, line, and range";
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
  if (browser) await browser.close().catch(() => {});
  server.kill();
}
process.exit(failed ? 1 : 0);
