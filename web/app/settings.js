// settings.js: the Settings page of the panel
// (linux/src/ui/settings-browser.c). It has three columns, one at a time:
// the sections, the settings of a section with an editor in each row, and
// the detail page of one setting. All of it comes from the setting infos of
// the core (zs_setting_get_info); the shell lists no setting.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import {
  ALL_FEATURES, FEATURE_COLORS, FEATURE_COUNT, FEATURE_TITLES, GROUP_TITLES,
  displayValue, formatNumber, isNumber, isRatio, parsesAsNumber, sourceText, toCore, valueWithUnit,
} from "./format.js";
import { filamentEditor } from "./filaments.js";

const GROUP_ORDER = ["project", "filament", "machine", "engine"];
const LIVE_DELAY_MS = 450;

// The badge of a printer or a filament setting (null for a print setting):
// "Printer · Bambu Lab X2D". setOwner fills in the name.
function ownerBadge(info) {
  if (info.group !== "machine" && info.group !== "filament") return null;
  const b = el("span", `owner ${info.group}`);
  b.title = info.group === "machine"
    ? "A printer setting: each printer has its own value, and it changes when you change the printer."
    : "A filament setting: each filament has its own value, and it changes when you change the filament.";
  return b;
}

function setOwner(b, info, values) {
  const who = info.group === "machine" ? values?.["machine.name"]?.value : values?.["filament.name"]?.value;
  b.textContent = `${info.group === "machine" ? "Printer" : "Filament"}${who ? ` · ${who}` : ""}`;
}

