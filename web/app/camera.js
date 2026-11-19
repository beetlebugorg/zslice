// camera.js: the live picture of a printer camera, for the Printers page
// and the print card.
//
// The picture goes from the printer straight to this page, in an <img>:
// - An MJPEG stream (multipart/x-mixed-replace) plays in the <img> by
//   itself. printdeck takes w= and fps= in the query, so a small tile asks
//   for a small picture at a low rate.
// - A printer with only snapshots (a WebRTC camera of Moonraker): the
//   <img> loads the snapshot again every few seconds.
// An <img> needs no CORS. The camera plays only while it is on the screen
// and the page shows (an IntersectionObserver and visibilitychange): an
// <img> with no src closes the stream. The 3D view keeps its frames.
//
// The addresses come from the printer (link.js camera, zs_printer_camera).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";

// The seconds between two snapshots: a tile, and the large view.
const SNAP_TILE_S = 5;
const SNAP_LARGE_S = 1;
// No first picture in this time: the camera is out of reach.
const FIRST_MS = 12000;
// The wait before a camera with an error tries again.
const RETRY_MS = 20000;

const live = new Set();
let observer = null;

function observe(cam) {
  if (!observer && "IntersectionObserver" in window) {
    observer = new IntersectionObserver((list) => {
      for (const e of list) e.target._cam?.seen(e.isIntersecting);
    });
    document.addEventListener("visibilitychange", () => {
      for (const c of live) c.update();
    });
  }
  live.add(cam);
  if (observer) observer.observe(cam.el);
  else cam.seen(true);
}

// The address with the query parameters `params` added.
function withParams(url, params) {
  try {
    const u = new URL(url, location.href);
    for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
    return u.href;
  } catch {
    return url;
  }
}

// The reason in words that an http camera does not play on an https
// page, or "".
function mixedReason(url) {
  try {
    const u = new URL(url, location.href);
    if (location.protocol === "https:" && u.protocol === "http:" && u.origin !== location.origin)
      return "This page is https, and the camera is http: the browser blocks it. Open zslice from the printer, or give the printer an https address.";
  } catch {
    // A bad address: the error of the <img>.
  }
  return "";
}

export class CameraView {
  // source: { stream, snapshot, flipH, flipV, rotation } with absolute
  // addresses, or null for no camera. opts: { large, printdeck, label,
  // onclick }.
  constructor(source, opts = {}) {
    this.source = source;
    this.opts = opts;
    this.el = el("div", `cam${opts.large ? " cam-large" : ""}`);
    this.el._cam = this;
    this.img = document.createElement("img");
    this.img.alt = opts.label ? `The camera of ${opts.label}` : "The camera of the printer";
    this.img.decoding = "async";
    this.msg = el("div", "cam-msg");
    this.el.append(this.img, this.msg);
    if (opts.onclick) {
      this.el.classList.add("cam-click");
      this.el.tabIndex = 0;
      this.el.setAttribute("role", "button");
      this.el.setAttribute("aria-label", `Show the camera of ${opts.label ?? "the printer"} large`);
      this.el.onclick = opts.onclick;
      this.el.onkeydown = (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          opts.onclick();
        }
      };
    }
    this.visible = false;
    this.enabled = true;
    this.playing = false;
    this.error = "";
    this.timer = 0;
    this.retryAt = 0;
    this.img.onload = () => this.loaded();
    this.img.onerror = () => this.failed();
    this.applyTurn();
    if (!source || (!source.stream && !source.snapshot)) {
      this.show("No camera");
      this.el.classList.add("cam-none");
      return;
    }
    const mixed = mixedReason(source.stream || source.snapshot);
    if (mixed) {
      this.error = mixed;
      this.show(mixed);
      this.el.classList.add("cam-error");
      return;
    }
    this.show("Connecting…");
    observe(this);
  }

  // The turn of the picture (rotation, flipH, flipV of the printer).
  applyTurn() {
    const s = this.source;
    if (!s) return;
    const t = [];
    if (s.rotation) t.push(`rotate(${s.rotation}deg)`);
    if (s.flipH) t.push("scaleX(-1)");
    if (s.flipV) t.push("scaleY(-1)");
    this.img.style.transform = t.join(" ");
  }

  show(text) {
    this.msg.textContent = text;
    this.msg.hidden = !text;
  }

  seen(on) {
    this.visible = on;
    this.update();
  }

  // Plays while it is on the screen, the page shows, and no owner turned
  // it off.
  update() {
    const want = this.enabled && this.visible && !document.hidden && this.el.isConnected;
    if (want && !this.playing && !(this.error && performance.now() < this.retryAt)) this.play();
    else if (!want && this.playing) this.pause();
  }

  setEnabled(on) {
    this.enabled = on;
    this.update();
  }

  play() {
    const s = this.source;
    this.playing = true;
    this.error = "";
    this.el.classList.remove("cam-error");
    clearTimeout(this.first);
    this.first = setTimeout(() => {
      if (!this.img.naturalWidth) this.failed();
    }, FIRST_MS);
    if (s.stream) {
      // printdeck: a small picture at a low rate for a tile (webcam.go).
      const p = this.opts.printdeck ? (this.opts.large ? { fps: "10" } : { w: "480", fps: "4" }) : {};
      this.img.src = withParams(s.stream, p);
    } else {
      this.snap();
    }
  }

  snap() {
    clearTimeout(this.timer);
    if (!this.playing) return;
    this.img.src = withParams(this.source.snapshot, { _: String(Date.now()) });
    this.timer = setTimeout(() => this.snap(), (this.opts.large ? SNAP_LARGE_S : SNAP_TILE_S) * 1000);
  }

  // Stops the stream: an <img> with no src closes its connection.
  pause() {
    this.playing = false;
    clearTimeout(this.timer);
    clearTimeout(this.first);
    this.img.onerror = null;
    this.img.removeAttribute("src");
    this.img.src = "data:,";
    this.img.onerror = () => this.failed();
  }

  loaded() {
    if (!this.playing) return;
    clearTimeout(this.first);
    this.el.classList.add("cam-live");
    this.show("");
  }

  async failed() {
    if (!this.playing) return;
    this.pause();
    this.el.classList.remove("cam-live");
    this.el.classList.add("cam-error");
    this.retryAt = performance.now() + RETRY_MS;
    this.error = "The camera gave no picture.";
    this.show(this.error);
    // Why: a request with no CORS answers when the printer is there (an
    // opaque reply), and fails when it is out of reach.
    const url = this.source.snapshot || this.source.stream;
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 5000);
    try {
      await fetch(url, { mode: "no-cors", cache: "no-store", signal: ctrl.signal });
      this.error = "The camera gave no picture. It can be off, or have no picture now.";
    } catch {
      this.error = "The camera did not answer. The printer can be off, or out of reach of this computer.";
    } finally {
      clearTimeout(t);
      // A stream goes on after the headers: close it.
      ctrl.abort();
    }
    this.show(this.error);
    setTimeout(() => this.update(), RETRY_MS + 100);
  }

  // Stops it for good.
  close() {
    this.pause();
    live.delete(this);
    if (observer) observer.unobserve(this.el);
  }
}

// Stops all cameras under `root` (a page that goes away).
export function closeCameras(root) {
  for (const c of [...live]) if (root.contains(c.el)) c.close();
}
