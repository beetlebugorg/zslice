// A test of the signatures of the web app (signing.js) in Node.js: the
// browser signs with WebCrypto, and the core (zs_verify_gcode, the same
// check as a printdeck) checks the file.
//
// Run: zig build web && node web/app/test-signing.mjs zig-out/web/app/zslice.wasm
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { readFile } from "node:fs/promises";
import { Wasm } from "./wasm.js";
import { body, keyId, publicKey, signGcode, supported } from "./signing.js";

const [wasmPath] = process.argv.slice(2);
if (!wasmPath) {
  console.error("usage: node web/app/test-signing.mjs <zslice.wasm>");
  process.exit(2);
}

function check(ok, what) {
  if (!ok) throw new Error(`failed: ${what}`);
}

const wasm = await Wasm.create(await WebAssembly.compile(await readFile(wasmPath)));
const enc = new TextEncoder();

// zs_verify_gcode: [result, key id].
function verify(bytes, trusted) {
  const out = wasm.alloc(4 + 17);
  try {
    const st = wasm.withBytes(bytes, (p, n) => wasm.withString(trusted, (t) => wasm.x.zs_verify_gcode(p, n, t, out, out + 4)));
    check(st === 0, "the status of zs_verify_gcode");
    return [wasm.i32(out), wasm.cstr(out + 4)];
  } finally {
    wasm.free(out, 4 + 17);
  }
}

check(await supported(), "Ed25519 in WebCrypto");
const pub = await publicKey();
const id = await keyId();
check(/^ed25519 [A-Za-z0-9+/]{43}=$/.test(pub) && /^[0-9a-f]{16}$/.test(id), "the key texts");

// The key id of the core is the key id of the browser.
const idOut = wasm.alloc(17);
wasm.withString(pub, (p) => wasm.x.zs_sign_key_id(p, idOut, 17));
check(wasm.cstr(idOut) === id, "the key id");
wasm.free(idOut, 17);

const gcode = enc.encode("G28\nM104 S200\nG1 X10 Y10");
const signed = await signGcode(gcode);
const text = new TextDecoder().decode(signed);
check(text.startsWith("G28\nM104 S200\nG1 X10 Y10\n; zslice-signature: ed25519 " + id + " ") && text.endsWith("\n"), "the signature line");
let [res, got] = verify(signed, pub);
check(res === 0 && got === id, "a good signature");

// One changed byte fails.
const bad = signed.slice();
bad[10] ^= 1;
check(verify(bad, pub)[0] !== 0, "a changed byte");
// An unknown key, and no signature.
check(verify(signed, "ed25519 6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=")[0] === 2, "an unknown key");
check(verify(gcode, pub)[0] === 1, "unsigned");
// A second signature replaces the first.
const again = await signGcode(signed);
check(new TextDecoder().decode(again).split("zslice-signature").length === 2 && verify(again, pub)[0] === 0, "a second signature");
check(body(signed).length === gcode.length + 1, "the body");

console.log(`signing: ok (key ${id})`);
