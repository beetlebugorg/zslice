// filaments.js: the filaments of the plate (src/app/filament_slots.zig).
//
// - `filamentEditor`: the editor of the setting project.filament, a row
//   of color chips, one for each filament of the plate. The card of a
//   range of layers (rangecard.js) and the part card (partcard.js) use it
//   through SettingsBrowser.makeEditor. A click on a chip prints the
//   layers or the part with that filament.
// - `FilamentList`: the list on the print card: each filament with its
//   color, its material, and its grams in the last slice, the number of
//   filament changes, and "+ Add a filament". A click on a color picks a
//   new color; × removes the filament.
//
// The list comes from the worker: with each slice ("sliced", `filaments`
// and `filamentStats`), and after each change of the list. `setFilaments`
// keeps it here, and each editor and list that shows updates.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const state = {
  list: [{ index: 0, name: "", material: "PLA", color: "#d0d0cc", nozzleTemp: 0 }],
  stats: null,
  views: new Set(),
};

// The filaments: [{ index, name, material, color, nozzleTemp }].
export function filaments() {
  return state.list;
}

export function filamentStats() {
  return state.stats;
}

// A new list (and the stats of the last slice, or undefined to keep them).
export function setFilaments(list, stats) {
  if (Array.isArray(list) && list.length > 0) state.list = list;
  if (stats !== undefined) state.stats = stats;
  for (const v of state.views) v();
}

// Calls fn after each change of the list, while `node` is in the page.
function follow(node, fn) {
  const v = () => {
    if (!node.isConnected && node.dataset.shown === "1") {
      state.views.delete(v);
      return;
    }
    if (node.isConnected) node.dataset.shown = "1";
    fn();
  };
  state.views.add(v);
  return v;
}

// Calls `fn` after each change of the list (for a node that always shows).
export function followFilaments(fn) {
  state.views.add(fn);
}

// Black or white text on a color.
export function inkOn(color) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color || "");
  if (!m) return "#000";
  const [r, g, b] = m.slice(1).map((h) => parseInt(h, 16) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55 ? "#111" : "#fff";
}

// The words of a filament: "2 · PLA".
export function filamentLabel(f) {
  return `${f.index + 1} · ${f.material || f.name || "filament"}`;
}

function chip(f, selected, onPick) {
  const b = document.createElement("button");
  b.className = "fil-chip";
  b.classList.toggle("on", selected);
  b.style.background = f.color;
  b.style.color = inkOn(f.color);
  b.textContent = String(f.index + 1);
  b.title = `Filament ${filamentLabel(f)} (${f.color})`;
  b.setAttribute("aria-label", `Filament ${f.index + 1}, ${f.material || ""} ${f.color}`);
  b.setAttribute("aria-pressed", String(selected));
  b.onclick = (e) => {
    e.stopPropagation();
    onPick(f.index);
  };
  return b;
}

// The editor of project.filament (see SettingsBrowser.makeEditor):
// commit(value) sets the value ("1" for filament 0). add(): a new
// filament, or null for no "+" chip. Returns { node, update(entry) }.
// zero: the label of value 0 ("Part": the filament of the part), for the
// support filaments; null: the setting has no 0.
export function filamentEditor(info, commit, add = null, zero = null) {
  const box = document.createElement("div");
  box.className = "editor fil-editor";
  box.dataset.setting = info.name;
  box.title = info.doc;
  let value = zero ? 0 : 1;
  const draw = () => {
    const chips = state.list.map((f) => chip(f, f.index + 1 === value, (i) => {
      value = i + 1;
      draw();
      commit(String(i + 1));
    }));
    if (zero) {
      const z = document.createElement("button");
      z.className = "fil-chip fil-zero" + (value === 0 ? " on" : "");
      z.textContent = zero;
      z.title = zero === "Part" ? "The filament of the part" : "The support filament";
      z.setAttribute("aria-pressed", String(value === 0));
      z.onclick = (e) => {
        e.stopPropagation();
        value = 0;
        draw();
        commit("0");
      };
      chips.unshift(z);
    }
    if (add) {
      const plus = document.createElement("button");
      plus.className = "fil-chip fil-add";
      plus.textContent = "+";
      plus.title = "Add a filament to the plate";
      plus.setAttribute("aria-label", "Add a filament");
      plus.onclick = async (e) => {
        e.stopPropagation();
        const i = await add();
        if (i >= 0) {
          value = i + 1;
          commit(String(i + 1));
        }
      };
      chips.push(plus);
    }
    box.replaceChildren(...chips);
  };
  follow(box, draw);
  draw();
  return {
    node: box,
    update: (entry) => {
      const v = Number(entry?.value);
      value = zero ? (v >= 0 ? v : 0) : v >= 1 ? v : 1;
      draw();
    },
  };
}

