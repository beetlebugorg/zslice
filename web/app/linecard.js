// linecard.js: the Inspector page of a selected line (dock.js,
// docs/internals/one-view.md).
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
// The Filament row gives the line its own filament: a chip colors the
// body of the line on its layer (the lines joined to it, as a drag over
// layers lights them: View.connectedPaths), with the paint of the part
// (zs_app_paint_body). The body shows in the color at once, and the slice
// follows. Then the card offers the layers above and below where the
// body goes on (zs_view_connected_layers).
//
// All the data comes from one call to the worker for each click (inspect:
// zs_app_inspect, its picks, and the cached check). The card does no work
// for each frame.
//
// The card follows the line after a new slice (the inspector finds the
// line again), and closes with Esc, with a click on no line, or with ×.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { FEATURE_TITLES } from "./format.js";
import { filamentEditor } from "./filaments.js";

const SLOW = [
  "",
  "Slow: the layer is short, so it prints slower to cool.",
  "Slow: the segments are short, so the head does not reach full speed.",
];
const MAX_SETTINGS = 5;
// The kinds of the check (checks.zig) that the card shows as a warning:
// flow, cooling, overhang, island, bridge.
const WARN_KINDS = new Set([0, 1, 2, 3, 5]);

// The settings that matter most for each feature (FEATURE_TITLES in
// format.js), in order.
const BY_FEATURE = [
  ["project.outer_wall_speed", "project.wall_count", "machine.outer_wall_accel", "project.seam"],
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
const ACCEL = ["machine.outer_wall_accel", "machine.inner_wall_accel", "machine.skin_accel", "machine.infill_accel"];

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

// Why a line is slow, or "". The foot of the Selected page shows it.
export function slowNote(info) {
  return info.slowText || SLOW[info.slowReason] || "";
}

// The flow limit of a line, or "". The foot of the Selected page shows it.
export function flowNote(info) {
  return info.flowLimited && info.maxFlow > 0 ? `The flow limit (${info.maxFlow.toFixed(0)} mm³/s) sets the speed of this line, not the printer.` : "";
}

export class LineCard {
  // ctx: { browser (SettingsBrowser), host (the slot of the Inspector),
  //        more() (open the Selected page), close() (clear the selection),
  //        openSetting(name) (show the setting in the panel),
  //        paintLine(info, filament) -> Promise<{ error, lo, hi, above,
  //        below }> (the body of the line on its layer, and the layers
  //        where it goes on), extendLine(beads, filament) -> Promise<error
  //        or null>, addFilament() -> Promise<index>, ... }
  constructor(ctx) {
    this.ctx = ctx;
    this.node = null;
    this.signature = "";
  }

  get open() {
    return !!this.node;
  }

  // Opens the card for the next `show`.
  openNext() {
    this.want = true;
  }

  // The state of "Fade the others".
  setIsolate(on) {
    this.fadeButton?.classList.toggle("checked", on);
    this.fadeButton?.setAttribute("aria-pressed", String(on));
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
    close.setAttribute("aria-label", "Clear the selection");
    close.title = "Clear the selection (Esc)";
    close.onclick = () => this.ctx.close();
    head.append(titles, close);
    this.stats = el("div", "lc-stats");
    this.notes = el("div", "lc-notes");
    card.append(head, this.stats, this.notes);
    // The filament of this part of the layer (see the header).
    this.filEditor = null;
    if (this.ctx.paintLine && info.path != null) {
      const box = el("div", "lc-settings lc-filament");
      const row = el("div", "lc-row");
      const label = el("div", "lc-label");
      label.append(el("span", "lc-name", "Filament"), el("span", "lc-why", "This part of the layer"));
      label.title = "A filament for the body of this line on its layer only: the lines joined to it. The paint of the part keeps it.";
      this.filEditor = filamentEditor(
        { name: "line.filament", doc: "A filament for this part of the layer" },
        (v) => this.pickFilament(Number(v)),
        this.ctx.addFilament ?? null,
      );
      row.append(label, this.filEditor.node);
      this.extend = el("div", "lc-extend");
      this.extend.hidden = true;
      box.append(row, this.extend);
      card.append(box);
    }

    // The settings that matter for this line. The picks of the core
    // (zs_app_inspect_picks), else the rules here. Their reasons are at
    // the foot of the Selected page.
    const picks = this.picks(info);
    if (picks.length > 0) {
      const box = el("div", "lc-settings");
      for (const { name } of picks) {
        const s = this.ctx.browser.byName.get(name);
        const row = el("div", "lc-row");
        const label = el("button", "flat lc-label");
        label.append(el("span", "lc-name", s.label));
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
  }

  // A filament for the body of the line on its layer. Then the buttons
  // for the layers above and below where the body goes on.
  async pickFilament(f) {
    const info = this.info;
    if (!info || !this.ctx.paintLine) return "No line.";
    this.extend.hidden = true;
    const r = await this.ctx.paintLine(info, f);
    if (r.error) return r.error;
    const buttons = [];
    const add = (text, title, beads) => {
      if (!beads) return;
      const b = el("button", "flat", text);
      b.title = title;
      b.onclick = async () => {
        b.disabled = true;
        const error = await this.ctx.extendLine(beads, f);
        if (error) b.disabled = false;
        else b.remove();
        if (!this.extend.querySelector("button")) this.extend.hidden = true;
      };
      buttons.push(b);
    };
    add(`Also the layers above, to ${r.hi + 1}`, `The same filament for this body on layers ${info.layer + 2} to ${r.hi + 1}, where it goes on`, r.above);
    add(`Also the layers below, from ${r.lo + 1}`, `The same filament for this body on layers ${r.lo + 1} to ${info.layer}, where it goes on`, r.below);
    this.extend.replaceChildren(...buttons);
    this.extend.hidden = buttons.length === 0;
    return null;
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
    if (this.filEditor && info.filament > 0) this.filEditor.update({ value: info.filament });
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
    // A printer with more than one nozzle: the nozzle of the line (from
    // 1: the main nozzle, then T1 and on).
    if (info.nozzle > 0) line1.append(dot(), part(info.nozzle === 1 ? "main nozzle" : info.nozzle === 2 ? "2nd nozzle" : `nozzle T${info.nozzle - 1}`, false));
    line1.title = "The speed of the line (and the planned speed when it is slower), and its flow (and its share of the most that the hot end melts)";
    const line2 = el("div", "lc-line");
    line2.append(part(`${info.lineWidth.toFixed(2)} × ${info.height.toFixed(2)} mm`, false), dot(), part(`layer ${layerTimeText(info.layerTime)}`, info.slowReason === 1), dot(), part(`fan ${Math.round((info.fan ?? 0) * 100)} %`, false));
    line2.title = "The width and the height of the line, the time of its layer, and the fan";
    this.stats.replaceChildren(line1, line2);
    const notes = [];
    // A nozzle after the first: its speed limits.
    if (info.nozzle >= 2 && info.nozzleText) notes.push(el("div", "lc-info", info.nozzleText));
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
}
