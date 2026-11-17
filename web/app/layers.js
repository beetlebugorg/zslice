// layers.js: the vertical slider with two knobs for the layers that show
// (linux/src/ui/layer-range.c). The top knob is the top layer; the bottom
// knob is the lowest layer that shows. Arrow keys move the top knob, and
// Shift with the arrow keys the bottom knob.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

export class LayerRange {
  // onChange(lo, hi): after each move.
  constructor(root, onChange) {
    this.root = root;
    this.onChange = onChange;
    this.trough = root.querySelector(".trough");
    this.highlight = root.querySelector(".highlight");
    this.hiKnob = root.querySelector(".knob.hi");
    this.loKnob = root.querySelector(".knob.lo");
    // The numbers of the layers: the top layer always, the bottom layer
    // when the range does not start at the first layer. Each is at the
    // height of its knob, as in layer-range.c.
    this.bubble = root.querySelector(".bubble.hi");
    this.loBubble = root.querySelector(".bubble.lo");
    this.count = 0;
    this.lo = 0;
    this.hi = 0;
    this.slowed = null;
    this.zs = null;
    // The numbers are placed in pixels: again after a change of size.
    new ResizeObserver(() => this.update()).observe(root);
    for (const [knob, which] of [[this.hiKnob, "hi"], [this.loKnob, "lo"]]) {
      knob.addEventListener("pointerdown", (e) => this.drag(e, which));
      knob.addEventListener("keydown", (e) => this.key(e, which));
    }
    // A click on the trough moves the nearer knob there.
    root.addEventListener("pointerdown", (e) => {
      if (e.target === this.hiKnob || e.target === this.loKnob || this.count === 0) return;
      const v = this.valueAt(e.clientY);
      this.drag(e, Math.abs(v - this.hi) <= Math.abs(v - this.lo) ? "hi" : "lo");
    });
  }

  // A new slice: n layers, and the layers that slow down to cool. The
  // knobs stay where they are if they can; else the top goes to the top.
  setLayers(n, slowed, zs) {
    const wasTop = this.hi >= this.count - 1;
    this.count = n;
    this.slowed = slowed;
    this.zs = zs;
    this.root.hidden = n === 0;
    if (wasTop || this.hi >= n) this.hi = Math.max(0, n - 1);
    this.lo = Math.min(this.lo, this.hi);
    this.update();
  }

  set(lo, hi, quiet = false) {
    const max = Math.max(0, this.count - 1);
    this.hi = Math.min(max, Math.max(0, Math.round(hi)));
    this.lo = Math.min(this.hi, Math.max(0, Math.round(lo)));
    this.update();
    if (!quiet) this.onChange(this.lo, this.hi);
  }

  // The layer at a y on the screen.
  valueAt(clientY) {
    const r = this.trough.getBoundingClientRect();
    const f = 1 - (clientY - r.top) / Math.max(1, r.height);
    return Math.round(Math.min(1, Math.max(0, f)) * Math.max(0, this.count - 1));
  }

  drag(e, which) {
    e.preventDefault();
    e.stopPropagation();
    const knob = which === "hi" ? this.hiKnob : this.loKnob;
    knob.focus();
    const move = (ev) => {
      const v = this.valueAt(ev.clientY);
      if (which === "hi") this.set(Math.min(this.lo, v), v);
      else this.set(v, Math.max(this.hi, v));
    };
    move(e);
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }

  key(e, which) {
    const step = { ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1, PageUp: 10, PageDown: -10 }[e.key];
    if (step === undefined) return;
    e.preventDefault();
    if (e.shiftKey || which === "lo") this.set(this.lo + step, Math.max(this.hi, this.lo + step));
    else this.set(Math.min(this.lo, this.hi + step), this.hi + step);
  }

  update() {
    const max = Math.max(1, this.count - 1);
    const pos = (v) => `${(1 - v / max) * 100}%`;
    // The knobs are placed in the trough area (9 px from each end).
    const place = (el, v) => { el.style.top = `calc(9px + (100% - 18px) * ${1 - v / max})`; };
    place(this.hiKnob, this.hi);
    place(this.loKnob, this.lo);
    this.highlight.style.top = pos(this.hi);
    this.highlight.style.bottom = `${(this.lo / max) * 100}%`;
    const slow = (l) => (this.slowed && this.slowed[l] ? "❄ " : "");
    this.bubble.textContent = `${slow(this.hi)}${this.hi + 1}`;
    const showLo = this.lo > 0 && this.lo < this.hi;
    this.loBubble.hidden = !showLo;
    this.loBubble.textContent = String(this.lo + 1);
    // The two numbers in pixels: the bottom one goes under the top one
    // when the knobs are close, so it never draws under it.
    const h = this.root.clientHeight;
    const y = (v) => 9 + (h - 18) * (1 - v / max);
    const hiY = y(this.hi);
    const bh = this.bubble.offsetHeight || 18;
    this.bubble.style.top = `${hiY}px`;
    if (showLo) this.loBubble.style.top = `${Math.max(y(this.lo), hiY + bh + 2)}px`;
    const z = this.zs ? this.zs[this.hi] : 0;
    this.root.title = `Layer ${this.hi + 1} of ${this.count}, at z ${z.toFixed(2)} mm. Drag a knob: the top knob is the top layer, and the bottom knob the lowest layer that shows. Arrow keys: the top knob; Shift+arrow keys: the bottom knob.`;
  }
}