export class FilamentList {
  // ctx: { client, applySettings(r) }. The list draws into `node`.
  constructor(ctx) {
    this.ctx = ctx;
    this.node = document.createElement("div");
    this.node.className = "fil-list";
    this.node.setAttribute("aria-label", "The filaments of the plate");
    follow(this.node, () => this.draw());
    this.draw();
  }

  async call(op, args) {
    const r = await this.ctx.client.call(op, args);
    if (r.error) this.ctx.toast?.(r.error);
    if (r.list) setFilaments(r.list);
    if (op === "filamentSet" && args.index === 0) this.ctx.applySettings?.(r);
    return r;
  }

  draw() {
    const list = state.list;
    const st = state.stats;
    const rows = [];
    const head = document.createElement("div");
    head.className = "fil-head";
    const title = document.createElement("span");
    title.textContent = list.length > 1 ? `${list.length} filaments` : "Filament";
    head.append(title);
    if (st && st.changes > 0) {
      const ch = document.createElement("span");
      ch.className = "dim";
      ch.textContent = ` · ${st.changes} ${st.changes === 1 ? "change" : "changes"}${st.flushG > 0.05 ? ` · flush ${st.flushG.toFixed(1)} g` : ""}`;
      head.append(ch);
    }
    rows.push(head);
    for (const f of list) {
      const row = document.createElement("div");
      row.className = "fil-row";
      const sw = document.createElement("input");
      sw.type = "color";
      sw.className = "fil-swatch";
      sw.value = /^#[0-9a-f]{6}$/i.test(f.color) ? f.color : "#d0d0cc";
      sw.title = `The color of filament ${f.index + 1}`;
      sw.setAttribute("aria-label", `The color of filament ${f.index + 1}`);
      sw.onchange = () => this.call("filamentSet", { index: f.index, name: "filament.color", value: sw.value });
      const num = document.createElement("span");
      num.className = "fil-num";
      num.textContent = String(f.index + 1);
      const mat = document.createElement("select");
      mat.className = "choice fil-mat";
      mat.title = `The material of filament ${f.index + 1}`;
      mat.setAttribute("aria-label", `The material of filament ${f.index + 1}`);
      const kinds = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA"];
      if (f.material && !kinds.includes(f.material)) kinds.unshift(f.material);
      for (const k of kinds) mat.append(new Option(k, k));
      mat.value = f.material || "PLA";
      mat.onchange = () => this.call("filamentSet", { index: f.index, name: "filament.material", value: mat.value });
      const grams = document.createElement("span");
      grams.className = "dim fil-g";
      const g = st?.grams?.[f.index];
      // The spool of the printer that the filament comes from ("A1").
      const from = f.fromPrinter ? f.slot || "Printer" : "";
      grams.textContent = [from, g > 0 ? `${g.toFixed(1)} g` : ""].filter(Boolean).join(" · ");
      if (f.fromPrinter) grams.title = `From the printer: ${f.slot ? `the spool in ${f.slot}` : "its spool"}`;
      else if (f.hand) grams.title = "You set this filament. It stays when the printer has other spools.";
      row.append(sw, num, mat);
      // A printer with two nozzles: the nozzle of the filament.
      if ((this.ctx.nozzles?.() ?? 1) >= 2) {
        const nz = document.createElement("select");
        nz.className = "choice fil-nozzle";
        nz.title = `The nozzle of filament ${f.index + 1}: the main nozzle (fed by the AMS on the X2D), or the second nozzle (fed by the external spool)`;
        nz.setAttribute("aria-label", `The nozzle of filament ${f.index + 1}`);
        nz.append(new Option("Main", "0"), new Option("2nd", "1"));
        nz.value = String(f.nozzle ?? 0);
        nz.onchange = () => this.call("filamentSet", { index: f.index, name: "filament.nozzle", value: nz.value });
        row.append(nz);
        row.classList.add("two");
      }
      row.append(grams);
      if (f.index > 0) {
        const rm = document.createElement("button");
        rm.className = "flat icon fil-rm";
        rm.textContent = "×";
        rm.title = `Remove filament ${f.index + 1}. Its parts and layers print with filament 1.`;
        rm.setAttribute("aria-label", `Remove filament ${f.index + 1}`);
        rm.onclick = () => this.call("filamentRemove", { index: f.index });
        row.append(rm);
      } else row.append(document.createElement("span"));
      rows.push(row);
    }
    if (list.length < 16) {
      const add = document.createElement("button");
      add.className = "flat pc-add fil-add-row";
      add.textContent = "+ Add a filament";
      add.title = "Add a filament to the plate. A part or a range of layers can then print with it.";
      add.onclick = () => this.call("filamentAdd", {});
      rows.push(add);
    }
    this.node.replaceChildren(...rows);
  }
}
