// turn.js: the rings of the Turn tool (R). With the Turn tool and a
// selected part, three rings go around the part: red turns it about X,
// green about Y, and blue about Z (a turn on the bed). A drag along a ring
// turns the part in steps of 15° (Shift: 5°); each step goes to the core
// at once, and the part slices again. The rings are an SVG over the view,
// made from the pixels of points around the part (zs_view_pixel_of), so
// they follow the camera.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const NS = "http://www.w3.org/2000/svg";
const AXES = [
  { axis: 0, color: "#e5484d", name: "X" },
  { axis: 1, color: "#30a46c", name: "Y" },
  { axis: 2, color: "#3e8ef7", name: "Z" },
];
const SAMPLES = 48;

export class TurnRings {
  // ctx: { host (the element of the view), pixelOf(point) -> device
  //        pixels or null, part() (the selected part or null), active()
  //        (the Turn tool is on), turn(axis, degrees) -> Promise }
  constructor(ctx) {
    this.ctx = ctx;
    this.svg = document.createElementNS(NS, "svg");
    this.svg.classList.add("turn-rings");
    this.rings = AXES.map((a) => {
      const g = document.createElementNS(NS, "g");
      const hit = document.createElementNS(NS, "polyline");
      hit.classList.add("turn-hit");
      const line = document.createElementNS(NS, "polyline");
      line.classList.add("turn-line");
      line.setAttribute("stroke", a.color);
      const title = document.createElementNS(NS, "title");
      title.textContent = `Drag to turn the part about ${a.name} (15° steps; Shift: 5°)`;
      g.append(hit, line, title);
      g.dataset.axis = String(a.axis);
      g.addEventListener("pointerdown", (e) => this.press(e, a.axis));
      this.svg.append(g);
      return { g, hit, line, pts: [], center: null };
    });
    this.label = document.createElement("div");
    this.label.className = "turn-label";
    this.label.hidden = true;
    ctx.host.append(this.svg, this.label);
    this.drag = null;
  }

  // The points of the ring of `axis` around the part, in mm.
  ringPoints(p, axis) {
    const c = [p.x, p.y, p.sizeZ / 2];
    const r = 0.62 * Math.max(p.sizeX, p.sizeY, p.sizeZ) + 4;
    const out = [];
    for (let i = 0; i <= SAMPLES; i++) {
      const t = (2 * Math.PI * i) / SAMPLES;
      const a = r * Math.cos(t);
      const b = r * Math.sin(t);
      if (axis === 0) out.push({ x: c[0], y: c[1] + a, z: c[2] + b });
      else if (axis === 1) out.push({ x: c[0] + a, y: c[1], z: c[2] + b });
      else out.push({ x: c[0] + a, y: c[1] + b, z: c[2] });
    }
    return out;
  }

  // After each frame: the rings at the pixels of the part now.
  place() {
    const p = this.ctx.part();
    const on = !!p && this.ctx.active();
    this.svg.style.display = on ? "" : "none";
    if (!on) {
      this.label.hidden = true;
      return;
    }
    const dpr = window.devicePixelRatio || 1;
    const center = this.ctx.pixelOf({ x: p.x, y: p.y, z: p.sizeZ / 2 });
    for (const a of AXES) {
      const ring = this.rings[a.axis];
      const pts = [];
      for (const q of this.ringPoints(p, a.axis)) {
        const px = this.ctx.pixelOf(q);
        if (px) pts.push([px[0] / dpr, px[1] / dpr]);
      }
      ring.pts = pts;
      ring.center = center ? [center[0] / dpr, center[1] / dpr] : null;
      const text = pts.map((q) => `${q[0].toFixed(1)},${q[1].toFixed(1)}`).join(" ");
      ring.hit.setAttribute("points", text);
      ring.line.setAttribute("points", text);
    }
  }

  // The sense of a ring on the screen: +1 if the angle about the center
  // grows with the angle of the ring (counterclockwise on the screen,
  // with y down), else -1.
  sense(ring) {
    const c = ring.center;
    if (!c || ring.pts.length < 3) return 1;
    let sum = 0;
    for (let i = 1; i < ring.pts.length; i++) {
      const a0 = Math.atan2(ring.pts[i - 1][1] - c[1], ring.pts[i - 1][0] - c[0]);
      const a1 = Math.atan2(ring.pts[i][1] - c[1], ring.pts[i][0] - c[0]);
      let d = a1 - a0;
      if (d > Math.PI) d -= 2 * Math.PI;
      if (d < -Math.PI) d += 2 * Math.PI;
      sum += d;
    }
    return sum >= 0 ? 1 : -1;
  }

  press(e, axis) {
    if (e.button !== 0) return;
    const ring = this.rings[axis];
    if (!ring.center) return;
    e.preventDefault();
    e.stopPropagation();
    const host = this.ctx.host.getBoundingClientRect();
    const at = (ev) => Math.atan2(ev.clientY - host.top - ring.center[1], ev.clientX - host.left - ring.center[0]);
    const sense = this.sense(ring);
    this.drag = { axis, start: at(e), sent: 0, busy: false, want: 0 };
    ring.g.classList.add("on");
    const target = e.currentTarget;
    target.setPointerCapture(e.pointerId);
    const move = (ev) => {
      const d = this.drag;
      if (!d) return;
      let delta = ((at(ev) - d.start) * 180) / Math.PI;
      while (delta > 180) delta -= 360;
      while (delta < -180) delta += 360;
      const step = ev.shiftKey ? 5 : 15;
      // The sense of the ring on the screen: the part turns with the drag.
      d.want = Math.round((sense * delta) / step) * step;
      this.showLabel(ev, d.want);
      this.send();
    };
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
      target.removeEventListener("pointercancel", up);
      ring.g.classList.remove("on");
      this.label.hidden = true;
      this.drag = null;
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
    target.addEventListener("pointercancel", up);
  }

  // One step at a time to the core: the turn since the last step.
  async send() {
    const d = this.drag;
    if (!d || d.busy || d.want === d.sent) return;
    d.busy = true;
    const step = d.want - d.sent;
    d.sent = d.want;
    await this.ctx.turn(d.axis, step);
    d.busy = false;
    if (this.drag === d) this.send();
  }

  showLabel(ev, deg) {
    const host = this.ctx.host.getBoundingClientRect();
    this.label.textContent = `${deg > 0 ? "+" : ""}${deg}° about ${AXES[this.drag.axis].name}`;
    this.label.hidden = false;
    this.label.style.left = `${ev.clientX - host.left + 16}px`;
    this.label.style.top = `${ev.clientY - host.top - 30}px`;
  }
}
