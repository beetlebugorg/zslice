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

// The look of each kind of step (history.c, looks).
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

// A change that can be undone alone (history.c, revertible): not the
// quality, and not a move, turn, or scale of a part.
function revertible(line) {
  if (line.includes("\tquality\t")) return false;
  if (!line.startsWith("part:")) return true;
  const key = line.split("\t")[1] ?? "";
  return !/^(\(part\)|position|rotation|orientation|scale)/.test(key);
}

function clock(ms) {
  const d = new Date(ms);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export class HistoryPage {
  // ctx: { client, applySettings(r), openSetting(name), toast(text),
  //        visible() }
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
    if (!this.ctx.visible()) return;
    const id = ++this.asked;
    const r = await this.ctx.client.call("history", {});
    if (id !== this.asked) return;
    this.list = r;
    this.render();
  }

  async go(index) {
    const r = await this.ctx.client.call("historyGoto", { index });
    this.ctx.applySettings(r);
    await this.refresh();
    this.root.querySelector(".hist-now")?.focus();
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
      root.replaceChildren(box);
      return;
    }
    for (let i = l.steps.length; i-- > 0;) box.append(this.step(i));
    root.replaceChildren(box);
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
