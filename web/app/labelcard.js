// labelcard.js: the card of the selected label of the Label tool
// (label.js). A spatial card (spatial.js): it goes to the place where
// the user put it last, else beside the label (place.js). It never covers
// the label or its handle.
//
// The card has:
// - the shapes of the label, each with the chips Text, Line, Bar, Ring,
//   Ticks, and Free (and SVG for a picture), and its fields (the text,
//   the size, the ticks of a dial, ...), "+ Add a shape", and "Place an
//   SVG…";
// - the turn of the label, its mode (Ink, Raised, Cut in) and relief,
//   its filament (chips), and its depth;
// - the stroke check (the thinnest stroke, the sizes of text that print
//   clean and fair, and one line of advice), and the cost (the filament
//   changes, the minutes, and the grams), from zs_app_label_info;
// - Delete.
// Each field changes the preview at once; the label goes to the worker
// after a short pause (label.js, change).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";
import { movable } from "./drag.js";
import { spatial, savedPlace, remember } from "./spatial.js";
import { placeBeside, freeArea } from "./place.js";
import { filaments, inkOn } from "./filaments.js";
import { SHAPES, SHAPE_NAMES, MODES, MODE_NAMES, DEFAULT_RELIEF, CURVE_LIMIT, CURVE_TEXT, angleOf, labelName } from "./label.js";

const KIND = "label-card";

// The fields of each shape: [field, label, unit, min, max, step, tip].
const FIELDS = {
  text: [
    ["size", "Size", "mm", 0.5, 200, 0.1, "The height of the capitals"],
    ["weight", "Weight", "mm", 0, 0.3, 0.01, "Makes each stroke wider: small text prints better, small holes close"],
  ],
  line: [
    ["length", "Length", "mm", 0.1, 500, 0.1, ""],
    ["width", "Width", "mm", 0.1, 100, 0.1, ""],
  ],
  bar: [
    ["width", "Width", "mm", 0.1, 500, 0.1, ""],
    ["height", "Height", "mm", 0.1, 500, 0.1, ""],
    ["radius", "Corners", "mm", 0, 100, 0.1, "The radius of the corners"],
  ],
  ring: [
    ["outer", "Outer radius", "mm", 0.1, 250, 0.1, ""],
    ["inner", "Inner radius", "mm", 0, 250, 0.1, "0 makes a disk"],
  ],
  ticks: [
    ["count", "Count", "", 1, 360, 1, "The number of ticks"],
    ["radius", "Radius", "mm", 0, 250, 0.1, "The distance from the center to the inner end of each tick"],
    ["length", "First length", "mm", 0.1, 100, 0.1, "The length of the first tick"],
    ["length_end", "Last length", "mm", 0, 100, 0.1, "The length of the last tick (0: the same as the first). The ticks between grow evenly."],
    ["width", "Width", "mm", 0.1, 20, 0.05, "The width of each tick"],
    ["start", "Start", "°", -360, 360, 1, "The angle of the first tick (0: to the right, 90: up)"],
    ["sweep", "Sweep", "°", -360, 360, 1, "The angle from the first tick to the last (negative: clockwise)"],
  ],
  polyline: [
    ["width", "Width", "mm", 0, 100, 0.1, "The width of the line (0 with Filled)"],
  ],
  svg: [
    ["size", "Height", "mm", 0.1, 500, 0.1, "The height of the picture"],
  ],
};

function numInput(value, min, max, step) {
  const n = Object.assign(document.createElement("input"), { type: "number", min: String(min), max: String(max), step: String(step), className: "pc-cut-n" });
  n.value = String(round(value));
  return n;
}

function round(v) {
  return Math.round((Number(v) || 0) * 1000) / 1000;
}

export class LabelCard {
  constructor(tool, host) {
    this.tool = tool;
    this.host = host;
    this.node = null;
    this.userAt = null;
    this.inputs = []; // { node, get(label) }: the fields that follow the label
  }

  close() {
    this.node?.remove();
    this.node = null;
  }

