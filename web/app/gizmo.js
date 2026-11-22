// turn.js: the rings of the Turn tool (R). With the Turn tool and a
// selected part, three rings go around the part: red turns it about X,
// green about Y, and blue about Z (a turn on the bed). A drag along a ring
// turns the part in steps of 15° (Shift: 5°); each step goes to the core
// at once, and the part slices once, at the end of the drag. The beads of
// the part turn in the view with the drag (a preview of the core view).
//
// The core view draws the rings, finds the ring under the pointer, and
// gives the angle of a drag (zs_view_set_rings, zs_view_ring_at,
// zs_view_ring_press, zs_view_ring_drag, zs_view_ring_release), so the GTK
// app and the macOS app have the same rings. This file has the events, the
// cursor, and the label of the angle.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const NAMES = ["X", "Y", "Z"];
// The distance from a ring that still hits it, CSS pixels.
const TOL = 8;

export class TurnRings {
  // ctx: { host (the element of the view), view (view.js: x, v), part()
  //        (the selected part or null), active() (the Turn tool is on),
  //        turn(axis, degrees) -> Promise, done() (the end of a drag),
  //        frame() (request a frame) }
  constructor(ctx) {
    this.ctx = ctx;
    this.label = document.createElement("div");
    this.label.className = "turn-label";
    this.label.hidden = true;
    ctx.host.append(this.label);
    this.drag = null;
    this.on = false;
    // Capture: a press on a ring is a turn, and not an orbit of the view.
    ctx.host.addEventListener("pointerdown", (e) => this.press(e), true);
    ctx.host.addEventListener("pointermove", (e) => this.hover(e));
  }

  dpr() {
    return window.devicePixelRatio || 1;
  }

  // The pixel of a pointer event in the view, device pixels.
  at(e) {
    const r = this.ctx.host.getBoundingClientRect();
    return [(e.clientX - r.left) * this.dpr(), (e.clientY - r.top) * this.dpr()];
  }

  // Before each frame: the rings around the part now, or none.
  place() {
    const p = this.ctx.part();
    const on = !!p && this.ctx.active();
    const x = this.ctx.view.x;
    const v = this.ctx.view.v;
    if (on) {
      x.zs_view_set_rings(v, p.x, p.y, p.sizeZ / 2, 0.62 * Math.max(p.sizeX, p.sizeY, p.sizeZ) + 4);
    } else if (this.on) {
      x.zs_view_set_rings(v, 0, 0, 0, 0);
    }
    this.on = on;
    if (!on) this.label.hidden = true;
  }

  // The ring under the pointer, or -1. Only the view counts: a card, the
  // dock, or a button over a ring keeps its own clicks.
  ringAt(e) {
    if (!this.on || e.target?.tagName !== "CANVAS") return -1;
    const [px, py] = this.at(e);
    return this.ctx.view.x.zs_view_ring_at(this.ctx.view.v, px, py, TOL * this.dpr());
  }

  hover(e) {
    if (this.drag || !this.on) return;
    this.ctx.host.style.cursor = this.ringAt(e) >= 0 ? "grab" : "";
  }

  press(e) {
    if (e.button !== 0 || !this.on) return;
    const axis = this.ringAt(e);
    if (axis < 0) return;
    const [px, py] = this.at(e);
    const x = this.ctx.view.x;
    const v = this.ctx.view.v;
    if (!x.zs_view_ring_press(v, axis, px, py)) return;
    e.preventDefault();
    e.stopPropagation();
    // The part at the press: the center of the rings is the pivot of the
    // preview, and its turn about Z gives the X and Y axes of a turn.
    const p = this.ctx.part();
    this.drag = { axis, sent: 0, want: 0, busy: false, index: p.index, pivot: [p.x, p.y, p.sizeZ / 2], rot: p.rotation ?? 0 };
    this.ctx.host.style.cursor = "grabbing";
    const target = e.target;
    try {
      target.setPointerCapture(e.pointerId);
    } catch {
      // A pointer with no capture (a test): the events still come here.
    }
    const move = (ev) => {
      const d = this.drag;
      if (!d) return;
      ev.stopPropagation();
      const [mx, my] = this.at(ev);
      d.want = Math.round(x.zs_view_ring_drag(v, mx, my, ev.shiftKey ? 5 : 15));
      this.showLabel(ev, d.want);
      this.preview(d);
      this.send();
    };
    const up = (ev) => {
      ev.stopPropagation();
      target.removeEventListener("pointermove", move, true);
      target.removeEventListener("pointerup", up, true);
      target.removeEventListener("pointercancel", up, true);
      x.zs_view_ring_release(v);
      this.label.hidden = true;
      const d = this.drag;
      this.drag = null;
      this.ctx.host.style.cursor = "";
      // No turn: no slice comes to end the preview.
      if (d && d.want === (d.shown ?? 0)) x.zs_view_part_preview(v, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
      this.ctx.frame();
      // The last steps go to the core first; then the turn is done, and
      // the slice that waited starts.
      this.finish(d);
    };
    target.addEventListener("pointermove", move, true);
    target.addEventListener("pointerup", up, true);
    target.addEventListener("pointercancel", up, true);
    this.ctx.frame();
  }

  // The beads of the part turn in the view at once (zs_view_part_preview),
  // by the angle of the drag since the slice that the view shows. The
  // slice of the new place ends the preview.
  preview(d) {
    const deg = d.want - (d.shown ?? 0);
    const t = (deg * Math.PI) / 180 / 2;
    const r = (d.rot * Math.PI) / 180;
    const axis = d.axis === 0 ? [Math.cos(r), Math.sin(r), 0] : d.axis === 1 ? [-Math.sin(r), Math.cos(r), 0] : [0, 0, 1];
    const s = Math.sin(t);
    const [px, py, pz] = d.pivot;
    this.ctx.view.x.zs_view_part_preview(this.ctx.view.v, d.index, axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(t), px, py, pz, 0, 0, 0, 1);
    this.ctx.frame();
  }

  // A slice of the drag came (the coarse slice of the part, at `turn`
  // degrees): the view shows it, so the preview turns from there.
  sliced(turn) {
    const d = this.drag;
    if (!d || turn === undefined) return;
    d.shown = turn;
    // The pivot of the part as it is now.
    const p = this.ctx.part();
    if (p) d.pivot = [p.x, p.y, p.sizeZ / 2];
    this.preview(d);
  }

  // One step at a time to the core: the turn since the last step.
  async send(d = this.drag) {
    if (!d || d.busy || d.want === d.sent) return;
    d.busy = true;
    const step = d.want - d.sent;
    d.sent = d.want;
    d.flight = this.ctx.turn(d.axis, step, d.sent);
    await d.flight;
    d.busy = false;
    this.send(d);
  }

  // The end of a drag: the step in flight and the last step, then done.
  async finish(d) {
    if (!d) return;
    while (d.busy) await d.flight;
    await this.send(d);
    await this.ctx.done?.();
  }

  showLabel(ev, deg) {
    const host = this.ctx.host.getBoundingClientRect();
    this.label.textContent = `${deg > 0 ? "+" : ""}${deg}° about ${NAMES[this.drag.axis]}`;
    this.label.hidden = false;
    this.label.style.left = `${ev.clientX - host.left + 16}px`;
    this.label.style.top = `${ev.clientY - host.top - 30}px`;
  }
}
