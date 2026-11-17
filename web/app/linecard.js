// linecard.js: the card of a selected line, next to it in the view
// (docs/internals/one-view.md). A click on a line opens it at the click.
// It shows what the line is (the feature and the layer), its three
// numbers (the planned speed, the real speed, the flow), why it is slow,
// its size, and the first settings that change it, with live editors. A
// change slices at once. "More" opens the Selected page of the panel,
// with all the settings and the reasons.
//
// The card follows the line after a new slice (the inspector finds the
// line again), and closes with Esc, with a click on no line, or with ×.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";

const SLOW = [
  "",
  "Slow: the layer is short, so it prints slower to cool.",
  "Slow: the segments are short, so the head does not reach full speed.",
];
const MAX_SETTINGS = 3;

export class LineCard {
  // ctx: { browser (SettingsBrowser), host (the element of the view),
  //        more() (open the Selected page), close() (clear the selection) }
  constructor(ctx) {
    this.ctx = ctx;
    this.node = null;
    this.at = [0, 0];
    this.signature = "";
  }

  get open() {
    return !!this.node;
  }

  // Opens the card at a point (CSS pixels in the view) for the next
  // `show`.
  openAt(x, y) {
    this.at = [x, y];
    this.want = true;
  }

  close() {
    this.want = false;
    this.dropEditors();
    this.node?.remove();
    this.node = null;
    this.signature = "";
  }

  dropEditors() {
    const b = this.ctx.browser;
    for (const [name, list] of b.editors) b.editors.set(name, list.filter((e) => e.where !== "card"));
  }

  // The data of the inspector for the selected line (zs_app_inspect), or
  // null.
  show(info) {
    if (!info) {
      this.close();
      return;
    }
    if (!this.want) return;
    const sig = `${info.title}\n${info.settings}`;
    if (this.node && sig === this.signature) {
      this.update(info);
      return;
    }
    this.signature = sig;
    this.build(info);
  }

  build(info) {
    this.dropEditors();
    this.node?.remove();
    const card = el("div", "line-card");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", "The selected line");
    card.tabIndex = -1;
    const head = el("div", "lc-head");
    this.title = el("div", "lc-title");
    const close = el("button", "flat icon lc-close", "×");
    close.setAttribute("aria-label", "Close");
    close.title = "Close (Esc)";
    close.onclick = () => this.ctx.close();
    head.append(this.title, close);
    this.stats = el("div", "lc-stats");
    this.note = el("div", "lc-note");
    this.size = el("div", "lc-size");
    card.append(head, this.stats, this.note, this.size);

    // The first settings that change the line: the first section of the
    // inspector list (Speed, then Shape).
    const names = [];
    for (const line of info.settings.split("\n")) {
      if (line.startsWith("# ") || !line) continue;
      if (this.ctx.browser.byName.has(line)) names.push(line);
      if (names.length >= MAX_SETTINGS) break;
    }
    if (names.length > 0) {
      const box = el("div", "lc-settings");
      for (const name of names) {
        const s = this.ctx.browser.byName.get(name);
        const row = el("div", "lc-row");
        const label = el("div", "lc-label", s.label);
        label.title = s.doc;
        const ed = this.ctx.browser.makeEditor(s, "card");
        row.append(label, ed.node);
        this.ctx.browser.track(name, { where: "card", update: (entry) => ed.update(entry) });
        box.append(row);
      }
      card.append(box);
    }
    const foot = el("div", "lc-foot");
    const more = el("button", "flat", "All settings of this line…");
    more.onclick = () => this.ctx.more();
    foot.append(more);
    card.append(foot);
    card.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !e.target.closest("input, select, textarea")) {
        e.preventDefault();
        e.stopPropagation();
        this.ctx.close();
      }
    });
    this.ctx.host.append(card);
    this.node = card;
    this.update(info);
    this.place();
  }

  update(info) {
    this.title.textContent = `${info.title} · layer ${info.layer + 1}`;
    this.stats.replaceChildren(
      ...[
        [`${info.plannedSpeed.toFixed(0)} mm/s`, "planned"],
        [`${info.speed.toFixed(0)} mm/s`, "real"],
        [`${info.flow.toFixed(1)} mm³/s`, "flow"],
      ].map(([v, c], i) => {
        const d = el("div", "lc-stat" + (i === 1 && info.slowReason !== 0 ? " warning" : ""));
        d.append(el("div", "lc-v", v), el("div", "lc-c", c));
        return d;
      }),
    );
    this.note.textContent = SLOW[info.slowReason] ?? "";
    this.note.hidden = !this.note.textContent;
    const m = info.measure;
    let size = "";
    if (m) {
      if (m.shape === 1) size = `Circle ⌀ ${(2 * m.radius).toFixed(2)} mm · `;
      else if (m.shape === 2) size = `Arc r ${m.radius.toFixed(2)} mm · `;
      size += `segment ${m.segment.toFixed(2)} mm · ${m.closed ? "loop" : "path"} ${m.path.toFixed(1)} mm`;
    }
    this.size.textContent = size;
    this.size.hidden = !size;
  }

  // Next to the click, inside the view.
  place() {
    const card = this.node;
    const host = this.ctx.host.getBoundingClientRect();
    const w = card.offsetWidth;
    const h = card.offsetHeight;
    let x = this.at[0] + 18;
    let y = this.at[1] - 24;
    if (x + w > host.width - 60) x = this.at[0] - w - 18;
    x = Math.max(8, Math.min(host.width - w - 8, x));
    y = Math.max(60, Math.min(host.height - h - 8, y));
    card.style.left = `${x}px`;
    card.style.top = `${y}px`;
  }
}
