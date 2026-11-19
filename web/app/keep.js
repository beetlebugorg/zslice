// keep.js: the work of the page across a refresh: the plate (a 3MF file
// of the core, zs_app_write_3mf, with the parts, their places, their
// settings, and the changes for some layers) in IndexedDB. The settings
// are in localStorage (app.js). All of it stays in this browser: nothing
// goes to a server (see PRIVACY.md).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const DB = "zslice";
const STORE = "work";

function open() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

async function run(mode, fn) {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const r = fn(tx.objectStore(STORE));
      tx.oncomplete = () => resolve(r?.result);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  } finally {
    db.close();
  }
}

// Keeps the plate: { name, bytes (an ArrayBuffer of a 3MF file) }. A
// browser that refuses storage (a private window) keeps nothing.
export async function savePlate(name, bytes) {
  try {
    await run("readwrite", (s) => s.put({ name, bytes, time: Date.now() }, "plate"));
  } catch {
    // No storage: the work lasts for this page only.
  }
}

// The kept plate, or null.
export async function loadPlate() {
  try {
    return (await run("readonly", (s) => s.get("plate"))) ?? null;
  } catch {
    return null;
  }
}

export async function clearPlate() {
  try {
    await run("readwrite", (s) => s.delete("plate"));
  } catch {
    // Nothing to clear.
  }
}

// The session of the core (zs_session_write): all plates, their last
// scenes, and the camera, as one file. A browser that refuses storage
// keeps nothing.
// `tag`: the project of the plates (project.js sessionTag), or null.
// `map`: the plan plate of each plate of the session (project.js setMap).
export async function saveSession(bytes, tag = null, map = null) {
  try {
    await run("readwrite", (s) => s.put({ bytes, time: Date.now(), tag, map }, "session"));
  } catch {
    // A private window: no session.
  }
}

export async function loadSession() {
  try {
    return (await run("readonly", (s) => s.get("session"))) ?? null;
  } catch {
    return null;
  }
}
