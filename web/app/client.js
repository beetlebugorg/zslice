// client.js: the page side of the worker (worker.js). Each call returns a
// promise of the answer; the events of the worker go to `onEvent`.
//
// A change that starts a slice stops the slice that runs first: the worker
// cannot take the call while it slices, so with a shared memory (the module
// with threads) the page sets the cancel flag of the app itself.

// The calls that start a slice.
const SLICE_OPS = new Set(["set", "reset", "quality", "profile", "setScoped", "resetScoped", "load", "add", "plate", "projectLoad", "partAction", "partSettingSet", "partPutDown", "partTurn",
  "putDown", "place", "partMove", "partRotate", "markAdd", "markRemoveNear", "markSet", "markRemove", "marksClear",
  "undo", "redo", "historyGoto", "historyRevert", "historyTruncate"]);
//
// SPDX-License-Identifier: AGPL-3.0-or-later

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
    return new Promise((resolve, reject) => {
      this.waiting.set(id, { resolve, reject });
      this.worker.postMessage({ id, op, ...args }, transfer);
    });
  }
}
