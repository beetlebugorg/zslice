// farm.js: the Printers page. One card for each printer of the user, from
// the core (link.js status, zs_printer_status): its name, its state, the
// job with its progress and the time left, the temperatures, the filament,
// and the live camera (camera.js). A click on the camera shows it large.
// The plates of the project to print are at the top, each with a printer
// to send it to. While the page shows, the cards read again every 10 s.
//
// A send goes out only after a fresh "Is the bed clear?" of the user,
// never by itself.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { KINDS, camera as readCamera, status as readStatus } from "./link.js";
import { CameraView, closeCameras } from "./camera.js";
import { openMenu } from "./menus.js";

const EVERY_MS = 10000;

// The states of zs_printer_status_farm_state, for the badge of a card.
const STATES = [
  { key: "offline", text: "Offline", count: "offline" },
  { key: "idle", text: "Ready", count: "ready" },
  { key: "printing", text: "Printing", count: "printing" },
  { key: "paused", text: "Paused", count: "paused" },
  { key: "done", text: "Done: clear the bed", count: "done" },
  { key: "failed", text: "Failed", count: "failed" },
];

function temp(v, target) {
  if (v === null || v === undefined) return "";
  const t = target > 0 ? ` / ${Math.round(target)}` : "";
  return `${Math.round(v)}${t} °C`;
}

export class FarmPage {
  // ctx: { root (the page element), printers() -> { name: printer }, send
  //        (printer, print) -> Promise<{ ok, message }>, canSend() -> bool,
  //        plateName() -> text, slicedFor() -> the name of the printer
  //        that the plate is sliced for, toast(text), plates() -> [{ name,
  //        status, parts, bed }], sendPlate(i, printer) -> Promise<{ ok,
  //        message }>, manage() (the dialog of the printers), formatTime(s),
  //        plateTotals() }
  constructor(ctx) {
    this.ctx = ctx;
    this.timer = 0;
    this.cards = new Map();
    // The last status of each printer, by name.
    this.state = new Map();
    // The camera of each printer, by name: a source, or null for none.
    // Read once each time the page shows.
    this.cams = new Map();
    // The sends of this session, by plate: { printer, at }.
    this.sent = new Map();
    // The time and the filament of each plate (plateTotals).
    this.totals = [];
    this.busy = false;
    this.large = null;
  }

  // The page shows: read the printers now, and every 10 s.
  start() {
    this.cams.clear();
    this.render();
    this.refresh();
    clearInterval(this.timer);
    this.timer = setInterval(() => this.refresh(), EVERY_MS);
  }

  // The page hides: no more requests, and no cameras.
  stop() {
    clearInterval(this.timer);
    this.timer = 0;
    this.closeLarge();
    closeCameras(this.ctx.root);
  }

  names() {
    const printers = this.ctx.printers();
    return Object.keys(printers).filter((n) => printers[n].kind && printers[n].kind !== "none");
  }

  render() {
    const root = this.ctx.root;
    closeCameras(root);
    root.replaceChildren();
    this.cards.clear();
    const names = this.names();
    const head = el("div", "farm-head");
    const title = el("h2", "farm-title", "Printers");
    this.counts = el("div", "farm-counts");
    this.counts.setAttribute("aria-live", "polite");
    const more = el("button", "flat icon farm-more", "⋯");
    more.title = "More";
    more.setAttribute("aria-label", "More actions for the printers");
    more.onclick = () => openMenu(more, [
      { label: Object.keys(this.ctx.printers()).length ? "Manage printers…" : "Add a printer…", action: () => this.ctx.manage?.() },
      { label: "Read the printers again", action: () => this.refresh() },
    ]);
    head.append(title, this.counts, more);
    root.append(head);
    // The plates to print.
    this.queueBox = el("section", "farm-queue-box");
    this.queueBox.setAttribute("aria-label", "Plates to print");
    root.append(this.queueBox);
    if (names.length === 0) {
      const empty = el("div", "farm-empty");
      empty.append(el("p", "dim", "No printer has a connection. Add a printdeck, an OctoPrint, or a Moonraker (Klipper) printer to see it here."));
      if (this.ctx.manage) {
        const add = el("button", "suggested", Object.keys(this.ctx.printers()).length ? "Manage printers…" : "Add a printer…");
        add.onclick = () => this.ctx.manage();
        empty.append(add);
      }
      root.append(empty);
      this.renderQueue();
      return;
    }
    const grid = el("div", "farm-grid");
    for (const name of names) {
      const card = this.makeCard(name);
      grid.append(card.root);
      this.cards.set(name, card);
    }
    root.append(grid);
    this.renderQueue();
    this.renderCounts();
  }

