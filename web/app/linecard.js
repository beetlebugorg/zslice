// linecard.js: the card of a selected line (docs/internals/one-view.md).
// A click on a line opens it in a corner of the view, away from the line,
// so it never covers the line or the part around it. It keeps its corner
// from click to click while that corner stays clear of the line.
//
// It shows what helps to decide what to change: what the line is (the
// feature, the layer, and the z), its speed and flow and what slows it
// (the cooling, the flow limit, or short segments), its width and height,
// the time of its layer, the fan, a warning of the check at the line, and
// for support the part line that it holds up. Then the settings that
// matter most for the line, each with a live editor and a jump to the
// setting in the panel. A change slices at once. "All settings" opens the
// Selected page of the panel, with all the settings and the reasons.
//
// All the data comes from one call to the worker for each click (inspect:
// zs_app_inspect, its picks, and the cached check). The card does no work
// for each frame.
//
// The card follows the line after a new slice (the inspector finds the
// line again), and closes with Esc, with a click on no line, or with ×.
// A drag of its head moves it, and it keeps that place for the next
// lines until it closes.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { movable } from "./drag.js";
import { spatial, savedPlace, remember } from "./spatial.js";
import { placeCorner, freeArea, GAP as PLACE_GAP } from "./place.js";
import { FEATURE_TITLES } from "./format.js";

const SLOW = [
  "",
  "Slow: the layer is short, so it prints slower to cool.",
  "Slow: the segments are short, so the head does not reach full speed.",
];
const MAX_SETTINGS = 5;
// The space around the clicked line that the card keeps clear, CSS px.
const CLEAR = 24;
// The kinds of the check (checks.zig) that the card shows as a warning:
// flow, cooling, overhang, island, bridge.
const WARN_KINDS = new Set([0, 1, 2, 3, 5]);

// The settings that matter most for each feature (FEATURE_TITLES in
// format.js), in order.
const BY_FEATURE = [
  ["project.outer_wall_speed", "project.wall_count", "project.outer_wall_accel", "project.seam"],
  ["project.wall_count", "project.inner_wall_speed", "project.wall_thickness", "project.infill_overlap"],
  ["project.top_thickness", "project.bottom_thickness", "project.skin_pattern", "project.skin_speed"],
  ["project.infill_density", "project.infill_pattern", "project.infill_speed", "project.infill_angle"],
  ["project.ironing", "project.ironing_flow", "project.ironing_speed", "project.ironing_spacing"],
  ["project.brim_width", "project.skirt_loops", "project.skirt_distance", "project.skirt_layers"],
  ["project.support", "project.support_style", "project.support_density", "project.support_xy_gap"],
  ["project.support_interface_layers", "project.support_z_gap_layers", "project.support_interface_density", "project.support_xy_gap"],
  ["project.slope_smoothing", "project.slope_smoothing_flow", "project.slope_smoothing_speed", "project.slope_smoothing_max_width"],
  ["project.slope_ironing", "project.slope_ironing_passes", "project.slope_ironing_flow", "project.slope_ironing_speed"],
  ["project.bridge_speed", "project.bridge_flow", "project.bridge_fan", "project.bridges"],
];

// The acceleration setting of each feature, for a line that is slow
// because its segments are short.
const ACCEL = ["project.outer_wall_accel", "project.inner_wall_accel", "project.skin_accel", "project.infill_accel"];

