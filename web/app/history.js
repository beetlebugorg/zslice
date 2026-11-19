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
// The glyph of a kind, in white, in a box of 20 around the center (the
// same drawing as draw_glyph in linux/src/ui/history.c).
const NS = "http://www.w3.org/2000/svg";
function arrowHead(x, y, ang, s) {
  const a = (t) => `${(x + s * Math.cos(t)).toFixed(2)} ${(y + s * Math.sin(t)).toFixed(2)}`;
  return `M${a(ang + 2.5)}L${x} ${y}L${a(ang - 2.5)}`;
}
function glyphMarkup(k) {
  const line = (d) => `<path d="${d}" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>`;
  const fill = (d) => `<path d="${d}" fill="#fff"/>`;
  switch (k) {
    case "walls": return line("M-5.5 -5.5h11v11h-11zM-2.5 -2.5h5v5h-5z");
    case "infill": {
      let d = "";
      for (const o of [-4.5, 0, 4.5]) d += `M${-6 + o} -6L${6 + o} 6M${6 + o} -6L${-6 + o} 6`;
      return `<clipPath id="ic-clip"><circle r="5.8"/></clipPath><path d="${d}" stroke="#fff" stroke-width="1.3" stroke-linecap="round" clip-path="url(#ic-clip)"/>`;
    }
    case "surface": return line([-1, 0, 1].map((o) => `M${-6 + o * 4} 4L${1 + o * 4} -4`).join(""));
    case "speed": return line("M-5 -4.5L-0.5 0L-5 4.5M0 -4.5L4.5 0L0 4.5");
    case "heat": return line("M0 -6V2M2.5 -4H4M2.5 -1H4") + `<circle cy="3.5" r="2.6" fill="#fff"/>`;
    case "support": return line("M-6 -4.5H6M-4 -4.5V5.5M0 -4.5V5.5M4 -4.5V5.5");
    case "layers": return line("M-5.5 -3.8H5.5M-5.5 0H5.5M-5.5 3.8H5.5");
    case "move": return line("M-6 0H6M0 -6V6" + arrowHead(6, 0, 0, 2.4) + arrowHead(-6, 0, Math.PI, 2.4) + arrowHead(0, 6, Math.PI / 2, 2.4) + arrowHead(0, -6, -Math.PI / 2, 2.4));
    case "rotate": return line("M0 -5A5 5 0 1 1 -5 0" + arrowHead(-5, 0, Math.PI / 2, 2.6));
    case "scale": return line("M-5 5L5 -5M1 -5H5V-1M-5 1V5H-1");
    case "add": return line("M-5 0H5M0 -5V5");
    case "remove": return line("M-5 0H5");
    case "quality": {
      let d = "";
      for (let i = 0; i < 10; i++) {
        const a = -Math.PI / 2 + (i * Math.PI) / 5, r = i % 2 ? 2.6 : 6;
        d += `${i ? "L" : "M"}${(r * Math.cos(a)).toFixed(2)} ${(r * Math.sin(a)).toFixed(2)}`;
      }
      return fill(d + "Z");
    }
    case "printer": return line("M-6 -2h12v6h-12zM-3.5 -6h7v4h-7zM-2 5.5H2");
    case "start": return line("M-3 6V-6L5 -3.5L-3 -1");
    default: return `<circle r="2" fill="#fff"/>`;
  }
}
// An <svg> with the glyph of kind `k`, `size` pixels wide.
export function glyph(k, size) {
  const s = document.createElementNS(NS, "svg");
  s.setAttribute("viewBox", "-10 -10 20 20");
  s.setAttribute("width", size);
  s.setAttribute("height", size);
  s.setAttribute("aria-hidden", "true");
  s.innerHTML = glyphMarkup(k);
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
        m.title = `${i === 0 ? "Start" : `Change ${i}`} · ${label}${words ? "\n" + words : ""}`;
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
