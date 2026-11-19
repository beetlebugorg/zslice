// cdp.mjs: a small driver of headless Chromium over the DevTools protocol,
// for the pictures of the docs (shots.mjs, sim_anim.mjs).
//
// - serve(): serves the web app (zig-out/web/app) and the test parts from
//   one folder of links, with web/app/serve.py, on a free port.
// - open(url): starts Chromium with no window and a new profile, and opens
//   the page. The page gets the keys, the mouse, and the screenshots.
//
// Chromium never opens a window: it runs with --headless=new, and with no
// DISPLAY and no WAYLAND_DISPLAY. Set DOCS_GPU=1 to draw with the GPU
// (--use-angle=gl-egl). Else it draws with SwiftShader, a slow renderer that
// works on any machine.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readdir, symlink, writeFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A free TCP port on 127.0.0.1.
function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
    s.on("error", reject);
  });
}

// Serves the built web app with the files of `extra` (name -> path) next
// to it. Returns { url, close }.
export async function serve(extra = {}) {
  const app = path.join(ROOT, "zig-out/web/app");
  const dir = await mkdtemp(path.join(tmpdir(), "zslice-docs-"));
  for (const f of await readdir(app)) await symlink(path.join(app, f), path.join(dir, f));
  for (const [name, file] of Object.entries(extra)) await symlink(path.resolve(file), path.join(dir, name));
  const port = await freePort();
  const py = spawn("python3", [path.join(ROOT, "web/app/serve.py"), dir, "--port", String(port)], { stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try {
      await fetch(`http://127.0.0.1:${port}/index.html`);
      break;
    } catch {
      await sleep(100);
    }
  }
  return {
    url: `http://127.0.0.1:${port}/`,
    close: async () => {
      py.kill();
      await rm(dir, { recursive: true, force: true });
    },
  };
}

// Opens `url` in a new headless Chromium with a window of w x h CSS pixels.
// Returns the page: send(method, params), eval(js), waitFor(js), shot(file),
// click(x, y), key(key), drag(points), close().
export async function open(url, { w = 1400, h = 900, scale = 1, log = false } = {}) {
  const prof = await mkdtemp(path.join(tmpdir(), "zslice-docs-prof-"));
  const port = await freePort();
  const gpu = process.env.DOCS_GPU ? ["--use-angle=gl-egl", "--ignore-gpu-blocklist"] : ["--enable-unsafe-swiftshader", "--use-angle=swiftshader"];
  const env = { ...process.env, WAYLAND_DISPLAY: "", DISPLAY: "" };
  const chrome = spawn("chromium", ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, ...gpu,
    `--window-size=${w},${h}`, "--hide-scrollbars", "--no-first-run", "about:blank"], { stdio: ["ignore", "ignore", "ignore"], env });
  let ws = null;
  for (let i = 0; i < 150 && !ws; i++) {
    await sleep(100);
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = list.find((t) => t.type === "page");
      if (page) ws = new WebSocket(page.webSocketDebuggerUrl);
    } catch {}
  }
  if (!ws) throw new Error("Chromium did not start");
  await new Promise((r) => ws.addEventListener("open", r));
  let id = 0;
  const pending = new Map();
  ws.addEventListener("message", (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m);
      pending.delete(m.id);
    }
    if (log && m.method === "Runtime.consoleAPICalled") console.log("console:", m.params.args.map((a) => a.value ?? a.description).join(" "));
    if (m.method === "Runtime.exceptionThrown") console.log("exception:", JSON.stringify(m.params.exceptionDetails).slice(0, 600));
  });
  const send = (method, params = {}) => new Promise((r) => {
    const i = ++id;
    pending.set(i, r);
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  const evalJs = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.result?.exceptionDetails) throw new Error(`${expr.slice(0, 80)}: ${r.result.exceptionDetails.exception?.description ?? r.result.exceptionDetails.text}`);
    return r.result?.result?.value;
  };
  await send("Runtime.enable");
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: scale, mobile: w < 700 });
  if (w < 700) await send("Emulation.setTouchEmulationEnabled", { enabled: true });
  await send("Page.navigate", { url });
  const page = {
    send,
    eval: evalJs,
    async waitFor(cond, ms = 90000) {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) {
        if (await evalJs(cond).catch(() => false)) return true;
        await sleep(150);
      }
      throw new Error(`timeout: ${cond}`);
    },
    async shot(file, clip) {
      const r = await send("Page.captureScreenshot", { format: "png", ...(clip ? { clip: { ...clip, scale: 1 } } : {}) });
      await writeFile(file, Buffer.from(r.result.data, "base64"));
    },
    async mouse(type, x, y, extra = {}) {
      await send("Input.dispatchMouseEvent", { type, x, y, button: "left", buttons: type === "mouseReleased" ? 0 : 1, clickCount: 1, ...extra });
    },
    async click(x, y, extra = {}) {
      await send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y, ...extra });
      await page.mouse("mousePressed", x, y, extra);
      await page.mouse("mouseReleased", x, y, extra);
    },
    async move(x, y, extra = {}) {
      await send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y, ...extra });
    },
    async key(key, extra = {}) {
      const text = key.length === 1 ? key : undefined;
      const code = key.length === 1 ? `Key${key.toUpperCase()}` : key;
      await send("Input.dispatchKeyEvent", { type: "keyDown", key, code, text, ...extra });
      await send("Input.dispatchKeyEvent", { type: "keyUp", key, code, ...extra });
    },
    async close() {
      ws.close();
      chrome.kill();
      await sleep(300);
      await rm(prof, { recursive: true, force: true }).catch(() => {});
    },
  };
  return page;
}

// Opens a model file of the served folder in the app, and waits for the
// slice. `name` is the name in the folder of serve().
export async function openModel(page, name) {
  await page.eval(`(async () => {
    const b = await (await fetch(${JSON.stringify(name)})).blob();
    const dt = new DataTransfer();
    dt.items.add(new File([b], ${JSON.stringify(name)}));
    const i = document.getElementById("file");
    i.files = dt.files;
    i.dispatchEvent(new Event("change"));
    return 1;
  })()`);
  await page.waitFor("window.zslice.app.state === 'done'");
}

// Waits for the next slice to end.
export async function sliced(page, ms = 90000) {
  await sleep(300);
  await page.waitFor("window.zslice.app.state === 'done' && document.getElementById('busy').hidden", ms);
  await sleep(400);
}

// The app with no first-start picker, ready for a model: waits for the
// app, and closes the printer picker of the first start.
export async function ready(page) {
  await page.waitFor("window.zslice && window.zslice.search && window.zslice.client");
  await sleep(500);
  await page.eval("document.querySelector('.picker-shade')?.remove(); 1");
}

export async function mkdirp(dir) {
  await mkdir(dir, { recursive: true });
}

export { writeFile };
