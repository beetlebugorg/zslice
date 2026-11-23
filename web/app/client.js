// client.js: the page side of the worker (worker.js). Each call returns a
// promise of the answer; the events of the worker go to `onEvent`.
//
// A change that starts a slice stops the slice that runs first: the worker
// cannot take the call while it slices, so with a shared memory (the module
// with threads) the page sets the cancel flag of the app itself.

// The calls that start a slice.
const SLICE_OPS = new Set(["set", "reset", "quality", "profile", "setScoped", "resetScoped", "load", "add", "plate", "projectLoad", "partAction", "partsAction", "partsMove", "partsSettingSet", "partsToPlate", "partSettingSet", "partPutDown", "partTurn",
  "putDown", "place", "partMove", "partToPlate", "partRotate", "markAdd", "markRemoveNear", "markSet", "markRemove", "marksClear",
  "supportAreaAdd", "supportAreaSet", "supportAreaKind", "supportAreaRemove",
  "labelAdd", "labelUpdate", "labelRemove",
  "treeMoveNode", "treeRadius", "treeMoveBranch", "treeDelete", "treeAdd", "treeReset",
  "undo", "redo", "historyGoto", "historyRevert", "historyTruncate",
  // The worker cannot take a call of the plate set while a plate slices in
  // the background: it slices again later.
  "plateAdd", "plateActivate", "plateRemove", "projectSet", "calibrate", "calibrationUse"]);
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// The calls whose `index` is a part of the active plate. The client sends
// the stable id of that part too, and the worker acts on the id: an index
// can name another part by the time the worker reads it.
const PART_OPS = new Set(["partGet", "partPlace", "partLift", "partAngles", "partMove", "partScale", "partRotate", "partTurn", "fallStart", "grabStart", "partSettle", "partPutDown", "partOrder", "partAction", "partCut", "partStep", "paintOpen", "paintSet", "labelsGet", "labelAdd", "labelUpdate", "labelRemove", "labelInfo", "partSettings", "partSettingSet", "partFill", "partToPlate"]);

export class Client {
  constructor(onEvent) {
    this.worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
    this.next = 1;
    this.waiting = new Map();
    this.worker.onmessage = (e) => {
      const m = e.data;
      if (m.event === "cancel-flag") {
        this.cancelFlag = { memory: m.memory, address: m.address };
        return;
      }
      if (m.event) {
        onEvent(m);
        return;
      }
      const w = this.waiting.get(m.id);
      if (!w) return;
      this.waiting.delete(m.id);
      // The worker is done with each request up to this one.
      this.sel?.answered(w.gen);
      if (m.error) w.reject(new Error(m.error));
      else w.resolve(m.result);
    };
    this.worker.onerror = (e) => onEvent({ event: "crashed", error: e.message });
  }

  call(op, args = {}, transfer = []) {
    if (this.cancelFlag && SLICE_OPS.has(op)) {
      // memory.buffer again each time: a grow of the memory makes a new one.
      Atomics.store(new Uint8Array(this.cancelFlag.memory.buffer), this.cancelFlag.address, 1);
    }
    const id = this.next++;
    const gen = this.sel?.gen ?? 0;
    const ids = this.sel ? this.partIds(op, args) : null;
    return new Promise((resolve, reject) => {
      this.waiting.set(id, { resolve, reject, gen });
      this.worker.postMessage({ id, op, ...args, ...ids }, transfer);
    });
  }

  // The stable ids of the parts that a call names by index.
  partIds(op, args) {
    const sel = this.sel;
    const out = {};
    if (PART_OPS.has(op) && args.index >= 0) out.partId = sel.idAt(args.index);
    if (op === "partBoxes" && args.except >= 0) out.exceptId = sel.idAt(args.except);
    if (Array.isArray(args.indices)) out.partIds = args.indices.map((i) => sel.idAt(i));
    if (Array.isArray(args.moves)) out.moves = args.moves.map((m) => ({ ...m, id: sel.idAt(m.index) }));
    return out;
  }
}
