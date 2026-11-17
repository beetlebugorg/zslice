// client.js: the page side of the worker (worker.js). Each call returns a
// promise of the answer; the events of the worker go to `onEvent`.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

export class Client {
  constructor(onEvent) {
    this.worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
    this.next = 1;
    this.waiting = new Map();
    this.worker.onmessage = (e) => {
      const m = e.data;
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
    const id = this.next++;
    return new Promise((resolve, reject) => {
      this.waiting.set(id, { resolve, reject });
      this.worker.postMessage({ id, op, ...args }, transfer);
    });
  }
}
