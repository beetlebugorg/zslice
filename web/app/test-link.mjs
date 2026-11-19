// A test of the printer link of the web app (link.js) in Node.js: the API
// key must not leave the printer. Two local servers: the "printer"
// redirects /api/version to the "other" server, which records the key of
// each request. Addresses from a deck must stay on the deck.
//
// Run: node web/app/test-link.mjs
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { createServer } from "node:http";
import { deckAddress, fetchOptions, plainName, test, webAddress } from "./link.js";

function check(ok, what) {
  if (!ok) throw new Error(`failed: ${what}`);
}

function listen(handler) {
  return new Promise((resolve) => {
    const s = createServer(handler);
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
}

const seen = [];
const other = await listen((req, res) => {
  seen.push(req.headers["x-api-key"] ?? "");
  res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  res.end('{"text": "OctoPrint"}');
});
const otherUrl = `http://127.0.0.1:${other.address().port}`;
const printer = await listen((req, res) => {
  res.writeHead(302, { Location: `${otherUrl}${req.url}` });
  res.end();
});
const printerUrl = `http://127.0.0.1:${printer.address().port}`;

// A redirect to another host: the request stops, and the key stays.
const r = await test({ name: "p", kind: "octoprint", url: printerUrl, apiKey: "secret-key" });
check(!r.ok, "a redirect with the key fails");
check(!seen.includes("secret-key"), "the other host got no key");
// A request with no key may follow a redirect.
check(fetchOptions(printerUrl, {}).redirect === "follow", "no key: follow");
check(fetchOptions(printerUrl, { headers: { "X-Api-Key": "k" } }).redirect === "error", "a key: no redirect");

// Addresses from outside.
check(webAddress("javascript:alert(1)") === "", "javascript: is not an address");
check(webAddress("data:text/html,x") === "", "data: is not an address");
check(webAddress("https://deck.local/") === "https://deck.local/", "https is an address");
check(deckAddress("http://deck.local", "/printers/p2") === "http://deck.local/printers/p2", "a path of the deck");
check(deckAddress("http://deck.local", "") === "http://deck.local", "the deck itself");
check(deckAddress("http://deck.local", "@evil.example/") === "", "no user part to another host");
check(deckAddress("http://deck.local", "//evil.example/") === "", "no other host");
check(deckAddress("http://deck.local", ".evil.example/") === "", "no other name");
check(deckAddress("http://deck.local", "/a/../../b") === "http://deck.local/a/../../b", "dots stay on the deck");
check(!plainName("__proto__") && !plainName("constructor") && plainName("TAZ 6") && !plainName(""), "plain names");

printer.close();
other.close();
console.log("ok");
