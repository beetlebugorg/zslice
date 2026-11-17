// linecard.js: the card of a selected line, next to it in the view
// (docs/internals/one-view.md). A click on a line opens it at the click.
// It shows what the line is (the feature and the layer), its three
// numbers (the planned speed, the real speed, the flow), why it is slow,
// its size, and the settings that matter for it (why it is slow, the first
// layer, a setting the user changed, the settings of its feature), with
// live editors. A
// change slices at once. "More" opens the Selected page of the panel,
// with all the settings and the reasons.
//
// The card follows the line after a new slice (the inspector finds the
// line again), and closes with Esc, with a click on no line, or with ×.
// A drag of its head moves it, and it keeps that place for the next
// lines until it closes.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { movable } from "./drag.js";

const SLOW = [
  "",
  "Slow: the layer is short, so it prints slower to cool.",
  "Slow: the segments are short, so the head does not reach full speed.",
];
const MAX_SETTINGS = 4;

// The settings that matter most for each feature (FEATURE_TITLES in
// format.js), in order.
const BY_FEATURE = [
  ["project.outer_wall_speed", "project.seam", "project.wall_count", "project.outer_wall_accel"],
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
// that changes the line (in info.settings) or one of the rules here.
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
    head.title = "Drag to move the card";
    movable(card, head, this.ctx.host, (x, y) => {
      this.userAt = [x, y];
    });
    this.stats = el("div", "lc-stats");
    this.note = el("div", "lc-note");
    this.size = el("div", "lc-size");
    card.append(head, this.stats, this.note, this.size);

    // The settings that matter for this line, with the reason of each.
    const picks = contextSettings(info, this.ctx.browser.byName);
    if (picks.length > 0) {
      const box = el("div", "lc-settings");
      for (const { name, why } of picks) {
        const s = this.ctx.browser.byName.get(name);
        const row = el("div", "lc-row");
        const label = el("div", "lc-label");
        label.append(el("div", "lc-name", s.label));
        if (why) label.append(el("div", "lc-why", why));
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

  // Next to the click, inside the view (a card that the user moved stays).
  place() {
    const card = this.node;
    if (this.userAt) {
      [card.style.left, card.style.top] = this.userAt.map((v) => `${v}px`);
      return;
    }
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