  makeCard(name) {
    const p = { ...this.ctx.printers()[name], name };
    const root = el("article", "farm-card");
    root.setAttribute("aria-label", name);
    const cam = el("div", "farm-cam");
    cam.hidden = true;
    const top = el("div", "farm-top");
    const who = el("div", "farm-who");
    who.append(el("div", "farm-name", name), el("div", "dim farm-kind", KINDS[p.kind] ?? p.kind));
    const badge = el("span", "farm-badge", "Reading");
    top.append(who, badge);
    const job = el("div", "farm-job");
    const jobName = el("div", "farm-jobname");
    const bar = el("div", "progress farm-bar");
    bar.append(el("div"));
    const jobFacts = el("div", "farm-facts");
    job.append(jobName, bar, jobFacts);
    job.hidden = true;
    const why = el("div", "farm-why");
    why.hidden = true;
    const heat = el("div", "farm-heat");
    heat.hidden = true;
    const roll = el("div", "dim farm-roll");
    roll.hidden = true;
    const actions = el("div", "farm-actions");
    const send = el("button", "suggested farm-send", "Print the plate");
    send.disabled = true;
    send.onclick = () => this.sendTo(p, send, true);
    const menu = el("button", "flat icon farm-menu", "⋯");
    menu.title = "More";
    menu.setAttribute("aria-label", `More actions for ${name}`);
    menu.onclick = () => openMenu(menu, [
      { label: "Upload the plate only", tip: "Upload the G-code, and do not start it", disabled: !this.ctx.canSend(), action: () => this.sendTo(p, send, false) },
      { label: "Show the camera large", disabled: !this.cams.get(name), action: () => this.openLarge(name) },
      { label: "Open the page of the printer", tip: p.https || p.url, action: () => window.open(p.https || p.url, "_blank", "noopener") },
    ]);
    actions.append(send, menu);
    root.append(cam, top, job, why, heat, roll, actions);
    return { root, cam, badge, job, jobName, bar, jobFacts, why, heat, roll, send, view: null, p, read: false };
  }

  // The camera of a card, when the printer has one.
  async loadCamera(name, card) {
    if (this.cams.has(name)) return;
    this.cams.set(name, null);
    const r = await readCamera(card.p);
    const src = r.ok ? r.camera : null;
    this.cams.set(name, src);
    if (!src || !card.root.isConnected) return;
    card.view = new CameraView(src, { label: name, printdeck: card.p.kind === "printdeck", onclick: () => this.openLarge(name) });
    card.cam.replaceChildren(card.view.el);
    card.cam.hidden = false;
  }

  // A printer is free when it answers and is ready.
  free(name) {
    const st = this.state.get(name);
    return !!st && st.farm === 1;
  }

  // ", free in 1 h 5 min" for a printer with a job and its time left.
  freeIn(name) {
    const st = this.state.get(name);
    const left = st?.timeLeft ?? 0;
    if (!(left > 0)) return "";
    return `, free in ${this.time(left)}`;
  }

  time(s) {
    return this.ctx.formatTime ? this.ctx.formatTime(s) : `${Math.round(s / 60)} min`;
  }

  renderCounts() {
    if (!this.counts) return;
    const n = new Array(STATES.length).fill(0);
    for (const [name, c] of this.cards) {
      const st = this.state.get(name);
      if (st) n[st.farm] += 1;
      else if (c.read) n[0] += 1;
    }
    this.counts.replaceChildren();
    for (const i of [5, 4, 3, 2, 1, 0]) {
      if (n[i]) this.counts.append(el("span", `farm-count farm-${STATES[i].key}`, `${n[i]} ${STATES[i].count}`));
    }
  }