// The help of a setting: the text in `backticks` in a code font, the rest
// as text (no HTML from the help).
function docText(text) {
  const box = el("div", "doc");
  const parts = text.split("`");
  parts.forEach((part, k) => {
    if (part === "") return;
    if (k % 2 === 1) box.append(el("code", "", part));
    else box.append(document.createTextNode(part));
  });
  return box;
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

export { el };

// The variables of the start and the end G-code (machine.start_gcode):
// the names of zslice. The names of Cura, PrusaSlicer, OrcaSlicer, and
// Bambu Studio work too (src/gcode_vars.zig).
const GCODE_VARS = ["nozzle_temp", "first_layer_nozzle_temp", "bed_temp", "standby_temp", "layer_height", "first_layer_height", "first_layer_speed", "nozzle_diameter", "filament_diameter", "filament_name", "machine_name", "job_name"];

// The Speed section: one place for the options that change the time of a
// slice (src/app/speed.zig), with the Faster slicing switch at the top.
const SPEED = "speed";
const SPEED_STATES = { off: "Off: the exact slice", on: "On", custom: "Custom: some options differ" };

export class SettingsBrowser {
  // ctx: { infos, effect(name), set(name, value) -> Promise<error text>,
  //        reset(name), focus(mask, firstLayerOnly),
  //        speed: { options, note, set(on) } (the Speed section) }
  constructor(ctx) {
    this.ctx = ctx;
    this.infos = ctx.infos;
    this.byName = new Map(this.infos.map((i) => [i.name, i]));
    this.speedOptions = (ctx.speed?.options ?? []).filter((o) => this.byName.has(o.name));
    this.speedNames = new Set(this.speedOptions.map((o) => o.name));
    this.speedState = "off";
    this.speedEditors = [];
    this.values = {};
    this.quality = "";
    this.featureStats = null;
    this.column = 0;
    this.group = null;
    this.section = null;
    this.feature = -1;
    this.search = "";
    this.key = null;
    // The live editors: name -> [{ update(entry) }].
    this.editors = new Map();
    this.cols = [
      document.getElementById("col-sections"),
      document.getElementById("col-settings"),
      document.getElementById("col-detail"),
    ];
    this.crumbs = document.getElementById("crumbs");
    document.getElementById("crumb-back").onclick = () => this.back();
    const search = document.getElementById("search");
    search.addEventListener("input", () => this.onSearch(search.value));
    this.searchEntry = search;
    this.fillSections();
    // The first section is selected at the start, as in the GTK shell.
    const first = this.infos.find((i) => i.group === "project");
    if (first) this.selectSection(first.group, first.section, false);
    this.showColumn(0);
  }

  // ---- data from the worker ----

  setValues(snapshot) {
    const before = this.nozzleCount();
    this.values = snapshot.values;
    this.quality = snapshot.quality;
    this.speedState = snapshot.speed ?? "off";
    for (const ed of this.speedEditors) ed(this.speedState);
    // The section of each nozzle after the first comes and goes with the
    // number of nozzles.
    if (before !== this.nozzleCount()) {
      this.fillSections();
      for (const r of this.sectionRows) r.classList.toggle("selected", r.dataset.group === this.group && r.dataset.section === this.section);
    }
    for (const [name, list] of this.editors) {
      for (const ed of list) ed.update(this.values[name]);
    }
  }

  setFeatureStats(stats) {
    this.featureStats = stats;
    if (this.column === 2 && this.key) this.fillEffect();
  }

  // ---- navigation ----

  showColumn(c) {
    this.column = c;
    this.cols.forEach((col, i) => { col.hidden = i !== c; });
    this.updateCrumbs();
    this.sendFocus();
  }

  back() {
    if (this.column > 0) this.showColumn(this.column - 1);
  }

  updateCrumbs() {
    const c = this.crumbs;
    c.replaceChildren();
    const add = (text, column) => {
      if (c.childElementCount > 0) c.append(el("span", "sep", "›"));
      const b = el("button", column === this.column ? "here" : "", text);
      b.onclick = () => this.showColumn(column);
      c.append(b);
    };
    add("Settings", 0);
    if (this.column >= 1) {
      if (this.search) add(`Search: ${this.search}`, 1);
      else if (this.feature >= 0) add(FEATURE_TITLES[this.feature], 1);
      else if (this.group === SPEED) add("Speed", 1);
      else if (this.group) add(`${GROUP_TITLES[this.group] ?? this.group} · ${this.section || "General"}`, 1);
    }
    if (this.column >= 2 && this.key) add(this.byName.get(this.key)?.label ?? this.key, 2);
    document.getElementById("crumb-back").disabled = this.column === 0;
  }

  // The focus of the previews: the lines that the selection changes.
  sendFocus() {
    let mask = 0;
    let first = false;
    if (this.column === 2 && this.key) {
      const e = this.ctx.effect(this.key);
      mask = e.features || ALL_FEATURES;
      first = e.firstLayerOnly;
    } else if (this.column === 1 && this.feature >= 0) {
      mask = 1 << this.feature;
    } else if (this.group) {
      mask = this.sectionFocus(this.group, this.section);
    }
    this.ctx.focus(mask, first);
  }

  sectionFocus(group, section) {
    let mask = 0;
    for (const i of this.infos) {
      const here = group === SPEED ? this.speedNames.has(i.name) : i.group === group && i.section === section;
      if (here) mask |= this.ctx.effect(i.name).features;
    }
    return mask || ALL_FEATURES;
  }

  // ---- column 1: the sections ----

  // The number of nozzles of the printer (machine.nozzles).
  nozzleCount() {
    return Number(this.values["machine.nozzles"]?.value ?? 1) || 1;
  }

  // A setting that the printer has: the settings of nozzle k (its
  // section, "Second nozzle (T1)" and on) only on a printer with more
  // than k nozzles.
  hasSection(info) {
    return !info.nozzle || info.nozzle < this.nozzleCount();
  }

  fillSections() {
    const col = this.cols[0];
    col.replaceChildren();
    this.sectionRows = [];
    if (this.speedOptions.length) {
      col.append(el("div", "group-title", "Slicing"));
      col.append(this.sectionRow(SPEED, "Speed", "Speed"));
    }
    for (const g of GROUP_ORDER) {
      const seen = new Set();
      for (const i of this.infos) {
        if (i.group !== g || seen.has(i.section) || !this.hasSection(i)) continue;
        if (seen.size === 0) col.append(el("div", "group-title", GROUP_TITLES[g] ?? g));
        seen.add(i.section);
        col.append(this.sectionRow(g, i.section, i.section || "General"));
      }
    }
  }

  sectionRow(g, section, title) {
    const row = el("div", "row");
    row.tabIndex = 0;
    row.append(el("div", "label", title), el("span", "chevron"));
    row.onclick = () => this.selectSection(g, section, true);
    row.onkeydown = (e) => {
      if (e.key === "Enter" || e.key === "ArrowRight") this.selectSection(g, section, true);
    };
    row.onmouseenter = () => {
      if (this.column === 0) this.ctx.focus(this.sectionFocus(g, section), false);
    };
    row.onmouseleave = () => { if (this.column === 0) this.sendFocus(); };
    row.dataset.group = g;
    row.dataset.section = section;
    this.sectionRows.push(row);
    return row;
  }

  // The Speed section: the Faster slicing switch, then each option with
  // its gain and its cost.
  fillSpeed() {
    const col = this.cols[1];
    for (const [name, list] of this.editors) this.editors.set(name, list.filter((e) => e.where !== "row"));
    this.speedEditors = [];
    col.replaceChildren();
    const master = el("div", "row setting-row speed-master");
    const label = el("div", "label");
    const name = el("div", "name", "Faster slicing");
    name.title = this.ctx.speed.note;
    const tag = el("div", "tag");
    label.append(name, tag, el("div", "speed-note", this.ctx.speed.note));
    const box = el("div", "editor");
    const sw = el("button", "switch");
    sw.id = "speed-switch";
    sw.setAttribute("role", "switch");
    sw.title = this.ctx.speed.note;
    sw.onclick = (e) => {
      e.stopPropagation();
      // Custom goes to on: the faster values of all options.
      this.ctx.speed.set(this.speedState !== "on");
    };
    box.append(sw);
    master.append(label, box);
    col.append(master);
    const update = (state) => {
      sw.classList.toggle("on", state === "on");
      sw.classList.toggle("custom", state === "custom");
      sw.setAttribute("aria-checked", state === "on" ? "true" : state === "custom" ? "mixed" : "false");
      tag.textContent = SPEED_STATES[state] ?? "";
      tag.classList.toggle("mine", state !== "off");
    };
    update(this.speedState);
    this.speedEditors.push(update);
    for (const o of this.speedOptions) {
      const row = this.settingRow(this.byName.get(o.name), false);
      const note = el("div", "speed-note", o.note);
      if (o.gcode) note.append(el("span", "gcode-mark", "Changes the G-code"));
      const info = this.byName.get(o.name);
      const faster = info.kind === "boolean" ? (o.faster === "true" ? "on" : "off") : displayValue(info, o.faster);
      if (o.faster) note.append(el("span", "gcode-mark", `Faster slicing: ${faster}`));
      row.querySelector(".label").append(note);
      col.append(row);
    }
  }

  selectSection(group, section, open) {
    this.group = group;
    this.section = section;
    this.feature = -1;
    if (this.search) {
      this.search = "";
      this.searchEntry.value = "";
    }
    for (const r of this.sectionRows) r.classList.toggle("selected", r.dataset.group === group && r.dataset.section === section);
    if (group === SPEED) this.fillSpeed();
    else this.fillSettings((i) => i.group === group && i.section === section, false);
    if (open) this.showColumn(1);
    else this.sendFocus();
  }

  onSearch(text) {
    this.search = text.trim();
    this.feature = -1;
    if (this.search) {
      const needle = this.search.toLowerCase();
      this.fillSettings((i) => this.hasSection(i) && (i.label.toLowerCase().includes(needle) || i.doc.toLowerCase().includes(needle) || i.name.includes(needle)), true);
      this.showColumn(1);
    } else if (this.group) {
      this.selectSection(this.group, this.section, false);
      this.showColumn(0);
    }
  }

  // Opens the Speed section.
  showSpeed() {
    if (this.speedOptions.length) this.selectSection(SPEED, "Speed", true);
  }

  // Column 2 lists the settings that change the lines of feature f: not
  // the settings that change all lines, because they are in each list.
  showFeature(f) {
    this.feature = f;
    this.search = "";
    this.searchEntry.value = "";
    this.fillSettings((i) => {
      const e = this.ctx.effect(i.name).features;
      return ((e >> f) & 1) !== 0 && (e & ALL_FEATURES) !== ALL_FEATURES;
    }, true);
    this.showColumn(1);
  }

  // ---- column 2: the settings ----

  fillSettings(filter, withSection) {
    const col = this.cols[1];
    for (const [name, list] of this.editors) this.editors.set(name, list.filter((e) => e.where !== "row"));
    col.replaceChildren();
    const shown = this.infos.filter(filter);
    // A list of one printer or filament section: one banner that says
    // whose settings they are. A mixed list (a search): a badge on each.
    const groups = new Set(shown.map((i) => i.group));
    const one = groups.size === 1 && !withSection ? [...groups][0] : null;
    if (one === "machine" || one === "filament") {
      const owner = ownerBadge(shown[0]);
      setOwner(owner, shown[0], this.values);
      const note = el("div", "owner-note banner");
      note.append(owner, document.createTextNode(one === "machine"
        ? " Each printer keeps its own values here. They change when you change the printer."
        : " Each filament keeps its own values here. They change when you change the filament."));
      col.append(note);
    }
    for (const info of shown) col.append(this.settingRow(info, withSection || !one));
    if (!col.childElementCount) col.append(el("div", "note", "No setting matches."));
  }

  settingRow(info, withSection) {
    const row = el("div", "row setting-row");
    row.tabIndex = 0;
    if (info.name === this.key) row.classList.add("selected");
    const label = el("div", "label");
    const name = el("div", "name", info.label);
    name.title = info.doc;
    const tag = el("div", "tag");
    // Whose setting it is: a printer setting changes with the printer, a
    // filament setting with the filament. A print setting has no badge.
    const owner = withSection ? ownerBadge(info) : null;
    if (owner) name.append(owner);
    label.append(name, tag);
    const editor = this.makeEditor(info, "row");
    row.append(label, editor.node, el("span", "chevron"));
    const open = () => this.openSetting(info.name);
    row.addEventListener("click", (e) => {
      if (e.target.closest("input, select, .switch")) return;
      open();
    });
    row.onkeydown = (e) => {
      if ((e.key === "Enter" || e.key === "ArrowRight") && e.target === row) open();
      if (e.key === "ArrowLeft" && e.target === row) this.back();
    };
    row.onmouseenter = () => {
      if (this.column !== 1) return;
      const fx = this.ctx.effect(info.name);
      this.ctx.focus(fx.features || ALL_FEATURES, fx.firstLayerOnly);
    };
    row.onmouseleave = () => { if (this.column === 1) this.sendFocus(); };
    this.track(info.name, {
      where: "row",
      update: (entry) => {
        editor.update(entry);
        if (owner) setOwner(owner, info, this.values);
        const t = sourceText(entry);
        tag.textContent = withSection ? `${GROUP_TITLES[info.group]} · ${info.section}${t ? ` · ${t}` : ""}` : t;
        tag.hidden = !tag.textContent;
        tag.classList.toggle("mine", entry?.level === 5 || entry?.level === 6);
      },
    });
    return row;
  }

  track(name, ed) {
    if (!this.editors.has(name)) this.editors.set(name, []);
    this.editors.get(name).push(ed);
    ed.update(this.values[name]);
  }

  // An editor for a setting: a number entry with its unit, a switch, a
  // list of choices, or a text entry. Returns { node, update(entry) }.
  // set(name, value): the change (default: for this print).
  makeEditor(info, where, set = this.ctx.set) {
    const box = el("div", "editor");
    // The history keeps the edits of one setting in one step while its
    // editor has the focus (app.js, historyFocus).
    box.dataset.setting = info.name;
    const commit = async (value, input) => {
      const error = await set(info.name, value);
      if (input) {
        input.classList.toggle("error", !!error);
        input.title = error || info.doc;
      }
      return error;
    };
    // The filament of a part or of layers: a chip for each filament of
    // the plate (filaments.js).
    if (info.name === "project.filament") return filamentEditor(info, (v) => commit(v), this.ctx.addFilament ?? null);
    if (info.name === "project.support_filament" || info.name === "project.infill_filament") return filamentEditor(info, (v) => commit(v), this.ctx.addFilament ?? null, "Part");
    if (info.name === "project.support_interface_filament") return filamentEditor(info, (v) => commit(v), this.ctx.addFilament ?? null, "Support");
    if (info.kind === "boolean") {
      const sw = el("button", "switch");
      sw.setAttribute("role", "switch");
      sw.title = info.doc;
      sw.onclick = (e) => {
        e.stopPropagation();
        const on = !sw.classList.contains("on");
        sw.classList.toggle("on", on);
        commit(on ? "true" : "false");
      };
      box.append(sw);
      return {
        node: box,
        update: (entry) => {
          const on = entry?.value === "true";
          sw.classList.toggle("on", on);
          sw.setAttribute("aria-checked", String(on));
        },
      };
    }
    if (info.kind === "choice") {
      const sel = el("select", "choice");
      sel.title = info.doc;
      for (const c of info.choices) sel.append(new Option(c, c));
      sel.onchange = () => commit(sel.value);
      box.append(sel);
      return { node: box, update: (entry) => { if (entry && document.activeElement !== sel) sel.value = entry.value; } };
    }
    if (info.kind === "text" && info.multiline && where === "row") {
      const t = el("span", "dim");
      t.style.maxWidth = "170px";
      t.style.overflow = "hidden";
      t.style.textOverflow = "ellipsis";
      t.style.whiteSpace = "nowrap";
      box.append(t);
      return { node: box, update: (entry) => { t.textContent = entry ? displayValue(info, entry.value) : ""; } };
    }
    if (info.kind === "text" && info.multiline) {
      const ta = el("textarea", "text");
      ta.rows = 8;
      ta.style.width = "100%";
      ta.style.fontFamily = "monospace";
      ta.style.background = "var(--entry)";
      ta.style.border = "none";
      ta.style.borderRadius = "6px";
      ta.style.padding = "6px";
      ta.onchange = () => commit(ta.value, ta);
      box.style.flex = "1";
      box.append(ta);
      // The start and the end G-code: the variables to insert, and the
      // result with the values of this print.
      if (/_gcode$/.test(info.name)) {
        box.style.flexDirection = "column";
        box.style.alignItems = "stretch";
        const vars = el("div", "gcode-vars");
        vars.append(el("span", "dim", "Insert:"));
        for (const v of GCODE_VARS) {
          const b = el("button", "chip", `{${v}}`);
          b.type = "button";
          b.title = `Insert {${v}} at the cursor`;
          b.onclick = () => {
            const at = ta.selectionStart ?? ta.value.length;
            ta.value = ta.value.slice(0, at) + `{${v}}` + ta.value.slice(ta.selectionEnd ?? at);
            ta.focus();
            ta.selectionStart = ta.selectionEnd = at + v.length + 2;
            commit(ta.value, ta);
          };
          vars.append(b);
        }
        const show = el("button", "flat", "Show the result");
        show.type = "button";
        show.title = "The start of the G-code of the last slice, with the values of the variables";
        const out = el("pre", "gcode-result");
        out.hidden = true;
        show.onclick = async () => {
          if (!out.hidden) {
            out.hidden = true;
            return;
          }
          const text = (await this.ctx.gcodeHead?.(info.name)) ?? "";
          out.textContent = text || "Slice first: the result comes from the G-code of the last slice.";
          out.hidden = false;
        };
        box.append(vars, show, out);
      }
      return { node: box, update: (entry) => { if (entry && document.activeElement !== ta) ta.value = entry.value; } };
    }
    const input = el("input", isNumber(info) ? "num" : "text");
    input.type = "text";
    input.spellcheck = false;
    input.title = info.doc;
    let timer = 0;
    let sent = null;
    let shown = null;
    const send = () => {
      clearTimeout(timer);
      const v = toCore(info, input.value);
      if (v === sent) return;
      sent = v;
      commit(v, input);
    };
    input.addEventListener("input", () => {
      clearTimeout(timer);
      // Live: a number goes to the core after a pause in the typing.
      if (isNumber(info) && parsesAsNumber(input.value)) timer = setTimeout(send, LIVE_DELAY_MS);
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") send();
      if (e.key === "Escape") { input.value = displayValue(info, shown ?? ""); input.blur(); }
      if (isNumber(info) && (e.key === "ArrowUp" || e.key === "ArrowDown") && parsesAsNumber(input.value)) {
        e.preventDefault();
        const k = isRatio(info) ? 100 : 1;
        const step = (info.sliderStep > 0 ? info.sliderStep : (info.kind === "integer" ? 1 : 0.1)) * k;
        input.value = formatNumber(Number(input.value) + (e.key === "ArrowUp" ? step : -step));
        send();
      }
    });
    input.addEventListener("change", send);
    input.addEventListener("click", (e) => e.stopPropagation());
    box.append(input);
    if (info.unit) box.append(el("span", "unit", info.unit));
    // A speed ratio: the speed in mm/s it gives on this printer.
    const mmS = el("span", "unit speed-hint");
    mmS.hidden = true;
    mmS.title = "The speed of this ratio on this printer, for a line of the line width at the layer height (the flow limit can make it lower).";
    box.append(mmS);
    return {
      node: box,
      update: (entry) => {
        if (!entry) return;
        mmS.hidden = !(entry.speed > 0);
        if (entry.speed > 0) mmS.textContent = `≈ ${Math.round(entry.speed)} mm/s`;
        sent = entry.value;
        shown = entry.value;
        if (document.activeElement !== input) {
          input.value = displayValue(info, entry.value);
          input.classList.remove("error");
        }
        // A value out of the usual range is valid, but unusual.
        const v = Number(entry.value);
        const unusual = isNumber(info) && info.sliderMax > info.sliderMin && parsesAsNumber(entry.value) &&
          (v < info.sliderMin - 1e-9 || v > info.sliderMax + 1e-9);
        input.classList.toggle("unusual", unusual);
      },
    };
  }

  // ---- column 3: the detail page ----

  openSetting(name) {
    this.key = name;
    // The path names the section of this setting, and no search.
    const info = this.byName.get(name);
    if (info) {
      this.group = info.group;
      this.section = info.section;
      this.feature = -1;
      this.search = "";
    }
    for (const r of this.cols[1].querySelectorAll(".row.selected")) r.classList.remove("selected");
    this.fillDetail();
    this.showColumn(2);
  }

  fillDetail() {
    const col = this.cols[2];
    for (const [name, list] of this.editors) this.editors.set(name, list.filter((e) => e.where !== "detail"));
    col.replaceChildren();
    const info = this.byName.get(this.key);
    if (!info) return;
    col.append(el("h3", "", info.label));
    col.append(el("div", "path", `${GROUP_TITLES[info.group] ?? info.group} › ${info.section || "General"}`));
    // A setting of the printer or the filament: say so, with the name.
    const owner = ownerBadge(info);
    if (owner) {
      setOwner(owner, info, this.values);
      const note = el("div", "owner-note");
      note.append(owner, document.createTextNode(info.group === "machine"
        ? " Each printer has its own value. It changes when you change the printer."
        : " Each filament has its own value. It changes when you change the filament."));
      col.append(note);
    }
    const line = el("div", "edit-line");
    line.append(el("div", "name", info.label));
    const editor = this.makeEditor(info, "detail");
    line.append(editor.node);
    col.append(line);

    // A slider for the usual values.
    let slider = null;
    if (isNumber(info) && info.sliderMax > info.sliderMin) {
      slider = el("input", "slider");
      slider.type = "range";
      slider.dataset.setting = info.name;
      const k = isRatio(info) ? 100 : 1;
      slider.min = String(info.sliderMin * k);
      slider.max = String(info.sliderMax * k);
      slider.step = String((info.sliderStep > 0 ? info.sliderStep : (info.kind === "integer" ? 1 : (info.sliderMax - info.sliderMin) / 100)) * k);
      let t = 0;
      slider.oninput = () => {
        clearTimeout(t);
        t = setTimeout(() => this.ctx.set(info.name, toCore(info, slider.value)), 120);
      };
      col.append(slider);
    }

    // The formula of a number.
    let formula = null;
    if (isNumber(info)) {
      const row = el("div", "formula");
      row.append(el("span", "name", "Formula"));
      formula = el("input", "text");
      formula.placeholder = "= {line_width} * 2";
      formula.spellcheck = false;
      formula.title = "A formula of other settings, for example {line_width} * 2. Empty: a plain value.";
      formula.onkeydown = async (e) => {
        if (e.key !== "Enter") return;
        const t = formula.value.trim();
        const v = t === "" ? (this.values[info.name]?.value ?? "") : (t.startsWith("=") ? t : `= ${t}`);
        const err = await this.ctx.set(info.name, v);
        formula.classList.toggle("error", !!err);
      };
      row.append(formula);
      col.append(row);
    }

    // Where the value comes from, and Reset.
    const def = el("div", "default");
    const defText = el("div", "text");
    const reset = el("button", "", "Reset");
    reset.onclick = () => this.ctx.reset(info.name);
    def.append(defText, reset);
    col.append(def);

    col.append(docText(info.docSource ?? info.doc));
    col.append(el("h4", "", "In your project"));
    this.effectBox = el("div", "");
    col.append(this.effectBox);
    this.fillEffect();

    this.track(info.name, {
      where: "detail",
      update: (entry) => {
        editor.update(entry);
        if (!entry) return;
        if (slider && document.activeElement !== slider && parsesAsNumber(entry.value)) {
          slider.value = String(Number(entry.value) * (isRatio(info) ? 100 : 1));
        }
        if (formula && document.activeElement !== formula) formula.value = entry.formula !== null ? `= ${entry.formula}` : "";
        const defv = valueWithUnit(info, info.defaultValue);
        const mine = entry.level === 5 || entry.level === 6;
        let text;
        if (entry.level === 5) {
          text = `Changed for this print. Reset gives ${valueWithUnit(info, entry.base)} (from ${this.quality || "the default"}).`;
        } else {
          const src = sourceText(entry);
          text = src ? `From ${src}. Default: ${defv}` : `The default (${defv})`;
        }
        defText.textContent = text;
        reset.style.visibility = mine ? "visible" : "hidden";
      },
    });
  }

  // What the setting changes: the lines of each feature, with their time.
  fillEffect() {
    const box = this.effectBox;
    if (!box || !this.key) return;
    box.replaceChildren();
    const e = this.ctx.effect(this.key);
    if (e.features === 0) {
      box.append(el("div", "dim", `${e.note || "It changes no line."} The preview shows all lines, in their feature colors.`));
      return;
    }
    const stats = this.featureStats;
    const total = stats ? stats.reduce((s, f) => s + f.timeS, 0) : 0;
    box.append(el("div", "", e.firstLayerOnly ? "It changes these lines on the first layer:" : "It changes these lines:"));
    let shown = 0;
    for (let f = 0; f < FEATURE_TITLES.length; f++) {
      if (!((e.features >>> f) & 1)) continue;
      if (f < FEATURE_COUNT && stats && stats[f].paths === 0) continue;
      const row = el("div", "feature-row row");
      row.style.paddingLeft = "10px";
      const dot = el("span", "dot", "●");
      dot.style.color = FEATURE_COLORS[f];
      row.append(dot, el("span", "what", FEATURE_TITLES[f]));
      if (f < FEATURE_COUNT && stats && total > 0 && !e.firstLayerOnly) {
        row.append(el("span", "stat", `${Math.round(stats[f].timeS / 60)} min · ${Math.round((100 * stats[f].timeS) / total)} %`));
      }
      row.title = `Show all settings that change the ${FEATURE_TITLES[f]} lines`;
      row.onclick = () => this.showFeature(f);
      box.append(row);
      shown++;
    }
    if (shown === 0) box.append(el("div", "dim", "This part has none of these lines now."));
    else box.append(el("div", "note", "The preview shows these lines, and the other lines fade."));
  }
}