// The settings for the card, from what the line is and what happens to it:
// [{ name, why }]. First the reasons of this line (slow, the first layer,
// a change of the user for these layers), then the settings of its
// feature, then the list of the inspector. Each name must be a setting
// that changes the line (in info.settings) or one of the rules here. The
// core gives the same list (zs_app_inspect_picks); this is the fallback.
export function contextSettings(info, byName, max = MAX_SETTINGS) {
  const changes = new Set(info.settings.split("\n").filter((l) => l && !l.startsWith("# ")));
  const out = [];
  const add = (name, why) => {
    if (out.length >= max || !byName.has(name) || out.some((o) => o.name === name)) return;
    out.push({ name, why });
  };
  if (info.slowReason === 1) {
    add("filament.min_layer_time", "Why it is slow: the layer is short");
    add("filament.fan_speed", "More fan cools a short layer");
  } else if (info.slowReason === 2) {
    add(ACCEL[info.feature] ?? "machine.max_accel", "Why it is slow: short segments");
  }
  if (info.layer === 0) {
    add("project.first_layer_speed", "The first layer");
    add("project.first_layer_height", "The first layer");
  }
  // A setting that the user changed for this print or for these layers:
  // likely the one to tune.
  for (const name of changes) {
    const v = info.values?.[name];
    if (v && (v.over || v.level === 5 || v.level === 6)) add(name, v.over ? "You changed it for some layers" : "You changed it");
  }
  for (const name of BY_FEATURE[info.feature] ?? []) add(name, "");
  for (const name of changes) add(name, "");
  return out;
}

// "6.2 s", "1 min 05 s".
export function layerTimeText(s) {
  if (!(s > 0)) return "–";
  if (s < 60) return `${s.toFixed(1)} s`;
  const r = Math.round(s);
  return `${Math.floor(r / 60)} min ${String(r % 60).padStart(2, "0")} s`;
}

// The notes of a line: why it is slow, and the flow limit. [text].
export function lineNotes(info) {
  const out = [];
  const slow = info.slowText || SLOW[info.slowReason] || "";
  if (slow) out.push(slow);
  if (info.flowLimited && info.maxFlow > 0) {
    out.push(`The flow limit (${info.maxFlow.toFixed(0)} mm³/s) sets the speed of this line, not the printer.`);
  }
  return out;
}

export class LineCard {
  // ctx: { browser (SettingsBrowser), host (the element of the view),
  //        more() (open the Selected page), close() (clear the selection),
  //        openSetting(name) (show the setting in the panel),
  //        lineBox() (the box of the line on the screen), ... }
  constructor(ctx) {
    this.ctx = ctx;
    this.node = null;
    this.at = [0, 0];
    this.signature = "";
    // The corner of the card: it stays from click to click.
    this.corner = null;
  }

  get open() {
    return !!this.node;
  }

  // Opens the card for the next `show`. (x, y): the click, CSS pixels in
  // the view: the card keeps clear of it.
  openAt(x, y) {
    this.at = [x, y];
    this.want = true;
  }

  // The state of "Fade the others".
  setIsolate(on) {
    this.fadeButton?.classList.toggle("checked", on);
    this.fadeButton?.setAttribute("aria-pressed", String(on));
  }