  updateCard(name, r) {
    const c = this.cards.get(name);
    if (!c) return;
    c.read = true;
    const st = r.ok ? r.status : null;
    const s = STATES[st ? st.farm : 0] ?? STATES[1];
    c.root.dataset.state = s.key;
    c.badge.className = `farm-badge farm-${s.key}`;
    c.badge.textContent = s.text;
    c.badge.title = st?.state ? `The printer says "${st.state}"` : "";
    if (!st) {
      c.job.hidden = true;
      c.heat.hidden = true;
      c.heatText = "";
      c.roll.hidden = true;
      c.why.hidden = false;
      // The first sentence on the card; all of it in the tooltip.
      c.why.textContent = r.message.replace(/\s*\(.*?\)\./, ".").split(/(?<=\.)\s/)[0];
      c.why.title = r.message;
      c.why.className = "farm-why farm-offline-why";
      // A tap shows all of it (a phone has no tooltip).
      c.why.onclick = () => {
        c.why.textContent = c.why.title || c.why.textContent;
      };
      c.send.disabled = true;
      c.send.title = "The printer does not answer.";
      c.view?.setEnabled(false);
      return;
    }
    if (!this.large || this.large.name !== name) c.view?.setEnabled(true);
    // The job.
    const hasJob = !!st.job && st.farm >= 2;
    c.job.hidden = !hasJob;
    if (hasJob) {
      c.jobName.textContent = st.job;
      const pct = Math.round((st.farm === 4 ? 1 : st.progress) * 100);
      c.bar.firstChild.style.width = `${pct}%`;
      const facts = [`${pct} %`];
      if (st.farm === 2 || st.farm === 3) {
        if (st.timeLeft > 0) facts.push(`${this.time(st.timeLeft)} left`);
        if (st.layers > 0) facts.push(`layer ${st.layer} of ${st.layers}`);
      }
      c.jobFacts.textContent = facts.join(" · ");
    }
    // Why it failed or paused.
    const why = st.farm === 5 || st.farm === 3 ? st.message : "";
    c.why.hidden = !why;
    c.why.className = "farm-why";
    c.why.textContent = why;
    c.why.title = "";
    // The temperatures.
    const h = st.heat ?? {};
    const parts = [];
    if (h.nozzle !== null && h.nozzle !== undefined) parts.push(["Nozzle", temp(h.nozzle, h.nozzleTarget)]);
    if (h.bed !== null && h.bed !== undefined) parts.push(["Bed", temp(h.bed, h.bedTarget)]);
    if (h.chamber !== null && h.chamber !== undefined) parts.push(["Chamber", temp(h.chamber, 0)]);
    c.heat.replaceChildren();
    for (const [k, v] of parts) {
      const t = el("span", "farm-t");
      t.append(el("span", "dim", `${k} `), v);
      c.heat.append(t);
    }
    c.heat.hidden = parts.length === 0;
    c.heatText = parts.map(([k, v]) => `${k} ${v}`).join(", ");
    // The filament.
    const roll = st.spool?.name ? `${st.spool.name}${st.material ? ` (${st.material})` : ""}${st.spool.left > 0 ? `, ${Math.round(st.spool.left)} g left` : ""}` : st.material;
    c.roll.hidden = !roll;
    c.roll.textContent = roll || "";
    // The main action: print the active plate on a ready printer.
    const canSend = this.ctx.canSend();
    c.send.disabled = !canSend || st.farm !== 1;
    c.send.title = !canSend ? "Slice the plate first." : st.farm === 4 ? "A print waits on the bed: clear it first." : st.farm !== 1 ? "The printer is busy." : "Upload the G-code of the active plate, and start it after you confirm that the bed is clear";
    if (!this.cams.has(name)) this.loadCamera(name, c);
  }

