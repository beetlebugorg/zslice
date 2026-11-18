// signing.js: the signing key of zslice in this browser, and the signature
// of each G-code file that the app exports or sends (src/gcode_sign.zig).
//
// The key is an Ed25519 key pair of WebCrypto. The private key is not
// extractable: the page can sign with it, but no script can read its
// bytes. IndexedDB keeps the key pair (a CryptoKey can go in IndexedDB
// as it is). A browser with no Ed25519 in WebCrypto makes no key: the
// files then go out with no signature, and supported() is false.
//
// The signature line is the last line of the file:
//   ; zslice-signature: ed25519 <key id> <base64 signature>
// The signature is Ed25519 (RFC 8032) over the SHA-256 hash (FIPS 180-4)
// of all bytes before that line. The key id is the first 8 bytes of the
// SHA-256 hash of the public key, in hex. See REFERENCES.md.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const DB = "zslice-signing";
const STORE = "keys";
const PREFIX = "; zslice-signature: ";

// The message for a browser with no Ed25519.
export const UNSUPPORTED =
  "This browser has no Ed25519 signatures (WebCrypto), so zslice sends prints with no signature. A printdeck with Signed prints only refuses them. Use a current Chrome, Edge, Firefox, or Safari.";

let keyPromise = null;

function openDb() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

function idb(db, mode, f) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const r = f(tx.objectStore(STORE));
    tx.oncomplete = () => resolve(r.result);
    tx.onerror = () => reject(tx.error);
  });
}

function b64(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function hex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

// The key: { pair, publicText, id }, or null with no Ed25519.
async function load() {
  if (!globalThis.crypto?.subtle) return null;
  let pair = null;
  let db = null;
  try {
    db = await openDb();
    pair = await idb(db, "readonly", (s) => s.get("main"));
  } catch {
    // No IndexedDB (a private window in some browsers): a key for this page only.
  }
  if (!pair) {
    try {
      pair = await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
    } catch {
      return null;
    }
    if (db) {
      try {
        await idb(db, "readwrite", (s) => s.put(pair, "main"));
      } catch {
        // The key stays for this page only.
      }
    }
  }
  db?.close();
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", raw));
  return { pair, publicText: `ed25519 ${b64(raw)}`, id: hex(h.subarray(0, 8)) };
}

function key() {
  keyPromise ??= load();
  return keyPromise;
}

// True when this browser can sign.
export async function supported() {
  return (await key()) !== null;
}

// The public key text ("ed25519 <base64>"), or "".
export async function publicKey() {
  return (await key())?.publicText ?? "";
}

// The key id (16 hex characters), or "".
export async function keyId() {
  return (await key())?.id ?? "";
}

// The bytes before the signature line of `bytes` (all bytes with no line).
export function body(bytes) {
  let end = bytes.length;
  if (end > 0 && bytes[end - 1] === 10) end--;
  if (end > 0 && bytes[end - 1] === 13) end--;
  let start = bytes.lastIndexOf(10, end - 1) + 1;
  if (end === 0) start = 0;
  const line = new TextDecoder().decode(bytes.subarray(start, Math.min(end, start + PREFIX.length)));
  return line === PREFIX ? bytes.subarray(0, start) : bytes;
}

// A signed copy of the G-code (a Uint8Array). An old signature line goes
// away first. With no key, the same bytes.
export async function signGcode(bytes) {
  const k = await key();
  if (!k) return bytes;
  let b = body(bytes);
  if (b.length > 0 && b[b.length - 1] !== 10) {
    const nl = new Uint8Array(b.length + 1);
    nl.set(b);
    nl[b.length] = 10;
    b = nl;
  }
  const digest = await crypto.subtle.digest("SHA-256", b);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, k.pair.privateKey, digest));
  const line = new TextEncoder().encode(`${PREFIX}ed25519 ${k.id} ${b64(sig)}\n`);
  const out = new Uint8Array(b.length + line.length);
  out.set(b);
  out.set(line, b.length);
  return out;
}
