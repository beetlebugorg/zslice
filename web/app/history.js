// history.js: the History tab of the panel (linux/src/ui/history.c).
//
// The history is the list of the steps of undo and redo, in the worker.
// This page lists them, the newest first: the kind of each step (a badge
// with a color), its number and time, and its changes in words. A click on
// a step goes to it, and the preview slices at that step. Each change of
// the step now or an earlier step has an undo button that undoes only that
// change and keeps the later ones. A double click on a change opens its
// setting. The up and down arrow keys go to the next and the step before.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { openMenuAt } from "./menus.js";
import { revertible } from "./format.js";

// The look of each kind of step (history.c, looks).
const NS = "http://www.w3.org/2000/svg";
// The paths of the glyph of a kind on the 18 x 18 grid of the icons of
// the app, in its style: outlines with round ends. Move, Turn, and Support
// are the icons of the tool strip (index.html); Printer is the icon of
// the printer button.
const GLYPHS = {
  walls: '<rect x="2.5" y="2.5" width="13" height="13" rx="3"/><rect x="6" y="6" width="6" height="6" rx="1"/>',
  infill: '<rect x="2.5" y="2.5" width="13" height="13" rx="1"/><path d="M2.5 9 9 2.5M2.5 15.5 15.5 2.5M9 15.5 15.5 9M2.5 9 9 15.5M2.5 2.5l13 13M9 2.5 15.5 9"/>',
  surface: '<path d="M2.5 3.5h13M2.5 14.5h13"/><path d="M2.5 6h13M2.5 12h13" stroke-dasharray="1.6 1.9"/>',
  speed: '<path d="M3 13.5a6.5 6.5 0 1 1 12 0"/><path d="M9 11 12.5 6.5"/><circle cx="9" cy="11" r="1"/>',
  heat: '<path d="M7 10.6V4a2 2 0 0 1 4 0v6.6a3.6 3.6 0 1 1-4 0z"/><path d="M9 12.5V7"/>',
  support: '<path d="M2 4.5h14l-2 3H4z"/><path d="M5 7.5v8M9 7.5v8M13 7.5v8M3.5 15.5h11"/>',
  layers: '<path d="M9 2.5 16 6l-7 3.5L2 6z"/><path d="M2 9.5 9 13l7-3.5M2 12.5 9 16l7-3.5"/>',
  move: '<path d="M2 9h14M9 2v14M13.7 6.8 16 9l-2.3 2.2M4.3 6.8 2 9l2.3 2.2M6.8 4.3 9 2l2.2 2.3M6.8 13.7 9 16l2.2-2.3"/>',
  rotate: '<path d="M14.5 9a5.5 5.5 0 1 1-1.6-3.9"/><path d="M13.6 2.2v3.3h-3.3"/>',
  scale: '<path d="M3 15 15 3M10 3h5v5M3 10v5h5"/>',
  add: '<path d="M3.5 9h11M9 3.5v11"/>',
  remove: '<path d="M3.5 9h11"/>',
  quality: '<path d="M9 2.2l2 4.3 4.7.6-3.4 3.2.9 4.6L9 12.6l-4.2 2.3.9-4.6-3.4-3.2 4.7-.6z"/>',
  printer: '<path d="M5 6.5V2.5h8v4M5 13H2.5V6.5h13V13H13M5 10.5h8v5H5z"/>',
  start: '<circle cx="9" cy="9" r="5.5"/><circle cx="9" cy="9" r="1.5" fill="#fff"/>',
  other: '<circle cx="4" cy="9" r=".6"/><circle cx="9" cy="9" r=".6"/><circle cx="14" cy="9" r=".6"/>',
};

// An <svg> with the glyph of kind `k`, `size` pixels wide.
export function glyph(k, size) {
  const s = document.createElementNS(NS, "svg");
  s.setAttribute("viewBox", "0 0 18 18");
  for (const [a, v] of [["fill", "none"], ["stroke", "#fff"], ["stroke-width", "1.6"], ["stroke-linecap", "round"], ["stroke-linejoin", "round"]]) s.setAttribute(a, v);
  s.setAttribute("width", size);
  s.setAttribute("height", size);
  s.setAttribute("aria-hidden", "true");
  s.innerHTML = GLYPHS[k] ?? GLYPHS.other;
  return s;
}

