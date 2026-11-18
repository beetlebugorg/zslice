// farm.js: the Printers page of the drawer (specs: the print farm, phase
// 1). A tile for each printer of the user: its state, its job with the
// progress and the time left, and the filament in it, from the core
// (link.js status, zs_printer_status). While the page shows, the tiles
// read again every 10 s. Each tile can send the active plate: after a
// fresh "Is the bed clear?" of the user, never by itself.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { KINDS, status as readStatus, statusText } from "./link.js";

const EVERY_MS = 10000;

export class FarmPage {
  // ctx: { root (the page element), printers() -> { name: printer }, send
  //        (printer, print) -> Promise<{ ok, message }>, canSend() -> bool,
  //        plateName() -> text, slicedFor() -> the name of the printer
  //        that the plate is sliced for, toast(text), plates() -> [{ name,
  //        status, parts, bed }], sendPlate(i, printer) -> Promise<{ ok,
  //        message }> }
  constructor(ctx) {
    this.ctx = ctx;
    this.timer = 0;
    this.tiles = new Map();
    // The last status of each printer, by name.
    this.state = new Map();
    this.busy = false;
  }

  // The page shows: read the printers now, and every 10 s.
  start() {
    this.render();
    this.refresh();
    clearInterval(this.timer);
    this.timer = setInterval(() => this.refresh(), EVERY_MS);
  }

  // The page hides: no more requests.
  stop() {
    clearInterval(this.timer);
    this.timer = 0;
  }

  render() {
    const root = this.ctx.root;
    root.replaceChildren();
    this.tiles.clear();
    const printers = this.ctx.printers();
    const names = Object.keys(printers).filter((n) => printers[n].kind && printers[n].kind !== "none");
    const head = el("div", "farm-head");
    head.append(el("div", "farm-title", "Printers"), el("div", "dim", names.length ? `${names.length} with a connection. The tiles read again every 10 s.` : ""));
    root.append(head);
    if (names.length === 0) {
      root.append(el("div", "dim", "No printer has a connection. Add one with Manage printers… in the printer menu: printdeck, OctoPrint, or Moonraker (Klipper)."));
      return;
    }
    const grid = el("div", "farm-grid");
    for (const name of names) {
      const p = { ...printers[name], name };
      const tile = el("div", "farm-tile");
      const title = el("div", "farm-name", name);
      const kind = el("div", "dim farm-kind", KINDS[p.kind] ?? p.kind);
      const state = el("div", "farm-state", "…");
      const bar = el("div", "progress farm-bar");
      bar.append(el("div"));
      bar.hidden = true;
      const send = el("button", "pc-action", "Send the plate");
      send.title = "Upload the G-code of the active plate to this printer, and start it after you confirm that its bed is clear";
      send.onclick = () => this.sendTo(p, send);
      tile.append(title, kind, state, bar, send);
      grid.append(tile);
      this.tiles.set(name, { tile, state, bar, send });
    }
    root.append(grid);
    // The queue: the plates of the project, each to a printer.
    this.queue = el("div", "farm-queue");
    root.append(el("div", "farm-title farm-qtitle", "Plates to print"), this.queue);
    this.renderQueue();
  }

  // A printer is free when it answers and prints no job.
  free(name) {
    const st = this.state.get(name);
    if (!st) return false;
    const printing = !!st.job && st.progress > 0 && st.progress < 1;
    return !printing && !/print|busy|running|pause/i.test(st.state || "");
  }

