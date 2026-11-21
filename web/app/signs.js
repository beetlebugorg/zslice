// The signs of the plates: a small card on the bed just in front of each
// plate, with its number and name, its printer, and its status (or its
// print time and filament after a slice).
//
// This file draws the text of all signs into one image with a 2D canvas.
// The core view (zs_view_set_signs) draws each sign as a flat quad on the
// bed with that image, in the world: the signs turn and tilt with the
// plates, and the parts hide them. The Linux shell draws the same cards
// with cairo (linux/src/ui/preview.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { formatTime } from "./format.js";

// The pixels of the image for one CSS pixel of the sign: the text stays
// sharp up close and on a screen with a high density.
const S = 2;
// The height of a sign on the screen (CSS pixels), within the limits of
// the core.
const SCREEN_H = 46;

// The second line of a plate: its printer, then its status, or its time
// and filament after a slice.
const STATUS = { empty: "Empty", stale: "To slice", slicing: "Slicing", failed: "The slice failed", resin: "Resin: not yet" };
const PRINT = { printing: "Printing", printed: "Printed", failed: "Print failed" };

// The lines of the sign of plate i. p: the plate (app.plates); totals: its
// { timeS, filamentG } or null; print: its print status in a project.
export function signLines(p, i, totals, print) {
  const title = `${i + 1}  ${p.name || "Empty plate"}`;
  const facts = [];
  if (p.printer) facts.push(p.printer);
  if (p.status === "done" && totals) facts.push(`${formatTime(totals.timeS)} · ${totals.filamentG.toFixed(1)} g`);
  else if (STATUS[p.status]) facts.push(STATUS[p.status]);
  if (print && PRINT[print]) facts.push(PRINT[print]);
  return { title, sub: facts.join(" · ") };
}

// Draws the signs: signs is a list of { title, sub, active } (null: no
// sign). dark: the colors of a dark view. dpr: the device pixels of a CSS
// pixel. Returns { rects, width, height, rgba, scale } for
// View3D.setSigns.
export function drawSigns(signs, dark, dpr, accent = "#3584e4") {
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  const font = (w, px) => `${w} ${px * S}px Inter, Cantarell, system-ui, sans-serif`;
  const pad = 10 * S;
  const bar = 4 * S;
  const h1 = 15;
  const h2 = 12.5;
  const height = Math.round(pad * 2 + (h1 * 1.25 + h2 * 1.35) * S);
  // The width of each sign: its longest line, with no shortening.
  const widths = signs.map((s) => {
    if (!s) return 0;
    ctx.font = font(700, h1);
    const a = ctx.measureText(s.title).width;
    ctx.font = font(400, h2);
    const b = s.sub ? ctx.measureText(s.sub).width : 0;
    return Math.ceil(Math.max(a, b, 90 * S) + pad * 2 + bar);
  });
  const W = Math.max(1, ...widths);
  // Each sign in its own row, with a clear row between them, so the
  // filtered pixels of one do not reach the next.
  const gap = 4;
  const H = Math.max(1, signs.length * (height + gap));
  canvas.width = W;
  canvas.height = H;
  const rects = [];
  signs.forEach((s, i) => {
    if (!s) {
      rects.push(null);
      return;
    }
    const y = i * (height + gap);
    const w = widths[i];
    const r = 9 * S;
    ctx.beginPath();
    ctx.roundRect(1, y + 1, w - 2, height - 2, r);
    ctx.fillStyle = dark ? "rgba(40, 40, 44, 0.9)" : "rgba(255, 255, 255, 0.92)";
    ctx.fill();
    ctx.lineWidth = S;
    ctx.strokeStyle = s.active ? accent : dark ? "rgba(255, 255, 255, 0.16)" : "rgba(0, 0, 0, 0.14)";
    ctx.stroke();
    // The active plate: a bar in the accent color at the left.
    if (s.active) {
      ctx.save();
      ctx.clip();
      ctx.fillStyle = accent;
      ctx.fillRect(0, y, bar + 1, height);
      ctx.restore();
    }
    ctx.textBaseline = "alphabetic";
    ctx.fillStyle = dark ? "#f6f5f4" : "#241f31";
    ctx.font = font(700, h1);
    ctx.fillText(s.title, bar + pad, y + pad + h1 * S);
    if (s.sub) {
      ctx.fillStyle = dark ? "#c0bfbc" : "#5e5c64";
      ctx.font = font(400, h2);
      ctx.fillText(s.sub, bar + pad, y + pad + (h1 * 1.25 + h2 * 1.1) * S);
    }
    rects.push([0, y, w, height]);
  });
  const rgba = new Uint8Array(ctx.getImageData(0, 0, W, H).data.buffer);
  return { rects, width: W, height: H, rgba, scale: height / (SCREEN_H * dpr) };
}