const LOOKS = {
  walls: ["#d9480f", "Walls"],
  infill: ["#2b8a3e", "Infill"],
  surface: ["#1c7ed6", "Top and bottom"],
  speed: ["#7c3aed", "Speed"],
  heat: ["#dc2626", "Temperature and cooling"],
  support: ["#6b7280", "Support"],
  layers: ["#d99000", "Layers"],
  move: ["#0c949e", "Move"],
  rotate: ["#0c949e", "Turn"],
  scale: ["#0c949e", "Scale"],
  add: ["#0c949e", "Part added"],
  remove: ["#0c949e", "Part removed"],
  quality: ["#db2777", "Quality"],
  printer: ["#334155", "Printer"],
  other: ["#808080", "Other"],
  start: ["#808080", "Start"],
};

function clock(ms) {
  const d = new Date(ms);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export class HistoryPage {
  // ctx: { client, applySettings(r), openSetting(name), toast(text),
  //        visible(), timeline (the bar under the scrub bar),
  //        undoRedo(op) }
  constructor(root, ctx) {
    this.root = root;
    this.ctx = ctx;
    this.list = null;
    this.asked = 0;
    root.tabIndex = 0;
    root.addEventListener("keydown", (e) => this.key(e));
    this.render();
  }

  // Asks the worker for the list again (only the last answer counts).
  async refresh() {
    const id = ++this.asked;
    const r = await this.ctx.client.call("history", {});
    const edits = await this.ctx.client.call("edits", {});
    if (id !== this.asked) return;
    this.list = r;
    this.edits = edits ?? [];
    if (this.ctx.visible()) this.render();
    this.renderTimeline();
  }

  // The timeline (history.c, zg_timeline_new): undo and redo, a mark for
  // each step (the oldest at the left), and the count. The left and right
  // arrow keys go through the steps.
  renderTimeline() {
    const bar = this.ctx.timeline;
    if (!bar) return;
    const l = this.list;
    const n = l ? l.steps.length : 0;
    const now = l ? l.current : 0;
    const tool = (label, title, enabled, fn) => {
      const b = el("button", "flat icon tl-tool", label);
      b.title = title;
      b.disabled = !enabled;
      b.onclick = fn;
      return b;
    };
    const parts = [
      tool("↶", "Undo (Ctrl+Z)", now > 0, () => this.ctx.undoRedo("undo")),
      tool("↷", "Redo (Ctrl+Shift+Z)", now + 1 < n, () => this.ctx.undoRedo("redo")),
      el("span", "tl-sep"),
      Object.assign(el("button", "tl-title", "History"), { title: "Show the list of the changes", onclick: () => this.ctx.toggle?.() }),
    ];
    if (n <= 1) {
      parts.push(el("span", "tl-empty", "Your changes show here"));
    } else {
      const marks = el("div", "tl-marks");
      for (let i = 0; i < n; i++) {
        const s = l.steps[i];
        if (i > 0) marks.append(el("span", "tl-line" + (i > now ? " later" : "")));
        const [color, label] = LOOKS[s.kind] ?? LOOKS.other;
        const m = el("button", "tl-mark" + (i === now ? " now" : i > now ? " later" : ""));
        m.style.setProperty("--kind", color);
        m.append(glyph(i === 0 ? "start" : (LOOKS[s.kind] ? s.kind : "other"), 12));
        const words = s.text.split("\n").filter(Boolean).map((w) => w.replace("\t", ": ")).join("\n");
        // A card (the style of the line card) with the changes, and an
        // editor for each setting that changed: hover, then change it there.
        m.setAttribute("aria-label", `${i === 0 ? "Start" : `Change ${i}`} · ${label}${words ? ". " + words : ""}`);
        m.onmouseenter = () => this.hoverMark(m, i);
        m.onmouseleave = () => this.leaveCard();
        m.onclick = () => this.go(i);
        m.oncontextmenu = (e) => this.menu(e, i);
        marks.append(m);
      }
      parts.push(marks, el("span", "tl-count", `${now} / ${n - 1}`));
      requestAnimationFrame(() => {
        const cur = marks.querySelector(".now");
        if (cur) marks.scrollLeft = cur.offsetLeft - marks.clientWidth / 2;
      });
    }
    bar.replaceChildren(...parts);
    bar.hidden = false;
    bar.onkeydown = (e) => {
      if (!this.list) return;
      if (e.key === "ArrowLeft" && now > 0) this.go(now - 1);
      else if (e.key === "ArrowRight" && now + 1 < n) this.go(now + 1);
      else return;
      e.preventDefault();
    };
  }

  // The card of step i over its bubble `m`, after a short hover.
  hoverMark(m, i) {
    clearTimeout(this.cardHide);
    clearTimeout(this.cardWait);
    if (this.card && this.cardStep === i) return;
    this.cardWait = setTimeout(() => this.showCard(m, i), this.card ? 0 : 350);
  }

  leaveCard() {
    clearTimeout(this.cardWait);
    clearTimeout(this.cardHide);
    // Time to move the pointer from the bubble into the card. A card with
    // the focus in an editor stays.
    this.cardHide = setTimeout(() => {
      if (this.card?.contains(document.activeElement)) return;
      this.closeCard();
    }, 400);
  }

  closeCard() {
    const b = this.ctx.browser;
    if (b) for (const [name, list] of b.editors) b.editors.set(name, list.filter((e) => e.where !== "history"));
    this.card?.remove();
    this.card = null;
    this.cardStep = -1;
  }

  showCard(m, i) {
    this.closeCard();
    const s = this.list?.steps[i];
    if (!s) return;
    const kind = i === 0 ? "start" : (LOOKS[s.kind] ? s.kind : "other");
    const [color, label] = LOOKS[kind];
    const card = el("div", "line-card hist-card");
    card.onmouseenter = () => clearTimeout(this.cardHide);
    card.onmouseleave = () => this.leaveCard();
    card.addEventListener("focusout", () => setTimeout(() => {
      if (this.card === card && !card.contains(document.activeElement) && !card.matches(":hover")) this.closeCard();
    }, 0));
    const head = el("div", "lc-head");
    const dot = el("span", "hist-card-dot");
    dot.style.background = color;
    dot.append(glyph(kind, 14));
    const titles = el("div", "lc-titles");
    titles.append(el("div", "lc-title", i === 0 ? "Start" : `Change ${i}`), el("div", "lc-where", `${label} · ${clock(s.time)}${i === (this.list?.current ?? -1) ? " · now" : ""}`));
    head.append(dot, titles);
    card.append(head);
    if (i === 0) {
      card.append(el("div", "lc-info", "The settings and the plate when the history started."));
    } else {
      const cl = (s.changes ?? "").split("\n");
      const wl = (s.text ?? "").split("\n");
      const lines = el("div", "lc-stats hist-card-lines");
      const box = el("div", "lc-settings");
      const done = new Set();
      for (let k = 0; k < wl.length; k++) {
        const tab = wl[k].indexOf("\t");
        if (tab < 0) continue;
        lines.append(el("div", "lc-line", `${wl[k].slice(0, tab)}: ${wl[k].slice(tab + 1)}`));
        // An editor for a setting of the whole plate: its value now.
        const [scope, key] = (cl[k] ?? "").split("\t");
        const info = this.ctx.browser?.byName.get(key);
        if (!info || done.has(key) || (scope && scope.includes(":"))) continue;
        done.add(key);
        const row = el("div", "lc-row");
        const lb = el("button", "flat lc-label");
        lb.append(el("span", "lc-name", info.label));
        lb.title = `${info.doc}\n\nClick to show this setting in the panel.`;
        lb.onclick = () => this.ctx.openSetting(key);
        const ed = this.ctx.browser.makeEditor(info, "history");
        row.append(lb, ed.node);
        this.ctx.browser.track(key, { where: "history", update: (entry) => ed.update(entry) });
        box.append(row);
      }
      card.append(lines);
      if (box.childElementCount) {
        box.prepend(el("div", "lc-c", "The value now:"));
        card.append(box);
      }
    }
    const foot = el("div", "lc-foot");
    const go = el("button", "flat", i === this.list?.current ? "This is the step now" : "Go to this step");
    go.disabled = i === this.list?.current;
    go.onclick = () => {
      this.closeCard();
      this.go(i);
    };
    foot.append(go);
    card.append(foot);
    document.body.append(card);
    // Over the bubble, and inside the window.
    const r = m.getBoundingClientRect();
    const w = card.offsetWidth;
    card.style.position = "fixed";
    card.style.left = `${Math.max(8, Math.min(window.innerWidth - w - 8, r.left + r.width / 2 - w / 2))}px`;
    card.style.bottom = `${window.innerHeight - r.top + 10}px`;
    this.card = card;
    this.cardStep = i;
  }

  // The right-click menu of step i: go to it, or clear the history after
  // it.
  menu(e, i) {
    e.preventDefault();
    const l = this.list;
    if (!l) return;
    const last = i + 1 >= l.steps.length;
    const name = i === 0 ? "the start" : `change ${i}`;
    openMenuAt(e.clientX, e.clientY, [
      { label: "Go to this change", disabled: i === l.current, action: () => this.go(i) },
      { sep: true },
      {
        label: i < l.current ? `Go to ${name} and clear the history after it` : `Clear the history after ${name}`,
        tip: "The later changes go from the history, and redo cannot bring them back.",
        disabled: last,
        action: () => this.truncate(i),
      },
    ]);
  }

  async truncate(index) {
    const r = await this.ctx.client.call("historyTruncate", { index });
    this.ctx.applySettings(r);
    await this.refresh();
  }

  async go(index) {
    const r = await this.ctx.client.call("historyGoto", { index });
    this.ctx.applySettings(r);
    await this.refresh();
    if (this.ctx.visible()) this.root.querySelector(".hist-now")?.focus();
  }

  key(e) {
    if (!this.list || e.ctrlKey || e.metaKey || e.altKey) return;
    // The list shows the newest first: up is the next step.
    const cur = this.list.current;
    if (e.key === "ArrowUp" && cur + 1 < this.list.steps.length) this.go(cur + 1);
    else if (e.key === "ArrowDown" && cur > 0) this.go(cur - 1);
    else return;
    e.preventDefault();
  }

  render() {
    const root = this.root;
    const box = el("div", "history");
    const l = this.list;
    if (!l || l.steps.length <= 1) {
      box.append(el("div", "dim hist-empty", "No changes yet. Each change of a setting or of the plate shows here, and you can go back to it."));
    } else {
      for (let i = l.steps.length; i-- > 0;) box.append(this.step(i));
    }
    root.replaceChildren(box);
    this.renderEdits();
  }

  // The edits of lines (the segment editor): each with its layer, what it
  // does, a mark when its line is not in the slice now, and ×.
  renderEdits() {
    const edits = this.edits ?? [];
    if (edits.length === 0) return;
    const box = el("div", "hist-edits");
    box.append(el("div", "hist-edits-title", `Line edits (${edits.length})`));
    edits.forEach((e, i) => {
      const row = el("div", "hist-edit");
      const what = e.kind === 0 ? "does not print" : e.kind === 2 ? `a drop of ${e.value.toFixed(1)} mm` : `${Math.round(e.value * 100)} % plastic`;
      const text = el("div", "", `Layer ${e.layer + 1}: ${what}`);
      const state = el("div", e.applied ? "dim" : "hist-edit-wait", e.applied ? "" : "waits: its line is not in this slice");
      const x = el("button", "flat icon", "×");
      x.title = "Remove this edit: the line prints as the slice makes it";
      x.setAttribute("aria-label", `Remove the edit of layer ${e.layer + 1}`);
      x.onclick = async () => {
        await this.ctx.client.call("editRemove", { index: i });
        this.refresh();
      };
      row.append(text, state, x);
      box.append(row);
    });
    this.root.append(box);
  }

  step(i) {
    const l = this.list;
    const s = l.steps[i];
    const now = l.current;
    const row = el("div", "hist-step" + (i === now ? " hist-now" : i > now ? " hist-later" : ""));
    row.tabIndex = -1;
    row.title = i === now ? "The step now" : "Click to go to this step";
    row.onclick = (e) => {
      if (e.target.closest("button")) return;
      if (i !== now) this.go(i);
    };
    row.oncontextmenu = (e) => this.menu(e, i);
    const [color, label] = LOOKS[s.kind] ?? LOOKS.other;
    const head = el("div", "hist-head");
    const badge = el("span", "hist-badge", label);
    badge.style.background = color;
    head.append(badge, el("span", "hist-title", i === 0 ? "Start" : `Change ${i}`), el("span", "dim hist-time", clock(s.time)));
    if (i === now) head.append(el("span", "hist-now-badge", "Now"));
    row.append(head);
    if (i === 0) {
      row.append(el("div", "dim", "The settings and the plate when the history started."));
      return row;
    }
    const cl = s.changes.split("\n");
    const wl = s.text.split("\n");
    let n = 0;
    for (let k = 0; k < wl.length && k < cl.length; k++) {
      const tab = wl[k].indexOf("\t");
      if (tab < 0) continue;
      n++;
      const line = cl[k];
      const change = el("div", "hist-change");
      const words = el("div", "hist-words");
      words.append(el("div", "dim hist-scope", wl[k].slice(0, tab)), el("div", "", wl[k].slice(tab + 1)));
      change.append(words);
      const key = line.split("\t")[1] ?? "";
      if (key.includes(".")) {
        change.title = "Double-click to open this setting.";
        change.ondblclick = () => this.ctx.openSetting(key);
      }
      if (i <= now && revertible(line)) {
        const undo = el("button", "flat icon hist-undo", "↶");
        undo.title = "Undo only this change. The later changes stay.";
        undo.onclick = async () => {
          const r = await this.ctx.client.call("historyRevert", { line });
          this.ctx.applySettings(r);
          if (r.error) this.ctx.toast(r.error);
        };
        change.append(undo);
      }
      row.append(change);
    }
    if (n === 0) row.append(el("div", "dim", "Other changes (formulas, global settings, or the plate)."));
    return row;
  }
}