  renderQueue() {
    const box = this.queueBox;
    if (!box || !this.ctx.plates) return;
    box.replaceChildren();
    const plates = this.ctx.plates();
    const list = plates.map((p, i) => ({ ...p, i })).filter((p) => p.parts > 0);
    const head = el("div", "farm-qhead");
    head.append(el("h3", "farm-qtitle", "Plates to print"));
    if (list.length) head.append(el("span", "farm-qn", String(list.length)));
    box.append(head);
    if (list.length === 0) {
      box.append(el("div", "dim farm-qempty", "Add parts to a plate, and it shows here to print."));
      return;
    }
    const names = [...this.cards.keys()];
    const rows = el("div", "farm-queue");
    for (const p of list) {
      const row = el("div", "farm-qrow");
      const what = el("div", "farm-qwhat");
      what.append(el("div", "farm-qname", `${p.i + 1}. ${p.name || `Plate ${p.i + 1}`}`));
      const t = this.totals[p.i];
      const parts = `${p.parts} part${p.parts === 1 ? "" : "s"}`;
      const facts = p.status === "done" && t ? `${parts} · ${this.time(t.timeS)} · ${t.filamentG.toFixed(1)} g` : `${parts} · ${p.status === "done" ? "sliced" : "not sliced yet"}`;
      what.append(el("div", "dim farm-qfacts", facts));
      const sent = this.sent.get(p.i);
      if (sent) {
        row.classList.add("farm-sent");
        what.append(el("div", "farm-qsent", `Sent to ${sent.printer} at ${sent.at}`));
      }
      const pick = document.createElement("select");
      pick.setAttribute("aria-label", `The printer for plate ${p.i + 1}`);
      // Ready printers first. A printer with a known bed smaller than the
      // plate bed does not fit.
      const fits = (n) => {
        const s = this.state.get(n);
        return !(s && s.bedX > 0 && p.bed && (s.bedX + 0.5 < p.bed[0] || s.bedY + 0.5 < p.bed[1]));
      };
      const order = names.filter(fits).sort((a, b) => Number(this.free(b)) - Number(this.free(a)));
      for (const n of order) pick.append(new Option(`${n}${this.free(n) ? " (ready)" : ` (busy${this.freeIn(n)})`}`, n));
      const go = el("button", "farm-qsend", "Send");
      go.disabled = p.status !== "done" || order.length === 0;
      go.title = order.length === 0 ? "No printer with a connection fits this plate" : p.status !== "done" ? "Slice the plate first" : "Send this plate to the printer, after you confirm that its bed is clear";
      go.onclick = async () => {
        const name = pick.value;
        const pr = this.ctx.printers()[name];
        if (!pr) return;
        const warn = this.free(name) ? "" : `\n\n${name} looks busy now.`;
        if (!window.confirm(`Send "${p.name || `Plate ${p.i + 1}`}" to ${name}?${warn}\n\nIs the bed of ${name} clear? The print can start when the file is there${pr.kind === "printdeck" ? " (a deck set to ask waits for a press of Print on it)" : ""}.`)) return;
        go.disabled = true;
        try {
          const r = await this.ctx.sendPlate(p.i, { ...pr, name });
          this.ctx.toast(r.message);
          if (r.ok) this.sent.set(p.i, { printer: name, at: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) });
          this.refresh();
        } finally {
          go.disabled = false;
        }
      };
      const to = el("div", "farm-qto");
      to.append(pick, go);
      row.append(what, to);
      rows.append(row);
    }
    box.append(rows);
  }

  async refresh() {
    if (this.busy) return;
    this.busy = true;
    try {
      const printers = this.ctx.printers();
      await Promise.all([...this.cards.keys()].map(async (name) => {
        const p = printers[name];
        if (!p) return;
        const r = await readStatus({ ...p, name });
        if (r.ok) this.state.set(name, r.status);
        else this.state.delete(name);
        this.updateCard(name, r);
        this.renderCounts();
      }));
      if (this.ctx.plateTotals) this.totals = await this.ctx.plateTotals();
      this.renderQueue();
      this.updateLarge();
    } finally {
      this.busy = false;
    }
  }

  // ---- the large camera ----

  openLarge(name) {
    const src = this.cams.get(name);
    if (!src) return;
    this.closeLarge();
    const d = el("dialog", "cam-dialog");
    d.setAttribute("aria-label", `The camera of ${name}`);
    const bar = el("div", "page-bar");
    const left = el("div", "cam-head");
    const line = el("div", "dim cam-line");
    left.append(el("div", "cam-title", name), line);
    const close = el("button", "flat icon", "×");
    close.setAttribute("aria-label", "Close");
    close.onclick = () => this.closeLarge();
    bar.append(left, close);
    const view = new CameraView(src, { large: true, label: name, printdeck: this.ctx.printers()[name]?.kind === "printdeck" });
    d.append(bar, view.el);
    d.onclose = () => this.closeLarge();
    this.ctx.root.append(d);
    // The small camera of the card rests while the large one plays.
    this.cards.get(name)?.view?.setEnabled(false);
    this.large = { name, d, view, line };
    d.showModal();
    this.updateLarge();
  }

  updateLarge() {
    const l = this.large;
    if (!l) return;
    const c = this.cards.get(l.name);
    const st = this.state.get(l.name);
    const bits = [c?.badge.textContent ?? ""];
    if (st?.job && st.farm >= 2) bits.push(`${st.job}, ${Math.round((st.farm === 4 ? 1 : st.progress) * 100)} %${st.timeLeft > 0 && st.farm === 2 ? `, ${this.time(st.timeLeft)} left` : ""}`);
    if (c?.heatText) bits.push(c.heatText);
    l.line.textContent = bits.filter(Boolean).join(" · ");
  }

  closeLarge() {
    const l = this.large;
    if (!l) return;
    this.large = null;
    l.view.close();
    if (l.d.open) l.d.close();
    l.d.remove();
    this.cards.get(l.name)?.view?.setEnabled(true);
  }

  async sendTo(p, button, print) {
    if (!this.ctx.canSend()) {
      this.ctx.toast("No G-code: the active plate has no slice yet.");
      return;
    }
    // A fresh confirmation of the user for each print. G-code of another
    // printer can have another bed, nozzle, or temperatures: say so.
    const other = this.ctx.slicedFor();
    const warn = other && other !== p.name ? `\n\nThe plate is sliced for ${other}. Choose ${p.name} in the printer menu to slice it for that printer first.` : "";
    if (print) {
      const clear = window.confirm(`Send "${this.ctx.plateName()}" to ${p.name}?${warn}\n\nIs the bed of ${p.name} clear? The print can start when the file is there${p.kind === "printdeck" ? " (a deck set to ask waits for a press of Print on it)" : ""}.`);
      if (!clear) return;
    } else if (warn && !window.confirm(`Upload "${this.ctx.plateName()}" to ${p.name}?${warn}`)) {
      return;
    }
    button.disabled = true;
    try {
      const r = await this.ctx.send(p, print);
      this.ctx.toast(r.message);
      this.refresh();
    } finally {
      button.disabled = false;
    }
  }
}
