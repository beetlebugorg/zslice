// clipboard.js: Copy (Ctrl+C), Cut (Ctrl+X), Paste (Ctrl+V), and
// Duplicate (Ctrl+D) for each kind of object that the app can select. On
// a Mac, Cmd works in place of Ctrl.
//
// What a copy takes, by the selection (the first that applies):
//
// - A setting editor with the focus (a list or a switch; a text field
//   keeps its own copy and paste): its value.
// - The selected label of the Label tool: the label (its shapes, its
//   filament, its depth, and its turn).
// - The selected area of the Support tool: the area, and the part under
//   it.
// - The card of a range of layers: the changes of those layers.
// - The selected parts: the parts in the core (zs_app_parts_copy), with
//   their settings, paint, labels, support trees, and the support areas
//   and marks over them.
// - A selected line: the report of the line ("Copy for AI").
//
// A paste puts the last copy where it fits:
//
// - Parts: with parts selected, each copy at a free place on the bed (as
//   Duplicate). With no selection, the group at the bed point under the
//   pointer. On an empty plate, at the places of the copy. The copies
//   become the selection. The plate can be another plate.
// - A whole plate (the context menu of the bed): its parts, as above. On
//   an empty plate, the same plate (its parts, layer changes, and
//   support). "Paste as a new plate" makes a new plate of it.
// - A label: on the face under the pointer, with the same turn. Else on
//   the same face, under the label of the copy.
// - A support area: at the same place on the part under the pointer (a
//   copy of the part gets the same support). On the part of the copy, the
//   area goes to the pointer.
// - The changes of layers: on the layers of the range card.
// - A setting value: into the setting editor with the focus.
//
// Each paste is one step of the history. Cut is a copy and a remove (for
// layers: the changes go). The app keeps its own clipboard. The system
// clipboard gets a small JSON text too ({"zslice":1, "kind", "id", ...}),
// so a label, a support area, the changes of layers, or a setting value
// pastes into another tab of zslice. The parts stay in the core of this
// tab: another tab says so.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const TEXT_FIELD = 'input:not([type=checkbox]):not([type=radio]):not([type=button]), textarea, [contenteditable=""], [contenteditable="true"]';

// The JSON text of a copy for the system clipboard, or the plain value of
// a setting.
export function clipText(clip) {
  if (!clip) return "";
  if (clip.kind === "setting") return String(clip.data.value);
  if (clip.kind === "line") return clip.data.text;
  const out = { zslice: 1, kind: clip.kind, id: clip.id };
  if (clip.kind === "parts" || clip.kind === "plate") out.count = clip.count;
  else out.data = clip.data;
  return JSON.stringify(out);
}

// A copy from the text of the system clipboard: { kind, id, data } for a
// zslice JSON text, { kind: "text", data } for other text, or null.
export function parseClipText(text) {
  if (typeof text !== "string" || text === "") return null;
  if (text[0] === "{") {
    try {
      const v = JSON.parse(text);
      if (v && v.zslice === 1 && typeof v.kind === "string" && typeof v.id === "string") return { kind: v.kind, id: v.id, data: v.data ?? null, count: v.count ?? 0 };
    } catch {
      // Not a zslice copy: plain text.
    }
  }
  return { kind: "text", data: text };
}

// The editor of a setting at an element: the element with data-setting
// (settings.js, makeEditor), or the one in a focused row. Or null.
export function settingEditor(target) {
  const t = target?.closest?.("[data-setting]");
  if (t) return t;
  if (target?.classList?.contains("row")) return target.querySelector?.("[data-setting]") ?? null;
  return null;
}

// The value that an editor shows: a list, a switch, or a field.
function editorValue(ed) {
  const sel = ed.querySelector("select");
  if (sel) return sel.value;
  const sw = ed.querySelector(".switch");
  if (sw) return sw.classList.contains("on") ? "true" : "false";
  const field = ed.querySelector("input, textarea");
  if (field) return field.value;
  return ed.textContent.trim();
}

// Puts a value into an editor as a user change. True if it took it.
function setEditorValue(ed, value) {
  const v = String(value).trim();
  const sel = ed.querySelector("select");
  if (sel) {
    const opt = [...sel.options].find((o) => o.value === v || o.textContent === v);
    if (!opt) return false;
    sel.value = opt.value;
    sel.dispatchEvent(new Event("change"));
    return true;
  }
  const sw = ed.querySelector(".switch");
  if (sw) {
    const on = /^(true|on|yes|1)$/i.test(v);
    if (!on && !/^(false|off|no|0)$/i.test(v)) return false;
    if (sw.classList.contains("on") !== on) sw.click();
    return true;
  }
  const field = ed.querySelector("input, textarea");
  if (field) {
    field.value = v;
    field.dispatchEvent(new Event("input"));
    field.dispatchEvent(new Event("change"));
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
    return true;
  }
  return false;
}