  // Builds the card for label l again (a new label, or other shapes).
  show(l) {
    const keepScroll = this.node?.scrollTop ?? 0;
    const at = this.node ? [this.node.style.left, this.node.style.top] : null;
    // The field with the focus keeps it in the new card.
    const fields = this.node ? [...this.node.querySelectorAll("input, select, button")] : [];
    const focus = fields.indexOf(document.activeElement);
    const range = focus >= 0 && document.activeElement.type === "text" ? [document.activeElement.selectionStart, document.activeElement.selectionEnd] : null;
    this.key = this.keyOf(l);
    this.node?.remove();
    this.inputs = [];
    const tool = this.tool;
    const card = el("div", "part-card label-card");
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", "The label");
    const head = el("div", "lc-head");
    this.title = el("div", "lc-title", `Label ${labelName(l)}`);
    const close = el("button", "flat icon lc-close", "×");
    close.setAttribute("aria-label", "Close");
    close.title = "Close the card (Esc). The label stays.";
    close.onclick = () => tool.select(-1);
    head.append(this.title, close);
    head.title = "Drag to move the card";
    movable(card, head, this.host, (x, y) => {
      this.userAt = [x, y];
      remember(KIND, { x, y });
    });
    spatial(card, KIND, head, () => {
      this.userAt = null;
      this.place(tool.screenBox());
    });
    card.append(head);

    // A notice when the label has the filament of the part.
    this.notice = el("div", "lc-note label-notice");
    this.curveNote = el("div", "lc-note", CURVE_TEXT);
    this.curveNote.hidden = !(tool.curve > CURVE_LIMIT);
    card.append(this.notice, this.curveNote);

    // The shapes.
    l.items.forEach((it, i) => card.append(this.itemBox(l, it, i)));
    const addRow = el("div", "pc-cut-row");
    const addSel = document.createElement("select");
    addSel.append(new Option("+ Add a shape…", ""));
    for (const k of SHAPES) addSel.append(new Option(SHAPE_NAMES[k], k));
    addSel.title = "Add a shape to this label: it shares the place, the turn, and the filament. Ticks go around the center, under the text.";
    addSel.onchange = () => {
      if (addSel.value) tool.addItem(addSel.value);
    };
    // An SVG picture from a file.
    const svgBtn = el("button", "pc-action label-svg", "Place an SVG…");
    svgBtn.title = "Put the filled shapes of an SVG file on the label. You can also drop an SVG file on a part.";
    const file = Object.assign(document.createElement("input"), { type: "file", accept: ".svg,image/svg+xml", hidden: true });
    svgBtn.onclick = () => file.click();
    file.onchange = async () => {
      const f = file.files[0];
      file.value = "";
      if (f) tool.placeSvg(await f.text(), f.name);
    };
    addRow.append(addSel, svgBtn, file);
    card.append(addRow);

    // The turn.
    const turnRow = el("label", "pc-cut-row");
    const angle = (x) => Math.round(angleOf(x) * 10) / 10;
    const turn = numInput(angle(l), -180, 180, 1);
    turn.title = "The turn of the label on the face (0: level). The wheel over the label turns it 1° (Shift: 15°).";
    turn.oninput = () => {
      const v = Number(turn.value);
      if (turn.value !== "" && Number.isFinite(v)) tool.setAngle(v);
    };
    turnRow.append(el("span", "label-k", "Turn"), turn, el("span", "dim", "°"));
    this.inputs.push({ node: turn, get: angle });
    card.append(turnRow);

    // The mode: ink, raised, or cut in, and the relief.
    const modeRow = el("div", "pc-cut-row label-mode");
    modeRow.append(el("span", "label-k", "Print"));
    this.modeButtons = MODES.map((m) => {
      const b = el("button", "pc-action", MODE_NAMES[m]);
      b.title = m === "ink" ? "Flush with the surface, in the filament of the label" : m === "raised" ? "Out of the surface by the relief" : "Cut into the surface by the relief";
      b.onclick = () => tool.setMode(m);
      modeRow.append(b);
      return b;
    });
    card.append(modeRow);
    this.reliefRow = el("label", "pc-cut-row label-relief");
    const relief = numInput(l.relief || DEFAULT_RELIEF, 0.1, 10, 0.1);
    relief.title = "The height of a raised label, or the depth of a cut, mm";
    relief.oninput = () => {
      const v = Number(relief.value);
      if (relief.value !== "" && v > 0 && v <= 10) tool.setRelief(v);
    };
    this.reliefRow.append(el("span", "label-k", "Relief"), relief, el("span", "dim", "mm"));
    this.inputs.push({ node: relief, get: (x) => x.relief || DEFAULT_RELIEF });
    card.append(this.reliefRow);

    // The filament.
    card.append(el("div", "pc-heading", "Filament"));
    this.chips = el("div", "fil-editor");
    card.append(this.chips);

    // The depth: 1 line, 2 lines, or mm.
    const depthRow = el("div", "pc-cut-row label-depth");
    depthRow.append(el("span", "label-k", "Depth"));
    const one = el("button", "pc-action", "1 line");
    const two = el("button", "pc-action", "2 lines");
    one.title = "The color is one line deep (the outer wall)";
    two.title = "The color is two lines deep: more color for a light filament over a dark part";
    const mm = numInput(l.depth || 0, 0, 10, 0.01);
    mm.title = "The depth of the color from the surface, mm (0: one line)";
    const lw = () => tool.info?.line_width || 0.42;
    one.onclick = () => tool.setDepth(0);
    two.onclick = () => tool.setDepth(2 * lw());
    mm.oninput = () => {
      const v = Number(mm.value);
      if (mm.value !== "" && v >= 0 && v <= 10) tool.setDepth(v);
    };
    depthRow.append(one, two, mm, el("span", "dim", "mm"));
    this.depthButtons = [one, two];
    this.inputs.push({ node: mm, get: (x) => x.depth || 0 });
    card.append(depthRow);

    // The stroke check and the cost (showInfo).
    this.check = el("div", "label-check");
    this.cost = el("div", "label-cost");
    card.append(el("div", "pc-heading", "Print"), this.check, this.cost);

    const del = el("button", "pc-action label-delete", "Delete the label");
    del.title = "Remove the label from the part (Delete)";
    del.onclick = () => tool.remove();
    card.append(del);

    card.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        if (e.target.closest("input, select, textarea")) e.target.blur();
        else tool.select(-1);
        return;
      }
      // The keys of the fields stay in the fields.
      if (e.target.closest("input, select, textarea")) e.stopPropagation();
    });
    this.host.append(card);
    this.node = card;
    if (at) [card.style.left, card.style.top] = at;
    card.scrollTop = keepScroll;
    if (focus >= 0) {
      const f = card.querySelectorAll("input, select, button")[focus];
      f?.focus();
      if (range && f?.type === "text") f.setSelectionRange(...range);
    }
    this.update(l);
    this.showInfo(tool.info);
    this.place(tool.screenBox());
  }

  // The box of one shape: its chips and its fields.
  itemBox(l, it, i) {
    const tool = this.tool;
    const box = el("div", "label-item");
    const chips = el("div", "pc-actions label-shapes");
    const kinds = it.kind === "svg" ? ["svg", ...SHAPES] : SHAPES;
    for (const k of kinds) {
      const b = el("button", "pc-action", SHAPE_NAMES[k]);
      b.classList.toggle("on", it.kind === k);
      b.setAttribute("aria-pressed", String(it.kind === k));
      b.title = k === "svg" ? "An SVG picture" : k === "polyline" ? "A free line: click points on the face" : `Make this shape a ${SHAPE_NAMES[k].toLowerCase()}`;
      b.onclick = () => k !== "svg" && tool.setShape(i, k);
      chips.append(b);
    }
    if (l.items.length > 1) {
      const x = el("button", "flat icon pc-clear", "×");
      x.title = "Remove this shape from the label";
      x.setAttribute("aria-label", `Remove shape ${i + 1}`);
      x.onclick = () => tool.removeItem(i);
      chips.append(x);
    }
    box.append(chips);
    if (it.kind === "text") {
      const t = Object.assign(document.createElement("input"), { type: "text", className: "label-text", maxLength: 256 });
      t.value = it.text;
      t.setAttribute("aria-label", "The text of the label");
      t.placeholder = "Text";
      t.oninput = () => tool.editItem(i, { text: t.value });
      this.inputs.push({ node: t, get: (x) => x.items[i]?.text ?? "" });
      box.append(t);
    }
    const grid = el("div", "label-fields");
    for (const [f, name, unit, min, max, step, tip] of FIELDS[it.kind]) {
      const row = el("label", "pc-cut-row");
      const n = numInput(it[f] ?? 0, min, max, step);
      n.title = tip || name;
      n.oninput = () => {
        const v = Number(n.value);
        if (n.value === "" || !Number.isFinite(v) || v < min || v > max) {
          n.classList.add("bad");
          return;
        }
        const ok = tool.editItem(i, { [f]: f === "count" ? Math.round(v) : v });
        n.classList.toggle("bad", !ok);
      };
      row.append(el("span", "label-k", name), n, el("span", "dim", unit));
      this.inputs.push({ node: n, get: (x) => x.items[i]?.[f] ?? 0 });
      grid.append(row);
    }
    if (it.kind === "polyline") {
      const row = el("div", "pc-cut-row");
      for (const [f, name] of [["closed", "Closed"], ["filled", "Filled"]]) {
        const lab = el("label", "pc-cut-row");
        const c = Object.assign(document.createElement("input"), { type: "checkbox", checked: !!it[f] });
        c.onchange = () => {
          if (!tool.editItem(i, { [f]: c.checked })) c.checked = !c.checked;
        };
        lab.append(c, el("span", "", name));
        row.append(lab);
      }
      grid.append(row);
      const drawing = tool.drawing === i;
      const draw = el("button", "pc-action", drawing ? "Done" : "Draw points");
      draw.title = drawing ? "Stop: the line keeps its points" : "Click points on the face, one after the other";
      draw.onclick = () => (drawing ? tool.stopDrawing() : tool.startDrawing(i));
      grid.append(draw);
      if (drawing) grid.append(el("div", "dim caption", "Click points on the face. Click Done at the end."));
    }
    // The place of the shape in the label.
    const atRow = el("label", "pc-cut-row");
    const ax = numInput(it.at?.[0] ?? 0, -500, 500, 0.1);
    const ay = numInput(it.at?.[1] ?? 0, -500, 500, 0.1);
    ax.title = "Right of the center of the label, mm";
    ay.title = "Up from the center of the label, mm";
    const setAt = () => {
      const x = Number(ax.value);
      const y = Number(ay.value);
      if (Number.isFinite(x) && Number.isFinite(y)) tool.editItem(i, { at: [x, y] });
    };
    ax.oninput = setAt;
    ay.oninput = setAt;
    atRow.append(el("span", "label-k", "Offset"), ax, ay, el("span", "dim", "mm"));
    this.inputs.push({ node: ax, get: (x) => x.items[i]?.at?.[0] ?? 0 }, { node: ay, get: (x) => x.items[i]?.at?.[1] ?? 0 });
    grid.append(atRow);
    box.append(grid);
    return box;
  }

  // The shapes of a label and the item that draws: a card with another
  // key has other fields.
  keyOf(l) {
    return `${l.id}:${l.items.map((it) => it.kind).join(",")}:${this.tool.drawing}`;
  }

  // The card after a change from outside (an undo, a slice): the same
  // fields get the new values; other shapes build the card again.
  refresh(l) {
    if (this.node && this.keyOf(l) === this.key) this.update(l);
    else this.show(l);
  }

  // The focus to the first text field, with its text selected.
  focusText() {
    const t = this.node?.querySelector(".label-text");
    if (!t) return;
    t.focus();
    t.select();
  }

  // The fields after a change of the label (not the one with the focus).
  update(l) {
    if (!this.node) return;
    this.title.textContent = `Label ${labelName(l)}`;
    for (const { node, get } of this.inputs) {
      if (node === document.activeElement) continue;
      const v = get(l);
      node.value = typeof v === "number" ? String(round(v)) : v;
    }
    this.depthButtons[0].classList.toggle("on", !(l.depth > 0));
    const lw = this.tool.info?.line_width || 0.42;
    this.depthButtons[1].classList.toggle("on", Math.abs((l.depth || 0) - 2 * lw) < 1e-6);
    const mode = l.mode || "ink";
    MODES.forEach((m, k) => {
      this.modeButtons[k].classList.toggle("on", m === mode);
      this.modeButtons[k].setAttribute("aria-pressed", String(m === mode));
    });
    this.reliefRow.hidden = mode === "ink";
    this.drawChips(l);
  }

  drawChips(l) {
    const list = filaments();
    const base = this.tool.base;
    const chips = list.map((f) => {
      const b = document.createElement("button");
      b.className = "fil-chip";
      b.classList.toggle("on", f.index + 1 === l.filament);
      b.style.background = f.color;
      b.style.color = inkOn(f.color);
      b.textContent = String(f.index + 1);
      b.title = `Filament ${f.index + 1} (${f.material}, ${f.color})${f.index + 1 === base ? ": the filament of the part" : ""}`;
      b.onclick = () => this.tool.setFilament(f.index + 1);
      return b;
    });
    const plus = document.createElement("button");
    plus.className = "fil-chip fil-add";
    plus.textContent = "+";
    plus.title = "Add a filament to the plate, for this label";
    plus.onclick = () => this.tool.addFilament();
    chips.push(plus);
    this.chips.replaceChildren(...chips);
    // A label in the filament of the part does not show.
    this.notice.replaceChildren();
    if (l.filament === base && (l.mode || "ink") === "ink") {
      if (list.length <= 1) {
        const add = el("button", "pc-action", "Add a filament");
        add.title = "Add a second filament to the plate, and print the label with it";
        add.onclick = () => this.tool.addFilament();
        this.notice.append(el("span", "", "The plate has one filament, so this label does not show. "), add);
      } else this.notice.append(el("span", "", "The label has the filament of the part, so it does not show. Pick another filament."));
    }
    this.notice.hidden = this.notice.childNodes.length === 0;
  }

  showCurve(deg) {
    if (this.curveNote) this.curveNote.hidden = !(deg > CURVE_LIMIT);
  }

  // The facts of zs_app_label_info: the stroke check and the cost.
  showInfo(info) {
    if (!this.node) return;
    this.check.replaceChildren();
    this.cost.replaceChildren();
    if (!info) {
      this.check.append(el("div", "dim caption", "…"));
      return;
    }
    const stats = el("div", "lc-stats");
    const stat = (k, v, warn = false) => {
      const vn = el("div", "lc-v", v);
      vn.classList.toggle("warning", warn);
      stats.append(el("div", "lc-k", k), vn);
    };
    const lw = info.line_width || 0.42;
    if (info.thinnest > 0) stat("Thinnest stroke", `${info.thinnest.toFixed(2)} mm`, info.thinnest < 2 * lw);
    if (info.clean_size > 0) stat("Text size", `clean from ${info.clean_size.toFixed(1)} mm, fair from ${info.fair_size.toFixed(1)} mm`);
    this.check.append(stats);
    if (info.advice) this.check.append(el("div", "lc-info", info.advice));
    if (info.same_filament) return;
    const c = el("div", "lc-stats");
    const n = info.sliced ? info.changes : info.estimate_changes;
    c.append(el("div", "lc-k", info.sliced ? "Adds" : "Adds about"), el("div", "lc-v", `${n} filament ${n === 1 ? "change" : "changes"}`));
    c.append(el("div", "lc-k", "Time"), el("div", "lc-v", `${Math.round(info.minutes)} min`));
    c.append(el("div", "lc-k", "Flush"), el("div", "lc-v", `${info.grams.toFixed(1)} g`));
    if (info.layers > 0) c.append(el("div", "lc-k", "Layers"), el("div", "lc-v", `${info.layers} (${info.z_min.toFixed(1)} to ${info.z_max.toFixed(1)} mm)`));
    this.cost.append(c);
    if (!info.sliced) this.cost.append(el("div", "dim caption", "An estimate. The slice gives the count."));
    if (info.kind === "side" && n > 10 && info.top_changes >= 0) this.cost.append(el("div", "lc-info", `On the top face, this label costs ${info.top_changes} ${info.top_changes === 1 ? "change" : "changes"}.`));
  }

  // Beside the label (box: its box on the screen, CSS pixels of the host,
  // or null), or at the place where the user put the card.
  place(box) {
    const card = this.node;
    if (!card) return;
    if (this.userAt) {
      [card.style.left, card.style.top] = this.userAt.map((v) => `${v}px`);
      return;
    }
    const kept = savedPlace(KIND, card, this.host, box);
    if (kept) {
      card.style.left = `${kept[0]}px`;
      card.style.top = `${kept[1]}px`;
      return;
    }
    const area = freeArea(this.host);
    const [x, y] = box ? placeBeside(box, area, card.offsetWidth, card.offsetHeight) : [area[2] - card.offsetWidth, area[1] + 52];
    card.style.left = `${x}px`;
    card.style.top = `${y}px`;
  }
}
