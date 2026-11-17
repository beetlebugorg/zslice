// thread.js: one thread of the slice, for the wasm module with threads
// (zslice-mt.wasm). The worker of the app core (worker.js) starts some of
// these workers. Each one makes an instance of the module on the memory of
// the core, and waits in the core for work (zs_thread_run does not return).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

self.onmessage = async (e) => {
  const { module, memory, index, stackTop, tls } = e.data;
  // The events of a slice come from the thread that starts the slice.
  const instance = await WebAssembly.instantiate(module, { env: { memory, zs_web_event: () => {} } });
  instance.exports.zs_thread_run(index, stackTop, tls);
};