  close() {
    this.userAt = null;
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
    this.info = info;
    if (!info) {
      this.close();
      return;
    }
    if (!this.want) return;
    // A new card for new settings rows: another feature, or other
    // settings. The reasons of the rows change in place: a new card after
    // each slice took the focus from the editor that the user types in
    // (the arrow keys then stopped).
    const sig = `${info.title}\n${info.settings}\n${this.pickNames(info).join("\n")}`;
    if (this.node && sig === this.signature) {
      this.update(info);
      this.place();
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
    this.where = el("div", "lc-where");
    const titles = el("div", "lc-titles");
    titles.append(this.title, this.where);
    const close = el("button", "flat icon lc-close", "×");
    close.setAttribute("aria-label", "Close");
    close.title = "Close (Esc)";
    close.onclick = () => this.ctx.close();
    head.append(titles, close);
    head.title = "Drag to move the card";
    movable(card, head, this.ctx.host, (x, y) => {
      this.userAt = [x, y];
      remember("line-card", { x, y });
    });
    // Its place and size stay for the next card (spatial.js).
    spatial(card, "line-card", head, () => {
      this.userAt = null;
      this.place();
    });
    this.stats = el("div", "lc-stats");
    this.notes = el("div", "lc-notes");
    card.append(head, this.stats, this.notes);

    // The settings that matter for this line, with the reason of each.
    // The picks of the core (zs_app_inspect_picks), else the rules here.
    const picks = this.picks(info);
    this.whys = new Map();
    if (picks.length > 0) {
      const box = el("div", "lc-settings");
      for (const { name, why } of picks) {
        const s = this.ctx.browser.byName.get(name);
        const row = el("div", "lc-row");
        const label = el("button", "flat lc-label");
        label.append(el("span", "lc-name", s.label));
        const whyNode = el("span", "lc-why", why ?? "");
        whyNode.hidden = !why;
        label.append(whyNode);
        this.whys.set(name, whyNode);
        label.title = `${s.doc}\n\nClick to show this setting in the panel.`;
        label.onclick = () => this.ctx.openSetting?.(name);
        const ed = this.ctx.browser.makeEditor(s, "card");
        row.append(label, ed.node);
        this.ctx.browser.track(name, { where: "card", update: (entry) => ed.update(entry) });
        box.append(row);
      }
      card.append(box);
    }
    const foot = el("div", "lc-foot");
    const fade = el("button", "lc-fade", "Fade the others");
    fade.title = "Show this line solid, and the other lines as faint ghosts";
    fade.classList.toggle("checked", !!this.ctx.isolated?.());
    fade.setAttribute("aria-pressed", String(!!this.ctx.isolated?.()));
    fade.onclick = () => this.ctx.isolate?.();
    this.fadeButton = fade;
    foot.append(fade);
    const more = el("button", "flat", "All settings…");
    more.title = "All the settings of this line, and how its values come about (the Selected page)";
    more.onclick = () => this.ctx.more();
    foot.append(more);
    card.append(foot);
    // The segment editor: an edit of this line alone, kept across slices.
    if (this.ctx.edit && info.path != null) {
      const edits = el("div", "lc-foot lc-edits");
      const del = el("button", "flat", "Don't print");
      del.title = "Take this line out of the print (Delete). The edit stays, and applies again to a new slice that makes the same line.";
      del.onclick = () => this.ctx.edit(info, 0, 1);
      const less = el("button", "flat", "−10 % plastic");
      less.title = "This line with 10 % less plastic";
      less.onclick = () => this.ctx.edit(info, 1, 0.9);
      const moreP = el("button", "flat", "+10 % plastic");
      moreP.title = "This line with 10 % more plastic, for a gap";
      moreP.onclick = () => this.ctx.edit(info, 1, 1.1);
      edits.append(del, less, moreP);
      card.append(edits);
    }
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

  // The settings rows of a line: the picks of the core, else the rules
  // here.
  picks(info) {
    return info.picks?.length ? info.picks.filter((p) => this.ctx.browser.byName.has(p.name)).slice(0, MAX_SETTINGS) : contextSettings(info, this.ctx.browser.byName);
  }

  pickNames(info) {
    return this.picks(info).map((p) => p.name);
  }

  update(info) {
    this.title.textContent = info.title;
    for (const { name, why } of this.picks(info)) {
      const n = this.whys?.get(name);
      if (!n) continue;
      n.textContent = why ?? "";
      n.hidden = !why;
    }
    this.where.textContent = `Layer ${info.layer + 1} · z ${info.z.toFixed(2)} mm`;
    const slow = info.slowReason !== 0;
    const flowUse = info.maxFlow > 0 ? Math.round((info.flow / info.maxFlow) * 100) : 0;
    // Two short lines: the speed and the flow, then the line and its
    // layer. The room goes to the settings. [text, a warning].
    const part = (text, warn) => el("span", "lc-v" + (warn ? " warning" : ""), text);
    const dot = () => el("span", "lc-c", " · ");
    const speed = slow ? `${info.speed.toFixed(0)} of ${info.plannedSpeed.toFixed(0)} mm/s` : `${info.speed.toFixed(0)} mm/s`;
    const flow = `${info.flow.toFixed(1)} mm³/s` + (info.maxFlow > 0 ? ` (${flowUse} %)` : "");
    const line1 = el("div", "lc-line");
    line1.append(part(speed, slow), dot(), part(flow, flowUse >= 95));
    line1.title = "The speed of the line (and the planned speed when it is slower), and its flow (and its share of the most that the hot end melts)";
    const line2 = el("div", "lc-line");
    line2.append(part(`${info.lineWidth.toFixed(2)} × ${info.height.toFixed(2)} mm`, false), dot(), part(`layer ${layerTimeText(info.layerTime)}`, info.slowReason === 1), dot(), part(`fan ${Math.round((info.fan ?? 0) * 100)} %`, false));
    line2.title = "The width and the height of the line, the time of its layer, and the fan";
    this.stats.replaceChildren(line1, line2);
    const notes = lineNotes(info).map((t) => el("div", "lc-note", t));
    // What a support line holds up.
    if (info.holds) {
      const f = FEATURE_TITLES[info.holds.feature] ?? "Part";
      const up = info.holds.layer - info.layer;
      notes.push(el("div", "lc-info", `Holds up: ${f.toLowerCase()} on layer ${info.holds.layer + 1}, ${up} ${up === 1 ? "layer" : "layers"} up.`));
    } else if (info.feature === 6 || info.feature === 7) {
      notes.push(el("div", "lc-info", "Holds up: no part line over it on the next layers."));
    }
    // The warnings of the check at this line (a bridge, an overhang).
    const seen = new Set();
    for (const is of info.issues ?? []) {
      if (is.severity < 1 || !WARN_KINDS.has(is.kind) || seen.has(is.kind) || seen.size >= 2) continue;
      seen.add(is.kind);
      notes.push(el("div", "lc-note lc-check", `⚠ ${is.text}`));
    }
    this.notes.replaceChildren(...notes);
    this.notes.hidden = notes.length === 0;
  }

  // In a corner of the view, clear of the line (a card that the user
  // moved stays).
  place() {
    const card = this.node;
    if (!card) return;
    if (this.userAt) {
      [card.style.left, card.style.top] = this.userAt.map((v) => `${v}px`);
      return;
    }
    // The box of the whole line that the user clicked, the click, and some
    // room around them: the card covers no part of it.
    const box = this.ctx.lineBox?.() ?? [this.at[0], this.at[1], this.at[0], this.at[1]];
    box[0] = Math.min(box[0], this.at[0]) - CLEAR;
    box[1] = Math.min(box[1], this.at[1]) - CLEAR;
    box[2] = Math.max(box[2], this.at[0]) + CLEAR;
    box[3] = Math.max(box[3], this.at[1]) + CLEAR;
    // The place where the user put the card before, if it is clear of the
    // line.
    const kept = savedPlace("line-card", card, this.ctx.host, box);
    if (kept) {
      card.style.left = `${kept[0]}px`;
      card.style.top = `${kept[1]}px`;
      return;
    }
    const area = freeArea(this.ctx.host);
    card.style.maxHeight = "";
    let [x, y, corner, over] = placeCorner(box, area, card.offsetWidth, card.offsetHeight, this.corner);
    if (over > 0) {
      // A narrow or short view: no corner is clear of the line. The card
      // gets shorter, and scrolls, to fit above or below the line.
      const room = Math.max(box[1] - area[1], area[3] - box[3]) - PLACE_GAP - 1;
      if (room >= 120) {
        card.style.maxHeight = `${room}px`;
        [x, y, corner] = placeCorner(box, area, card.offsetWidth, card.offsetHeight, this.corner);
      }
    }
    this.corner = corner;
    card.style.left = `${x}px`;
    card.style.top = `${y}px`;
  }
}