let serial = 0;
function newId() {
  serial += 1;
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}-${serial}`;
}

export class Clipboard {
  // ctx: { client, canvas, tools (tools.js), labelTool, supportTool,
  //        rangeCard, partCard, app (sel, page, state), toast(text),
  //        menuOpen(), report() -> Promise<text or null> (Copy for AI),
  //        applySettings(r), pasted(r) (parts came on the plate),
  //        plateAdded(r) (a new plate of a paste) }
  constructor(ctx) {
    this.ctx = ctx;
    this.clip = null; // { kind, id, data, count }
    // The pointer over the view: CSS pixels in the canvas, or null.
    this.pointer = null;
    this.pasteTimer = 0;
    const canvas = ctx.canvas;
    canvas.addEventListener("pointermove", (e) => {
      const r = canvas.getBoundingClientRect();
      this.pointer = [e.clientX - r.left, e.clientY - r.top];
    });
    canvas.addEventListener("pointerleave", () => {
      this.pointer = null;
    });
    document.addEventListener("keydown", (e) => this.key(e));
    // The paste event has the text of the system clipboard with no
    // question to the user.
    document.addEventListener("paste", (e) => this.onPaste(e), true);
  }

  // ---- the keys ----

  key(e) {
    if (!(e.ctrlKey || e.metaKey) || e.altKey || e.defaultPrevented) return;
    if (this.ctx.menuOpen?.()) return;
    const k = e.key.toLowerCase();
    if (!["c", "x", "v", "d"].includes(k)) return;
    const t = e.target;
    // A text field keeps its own keys.
    if (t?.closest?.(TEXT_FIELD)) return;
    if (k === "v") {
      // The paste event follows with the system clipboard; without one
      // (some browsers fire none outside a text field), the app's own.
      clearTimeout(this.pasteTimer);
      const shift = e.shiftKey;
      this.pasteTimer = setTimeout(() => this.paste({ asPlate: shift }), 80);
      this.pasteShift = shift;
      return;
    }
    if (e.shiftKey) return;
    const sel = this.selection(t);
    if (!sel) {
      if (k !== "d") this.ctx.toast("Select a part, a label, a support area, or layers to copy.");
      return;
    }
    e.preventDefault();
    if (k === "c") this.copy(sel);
    else if (k === "x") this.cut(sel);
    else this.duplicate(sel);
  }

  onPaste(e) {
    if (e.target?.closest?.(TEXT_FIELD)) {
      clearTimeout(this.pasteTimer);
      return;
    }
    clearTimeout(this.pasteTimer);
    e.preventDefault();
    const text = e.clipboardData?.getData("text/plain") ?? "";
    this.paste({ text, asPlate: !!this.pasteShift, target: e.target });
    this.pasteShift = false;
  }

  // What a copy takes now: { kind, ... }, or null.
  selection(target = document.activeElement) {
    const { labelTool, supportTool, rangeCard, tools, app } = this.ctx;
    const ed = settingEditor(target);
    if (ed) return { kind: "setting", ed };
    if (labelTool?.on && labelTool.label) return { kind: "label" };
    if (supportTool?.on && supportTool.sel >= 0) return { kind: "area" };
    if (rangeCard?.open) return { kind: "range" };
    if (tools?.parts?.length > 0) return { kind: "parts", indices: tools.parts.map((p) => p.index) };
    if (app.sel >= 0) return { kind: "line" };
    return null;
  }

  // The new copy of the app, and its text on the system clipboard.
  keep(clip) {
    this.clip = { id: newId(), ...clip };
    const text = clipText(this.clip);
    navigator.clipboard?.writeText?.(text).catch(() => {});
    return this.clip;
  }

  // ---- copy, cut, duplicate ----

  async copy(sel = this.selection()) {
    const { client, labelTool, supportTool, rangeCard, toast } = this.ctx;
    switch (sel?.kind) {
      case "setting": {
        const name = sel.ed.dataset.setting;
        this.keep({ kind: "setting", data: { name, value: editorValue(sel.ed) } });
        toast("Copied the value.");
        return true;
      }
      case "label": {
        this.keep({ kind: "label", data: { label: labelTool.copyLabel(), part: labelTool.index } });
        toast("Copied the label.");
        return true;
      }
      case "area": {
        const data = await supportTool.copyArea();
        if (!data) return false;
        this.keep({ kind: "area", data });
        toast("Copied the support area.");
        return true;
      }
      case "range": {
        const [zmin, zmax] = rangeCard.zRange();
        const r = await client.call("rangeChanges", { zmin, zmax });
        if (!r.list?.length) {
          toast("These layers have no changes to copy.");
          return false;
        }
        this.keep({ kind: "range", data: { list: r.list } });
        toast(`Copied ${r.list.length} ${r.list.length === 1 ? "change" : "changes"} of the layers.`);
        return true;
      }
      case "parts": {
        const r = await client.call("partsCopy", { indices: sel.indices });
        if (!r.ok) {
          toast("The parts did not copy.");
          return false;
        }
        this.keep({ kind: "parts", count: r.count, data: null });
        toast(r.count === 1 ? "Copied the part." : `Copied ${r.count} parts.`);
        return true;
      }
      case "line": {
        const text = await this.ctx.report?.();
        if (!text) return false;
        this.keep({ kind: "line", data: { text } });
        toast("The report of the line is on the clipboard.");
        return true;
      }
      default:
        return false;
    }
  }

  // Copy, then the selection goes.
  async cut(sel = this.selection()) {
    const { client, labelTool, supportTool, rangeCard, tools, toast } = this.ctx;
    switch (sel?.kind) {
      case "label":
        if (await this.copy(sel)) await labelTool.remove();
        return;
      case "area":
        if (await this.copy(sel)) await supportTool.removeSelected();
        return;
      case "range": {
        if (!(await this.copy(sel))) return;
        const [zmin, zmax] = rangeCard.zRange();
        const r = await client.call("rangeReset", { names: this.clip.data.list.map((c) => c[0]), zmin, zmax, at: { z: zmin, names: rangeCard.names() } });
        this.ctx.applySettings?.(r);
        rangeCard.fill(r.at);
        return;
      }
      case "parts": {
        const r = await client.call("partsCut", { indices: sel.indices });
        if (!r.ok) {
          toast("The parts did not cut.");
          return;
        }
        this.keep({ kind: "parts", count: r.count, data: null });
        tools.selectPart(null);
        toast(r.count === 1 ? "Cut the part. Ctrl+V pastes it." : `Cut ${r.count} parts. Ctrl+V pastes them.`);
        return;
      }
      default:
        // A setting or a line: a copy (they stay).
        await this.copy(sel);
    }
  }

  // A copy next to the selection, with no change of the clipboard.
  async duplicate(sel = this.selection()) {
    const { labelTool, partCard, toast } = this.ctx;
    switch (sel?.kind) {
      case "parts":
        partCard.act("duplicate");
        return;
      case "label":
        await labelTool.pasteLabel(labelTool.copyLabel());
        return;
      default:
        toast("Ctrl+D duplicates parts and labels.");
    }
  }

  // ---- paste ----

  // text: the text of the system clipboard (a paste event), or undefined.
  // asPlate: a whole plate goes onto a new plate. target: the element of
  // the paste.
  async paste({ text, asPlate = false, target = document.activeElement } = {}) {
    const { toast } = this.ctx;
    let clip = this.clip;
    const sys = parseClipText(text);
    if (sys && sys.kind !== "text" && sys.id !== clip?.id) {
      // A copy of another tab.
      if (sys.kind === "parts" || sys.kind === "plate") {
        toast("The parts were copied in another tab. Copy them in this tab to paste them here.");
        return false;
      }
      clip = this.clip = { kind: sys.kind, id: sys.id, data: sys.data };
    }
    const ed = settingEditor(target);
    if (ed) {
      const value = sys?.kind === "text" ? sys.data : clip?.kind === "setting" ? clip.data.value : null;
      if (value == null) return false;
      if (!setEditorValue(ed, value)) toast("This setting does not take that value.");
      return true;
    }
    if (!clip) {
      toast("The clipboard is empty: copy a part, a label, a support area, or layers first.");
      return false;
    }
    return this.pasteClip(clip, { asPlate, at: this.pointer });
  }

  // Pastes a copy. at: CSS pixels of the view (the pointer, or the place
  // of a right click), or null.
  // here: a paste at that place also with parts selected (the context
  // menu).
  async pasteClip(clip, { asPlate = false, at = null, here = false } = {}) {
    const { client, labelTool, supportTool, rangeCard, tools, toast, app } = this.ctx;
    const dpr = window.devicePixelRatio || 1;
    const in3d = app.page === "3d";
    switch (clip.kind) {
      case "parts":
      case "plate": {
        if (asPlate) return this.pasteAsPlate();
        // With parts selected: free places, next to them. Else at the
        // pointer, on the bed.
        const bed = (here || tools.parts.length === 0) && at && in3d ? tools.bedPoint(at[0] * dpr, at[1] * dpr) : null;
        const r = await client.call("partsPaste", { at: bed });
        if (!r.ok) {
          toast(r.empty ? "The clipboard is empty: copy a part first." : "The parts did not paste.");
          return false;
        }
        this.ctx.pasted?.(r);
        tools.setParts(r.parts);
        if (r.fits === false) toast("The parts do not all fit on the bed. Move some, or paste on another plate.");
        return true;
      }
      case "label":
        if (!in3d) {
          toast("Paste a label in the 3D view.");
          return false;
        }
        return labelTool.pasteLabel(clip.data.label, at?.[0] ?? null, at?.[1] ?? null, clip.data.part ?? -1);
      case "area": {
        if (!at || !in3d) {
          toast("Point at a part to paste the support area there.");
          return false;
        }
        const part = await tools.partAt(at[0] * dpr, at[1] * dpr);
        const ok = await supportTool.pasteArea(clip.data, part, at[0] * dpr, at[1] * dpr);
        if (ok) toast("Pasted the support area.");
        return ok;
      }
      case "range": {
        if (!rangeCard.open) {
          toast("Select layers first (drag up or down over the print), then paste the changes.");
          return false;
        }
        const [zmin, zmax] = rangeCard.zRange();
        const byName = rangeCard.ctx.browser.byName;
        for (const [name] of clip.data.list) {
          const info = byName.get(name);
          if (info?.perLayer) rangeCard.addRow(info);
        }
        const r = await client.call("rangePaste", { list: clip.data.list, zmin, zmax, at: { z: zmin, names: rangeCard.names() } });
        this.ctx.applySettings?.(r);
        rangeCard.fill(r.at);
        if (r.error) toast(r.error);
        return r.ok > 0;
      }
      case "setting":
        toast("Click a setting, then paste the value into it.");
        return false;
      case "line":
        toast("The report of a line is text: paste it into a chat or a note.");
        return false;
      default:
        return false;
    }
  }

  // ---- the plate (the context menu of the bed) ----

  async copyPlate() {
    const r = await this.ctx.client.call("partsCopy", { whole: true });
    if (!r.ok || r.count === 0) {
      this.ctx.toast("The plate has no parts to copy.");
      return false;
    }
    this.keep({ kind: "plate", count: r.count, data: null });
    this.ctx.toast(`Copied the plate (${r.count === 1 ? "1 part" : `${r.count} parts`}).`);
    return true;
  }

  async pasteAsPlate() {
    if (this.clip?.kind !== "parts" && this.clip?.kind !== "plate") {
      this.ctx.toast("Copy parts or a plate first.");
      return false;
    }
    this.ctx.app.framePlate = this.ctx.app.plates?.length ?? -1;
    const r = await this.ctx.client.call("platePaste");
    if (!r.ok) {
      this.ctx.toast("The plate did not paste.");
      return false;
    }
    this.ctx.plateAdded?.(r);
    return true;
  }

  async duplicatePlate() {
    this.ctx.app.framePlate = this.ctx.app.plates?.length ?? -1;
    const r = await this.ctx.client.call("plateDuplicate");
    if (!r.ok) {
      this.ctx.toast("The plate has no parts to duplicate.");
      return false;
    }
    this.ctx.plateAdded?.(r);
    return true;
  }

  // The context menu: a paste at the place of the right click (client
  // pixels).
  async pasteAt(clientX, clientY) {
    if (!this.clip) return false;
    const r = this.ctx.canvas.getBoundingClientRect();
    return this.pasteClip(this.clip, { at: [clientX - r.left, clientY - r.top], here: true });
  }

  // True if a paste has something.
  get full() {
    return !!this.clip;
  }

  // True if the clipboard has parts or a plate of this tab.
  get hasParts() {
    return this.clip?.kind === "parts" || this.clip?.kind === "plate";
  }
}
