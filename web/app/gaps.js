// gaps.js: the Gaps view of the web page (linux/src/ui/preview.c: the Gaps
// toggle and its count; inspector.c: the gap page).
//
// A gap is an area of a layer that should be solid and that no line
// covers (src/gaps.zig). With Gaps on, the views show the gaps of the top
// shown layer in red, and the toolbar shows their number and area. A click
// on a gap opens the gap page: its size and place, the lines next to it,
// and the settings that can close it, each with Apply (all layers) and
// This layer (an override of the layer of the gap).
//
// The app core is in the worker: the page asks it for the cells of the
// gaps of a layer (op "gaps"), gives them to the 3D view of the page
// (zs_view_set_gap_runs) and to the 2D drawing (gl.js), and asks the worker
// for the gap under a click (op "gapAt").
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { displayValue } from "./format.js";

const FEATURES = ["outer wall", "inner wall", "skin", "sparse infill", "ironing", "skirt or brim",
  "support", "support interface", "slope smoothing", "slope ironing"];

export class Gaps {
  // ctx: { client, view (View3D), gl (GlRenderer), button, count (the
  //        label), page (the Selected page), browser (its infos),
  //        layerZ(layer), showPage(), setSetting(name, value),
  //        setScoped(name, value, zmin, zmax), requestFrame() }
  constructor(ctx) {
    this.ctx = ctx;
    this.on = false;
    this.layer = -1;
    this.data = null;
    this.asked = 0;
    // The gap of the gap page: { layer, x, y }, to find it again after a
    // new slice.
    this.shown = null;
    ctx.button.disabled = false;
    ctx.button.title = "Gaps: show the gaps of the top layer in red: areas that should be solid that no line covers. Click a gap for the settings that can close it.";
    ctx.button.onclick = () => this.setOn(!this.on);
  }

  setOn(on) {
    this.on = on;
    this.ctx.button.classList.toggle("checked", on);
    if (!on) {
      this.data = null;
      this.layer = -1;
      this.show();
    } else {
      this.refresh(this.wanted ?? 0);
    }
  }

  // The top layer changed, or a new slice came: ask for the gaps of
  // `layer` (only the last answer counts).
  async refresh(layer, sliced = false) {
    this.wanted = layer;
    if (!this.on || layer < 0) return;
    if (!sliced && layer === this.layer && this.data) return;
    const id = ++this.asked;
    const r = await this.ctx.client.call("gaps", { layer });
    if (id !== this.asked || !this.on) return;
    this.layer = layer;
    this.data = r.gaps ? r : null;
    this.show();
    if (sliced && this.shown) this.refind();
  }

  // The gaps in the views and the count.
  show() {
    const { view, gl, count } = this.ctx;
    const d = this.data;
    if (!d) {
      view.x.zs_view_set_gap_runs(view.v, -1n, 0, 0, 0, 0);
      gl.setGaps2d(null, 0);
      count.hidden = true;
    } else {
      const n = d.runs.length / 3;
      const z = this.ctx.layerZ(this.layer);
      const bytes = new Uint8Array(d.runs.buffer, d.runs.byteOffset, d.runs.byteLength);
      view.w.withBytes(bytes, (p) => view.x.zs_view_set_gap_runs(view.v, BigInt(this.layer), z, p, n, d.cell));
      gl.setGaps2d(d.runs, d.cell);
      let area = 0;
      for (const g of d.gaps) area += g.area;
      const k = d.gaps.length;
      count.textContent = k === 0 ? "No gaps" : `${k} gap${k === 1 ? "" : "s"} · ${area.toFixed(2)} mm²`;
      count.hidden = false;
    }
    this.ctx.requestFrame();
  }

  // A click at x, y (mm) on the top layer: opens the gap page and returns
  // true if a gap is there.
  async pick(x, y) {
    if (!this.on || this.layer < 0) return false;
    const layer = this.layer;
    const r = await this.ctx.client.call("gapAt", { layer, x, y });
    if (r.index < 0) return false;
    this.shown = { layer, x: r.gap.x, y: r.gap.y };
    this.page(layer, r);
    return true;
  }

  // After a new slice: the gap page again for the gap at the same place,
  // or a note that it is closed.
  async refind() {
    const s = this.shown;
    const r = await this.ctx.client.call("gapAt", { layer: s.layer, x: s.x, y: s.y });
    if (this.shown !== s) return;
    if (r.index < 0) this.closedPage(s.layer);
    else this.page(s.layer, r);
  }

  // Forget the gap page (a line is selected, or the page is gone).
  forget() {
    this.shown = null;
  }

  closedPage(layer) {
    const root = el("div", "inspector");
    root.append(el("div", "insp-title", `Gap · layer ${layer + 1}`));
    root.append(el("div", "dim", "The gap is closed: the new slice has no gap here."));
    this.ctx.page.replaceChildren(root);
  }

  // The gap page: r is the answer of "gapAt".
  page(layer, r) {
    const { browser } = this.ctx;
    const g = r.gap;
    const root = el("div", "inspector gap-page");
    root.append(el("div", "insp-title", `Gap · layer ${layer + 1}`));
    const next = FEATURES.filter((_, f) => g.features & (1 << f)).join(", ") || "no line";
    let facts = `${g.area.toFixed(3)} mm², ${g.width.toFixed(2)} mm wide, at ${g.x.toFixed(1)}, ${g.y.toFixed(1)} mm. Next to: ${next}.`;
    if (g.atEdge) facts += " It touches the edge of the solid area (the outline, or the sparse infill).";
    root.append(el("div", "", facts));
    root.append(el("div", "heading gap-heading", "Settings that can close it"));
    if (r.steps.length === 0) root.append(el("div", "dim", "No setting change closes this gap."));
    const z = this.ctx.layerZ(layer);
    for (const st of r.steps) {
      const info = browser.byName.get(st.name);
      const label = info?.label ?? st.name;
      const unit = info?.unit ? ` ${info.unit}` : "";
      const now = info ? displayValue(info, st.now) : st.now;
      const to = info ? displayValue(info, st.value) : st.value;
      root.append(el("div", "gap-step", `${label}: ${now}${unit} → ${to}${unit}`));
      root.append(el("div", "dim", st.why));
      const buttons = el("div", "gap-buttons");
      const all = el("button", "flat", "Apply");
      all.title = "Change the setting for all layers, and slice again.";
      all.onclick = () => this.ctx.setSetting(st.name, st.value);
      buttons.append(all);
      if (info?.perLayer) {
        const one = el("button", "flat", "This layer");
        one.title = "Change the setting only for this layer, and slice again.";
        one.onclick = () => this.ctx.setScoped(st.name, st.value, z, z);
        buttons.append(one);
      }
      root.append(buttons);
    }
    this.ctx.page.replaceChildren(root);
    this.ctx.showPage();
  }
}