  renderQueue() {
    if (!this.queue || !this.ctx.plates) return;
    const plates = this.ctx.plates();
    this.queue.replaceChildren();
    const list = plates.map((p, i) => ({ ...p, i })).filter((p) => p.parts > 0);
    if (list.length === 0) {
      this.queue.append(el("div", "dim", "No plate has parts."));
      return;
    }
    const names = [...this.tiles.keys()];
    for (const p of list) {
      const row = el("div", "farm-qrow");
      const what = el("div", "farm-qname", `${p.i + 1}. ${p.name || `Plate ${p.i + 1}`}`);
      const st = el("div", "dim", p.status === "done" ? `${p.parts} parts, sliced` : `${p.parts} parts, ${p.status}`);
      const pick = document.createElement("select");
      pick.setAttribute("aria-label", `The printer for plate ${p.i + 1}`);
      // Free printers first; a printer with a known bed smaller than the
      // plate bed does not fit.
      const fits = (n) => {
        const s = this.state.get(n);
        return !(s && s.bedX > 0 && p.bed && (s.bedX + 0.5 < p.bed[0] || s.bedY + 0.5 < p.bed[1]));
      };
      const order = names.filter(fits).sort((a, b) => Number(this.free(b)) - Number(this.free(a)));
      for (const n of order) pick.append(new Option(`${n}${this.free(n) ? "" : " (busy)"}`, n));
      const go = el("button", "pc-action", "Send");
      go.disabled = p.status !== "done" || order.length === 0;
      go.title = order.length === 0 ? "No printer with a connection fits this plate" : "Send this plate to the printer, after you confirm that its bed is clear";
      go.onclick = async () => {
        const name = pick.value;
        const pr = this.ctx.printers()[name];
        if (!pr) return;
        const warn = this.free(name) ? "" : `\n\n${name} looks busy now.`;
        if (!window.confirm(`Send "${p.name || `Plate ${p.i + 1}`}" to ${name}?${warn}\n\nIs the bed of ${name} clear? The print can start when the file is there.`)) return;
        go.disabled = true;
        try {
          const r = await this.ctx.sendPlate(p.i, { ...pr, name });
          this.ctx.toast(r.message);
          this.refresh();
        } finally {
          go.disabled = false;
        }
      };
      row.append(what, st, pick, go);
      this.queue.append(row);
    }
  }

  async refresh() {
    if (this.busy) return;
    this.busy = true;
    try {
      const printers = this.ctx.printers();
      await Promise.all([...this.tiles.entries()].map(async ([name, t]) => {
        const p = printers[name];
        if (!p) return;
        const r = await readStatus({ ...p, name });
        if (r.ok) this.state.set(name, r.status);
        else this.state.delete(name);
        t.tile.classList.toggle("farm-off", !r.ok);
        if (!r.ok) {
          t.state.textContent = r.message;
          t.bar.hidden = true;
          return;
        }
        const st = r.status;
        t.state.textContent = statusText(st);
        const printing = !!st.job && st.progress > 0 && st.progress < 1;
        t.bar.hidden = !printing;
        if (printing) t.bar.firstChild.style.width = `${Math.round(st.progress * 100)}%`;
        t.tile.classList.toggle("farm-busy", printing);
      }));
      for (const t of this.tiles.values()) t.send.disabled = !this.ctx.canSend();
      this.renderQueue();
    } finally {
      this.busy = false;
    }
  }

  async sendTo(p, button) {
    if (!this.ctx.canSend()) {
      this.ctx.toast("No G-code: the active plate has no slice yet.");
      return;
    }
    // A fresh confirmation of the user, each time. G-code of another
    // printer can have another bed, nozzle, or temperatures: say so.
    const other = this.ctx.slicedFor();
    const warn = other && other !== p.name ? `\n\nThe plate is sliced for ${other}, not for ${p.name}. Choose ${p.name} in the printer menu to slice it for that printer first.` : "";
    const clear = window.confirm(`Send "${this.ctx.plateName()}" to ${p.name}?${warn}\n\nIs the bed of ${p.name} clear? The print can start when the file is there.`);
    if (!clear) return;
    button.disabled = true;
    try {
      const r = await this.ctx.send(p, true);
      this.ctx.toast(r.message);
      this.refresh();
    } finally {
      button.disabled = false;
    }
  }
}
