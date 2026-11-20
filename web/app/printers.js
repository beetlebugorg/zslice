// printers.js: the printer picker of the web app, as the GTK shell has it
// (linux/src/ui/printer-picker.c). The data is the printer library of the
// core (zs_printers_* in include/zslice-app.h). The wasm module does not
// embed the library: the page fetches printers.txt when the picker opens
// the first time, and gives the bytes to zs_printers_load.
//
// Two steps: choose (a search as you type, the brands, the models, a
// drawing of the build volume, and the key facts), then set up (the name,
// the nozzle, the filament, the bed, and the address of the printer).
// A browser cannot send the UDP packets of mDNS, so the picker cannot find
// printers on the network: it asks for the address, and says why.
//
// SPDX-License-Identifier: AGPL-3.0-or-later


const MAX_ROWS = 400;

let lib = 0;          // the zs_printers pointer in the main wasm instance
let loading = null;

// zs_printer_model on wasm32 (pointers and size_t are 4 bytes, doubles are
// aligned to 8). See include/zslice-app.h.
const MODEL_SIZE = 128;

// Gives the bytes of printers.txt to the core. The Node test calls it.
export function loadLibrary(wasm, bytes) {
  const out = wasm.cell;
  const rc = wasm.withBytes(bytes, (p, n) => wasm.x.zs_printers_load(p, n, out));
  if (rc !== 0) throw new Error(`the printer library did not load (status ${rc})`);
  lib = wasm.u32(out);
  return lib;
}

async function load(wasm) {
  if (lib) return lib;
  if (!loading) {
    loading = (async () => {
      const r = await fetch("printers.txt");
      if (!r.ok) throw new Error(`printers.txt: HTTP ${r.status}`);
      return loadLibrary(wasm, new Uint8Array(await r.arrayBuffer()));
    })();
  }
  return loading;
}

// The bed model of the printer of a machine profile (its settings
// machine.model and machine.name), for the 3D view: { index, mesh,
// texture } with the bytes of the files in beds/, or null if the model
// has none. The library and the files load only for a printer with a bed
// model in the library.
export async function bedFiles(wasm, modelId, name) {
  if (!modelId && !name) return null;
  const l = await load(wasm);
  const i = wasm.withStrings([modelId ?? "", name ?? ""], (a, b) => wasm.x.zs_printers_find_machine(l, a, b));
  if (i < 0) return null;
  const p = wasm.alloc(12);
  let names;
  try {
    if (wasm.x.zs_printers_bed(l, i, p) !== 0) return null;
    names = [wasm.cstr(wasm.u32(p)), wasm.cstr(wasm.u32(p + 4))];
  } finally {
    wasm.free(p, 12);
  }
  const get = async (n) => {
    if (!n) return null;
    const r = await fetch(`beds/${encodeURIComponent(n)}`);
    return r.ok ? new Uint8Array(await r.arrayBuffer()) : null;
  };
  const [mesh, texture] = await Promise.all(names.map(get));
  if (!mesh && !texture) return null;
  return { lib: l, index: i, mesh, texture };
}

export function model(wasm, i) {
  const p = wasm.alloc(MODEL_SIZE);
  try {
    if (wasm.x.zs_printers_model_get(lib, i, p) !== 0) return null;
    const s = (o) => wasm.cstr(wasm.u32(p + o));
    const b = (o) => wasm.u8[p + o] !== 0;
    return {
      index: i,
      id: s(0), brand: s(4), brandIndex: wasm.u32(p + 8), name: s(12), series: s(16),
      bedX: wasm.f64(p + 24), bedY: wasm.f64(p + 32), height: wasm.f64(p + 40),
      originX: wasm.f64(p + 48), originY: wasm.f64(p + 56),
      round: b(64), heatedBed: b(65), heatedChamber: b(66), klipper: b(67), hasStartGcode: b(68),
      nozzle: wasm.f64(p + 72), nozzles: s(80), filament: wasm.f64(p + 88),
      maxSpeed: wasm.f64(p + 96), maxAccel: wasm.f64(p + 104),
      firmware: s(112), kinematics: s(116), extruders: wasm.u32(p + 120), title: s(124),
    };
  } finally {
    wasm.free(p, MODEL_SIZE);
  }
}

export function brands(wasm) {
  const out = [];
  const n = wasm.x.zs_printers_brand_count(lib);
  const p = wasm.alloc(12);
  try {
    for (let i = 0; i < n; i++) {
      wasm.x.zs_printers_brand_get(lib, i, p, p + 4, p + 8);
      out.push({ name: wasm.cstr(wasm.u32(p)), count: wasm.u32(p + 8) - wasm.u32(p + 4) });
    }
  } finally {
    wasm.free(p, 12);
  }
  return out;
}

// The printers that most people have (zs_printers_popular), for the
// Popular group that the picker shows first.
export function popularModels(wasm) {
  const p = wasm.alloc(64 * 4);
  try {
    const n = wasm.x.zs_printers_popular(lib, p, 64);
    const out = [];
    for (let k = 0; k < n; k++) out.push(wasm.u32(p + 4 * k));
    return out;
  } finally {
    wasm.free(p, 64 * 4);
  }
}

export function search(wasm, query, brand) {
  const p = wasm.alloc(MAX_ROWS * 4);
  try {
    const n = wasm.withString(query, (q) => wasm.x.zs_printers_search(lib, q, brand, p, MAX_ROWS));
    const shown = Math.min(n, MAX_ROWS);
    const idx = [];
    for (let k = 0; k < shown; k++) idx.push(wasm.u32(p + 4 * k));
    return { total: n, idx };
  } finally {
    wasm.free(p, MAX_ROWS * 4);
  }
}

const text = (wasm, fn, i, ...args) => wasm.readText((buf, cap, len) => fn(lib, i, ...args, buf, cap, len));

// The library model of a product name that a printer tells ("Bambu Lab
// X2D", "LulzBot TAZ Workhorse"): { model, profile } with its machine
// profile, or null when no model has all the words of the name.
export async function findModel(wasm, product) {
  const words = (s) => String(s ?? "").toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  const want = words(product);
  if (want.length === 0) return null;
  await load(wasm);
  const { idx } = search(wasm, product, -1);
  for (const i of idx.slice(0, 8)) {
    const m = model(wasm, i);
    if (!m) continue;
    const have = words(`${m.brand} ${m.name} ${m.title}`);
    if (want.every((w) => have.includes(w))) return { model: m, profile: profileText(wasm, i, m.nozzle) };
  }
  return null;
}

// The machine profile of model i (zs_printers_profile).
export function profileText(wasm, i, nozzle) {
  return text(wasm, wasm.x.zs_printers_profile, i, nozzle);
}

// ---- the drawing of the build volume (draw_volume in printer-picker.c) ----

// The flat bed textures for the plate of the drawing (zs_printer_bed.flat):
// model index to an Image, or null for none. `done` runs when an image
// loads. zs_printer_bed on wasm32: three pointers and a bool (16 bytes).
const bedImages = new Map();
function bedImage(wasm, i, done) {
  if (bedImages.has(i)) {
    const im = bedImages.get(i);
    return im?.complete && im.naturalWidth > 0 ? im : null;
  }
  let im = null;
  const p = wasm.alloc(16);
  try {
    if (wasm.x.zs_printers_bed(lib, i, p) === 0 && wasm.u8[p + 12] !== 0) {
      im = new Image();
      im.onload = done;
      im.src = `beds/${encodeURIComponent(wasm.cstr(wasm.u32(p + 4)))}`;
    }
  } finally {
    wasm.free(p, 16);
  }
  bedImages.set(i, im);
  return null;
}

function iso(x, y, z) {
  return [(x + y) * 0.866, (x - y) * 0.5 - z];
}

function drawVolume(canvas, v) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  canvas.width = Math.max(1, Math.round(w * dpr));
  canvas.height = Math.max(1, Math.round(h * dpr));
  const cr = canvas.getContext("2d");
  cr.setTransform(dpr, 0, 0, dpr, 0, 0);
  cr.clearRect(0, 0, w, h);
  const fg = "rgba(255,255,255,";
  const accent = "rgba(53,132,228,";
  if (!v) {
    cr.fillStyle = fg + "0.45)";
    cr.font = "14px sans-serif";
    cr.textAlign = "center";
    cr.fillText("Pick a printer to see its build volume", w / 2, h / 2);
    return;
  }
  const pts = [];
  for (const x of [0, v.bx]) for (const y of [0, v.by]) for (const z of [0, v.bz]) pts.push(iso(x, y, z));
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
  const padx = 84, pady = 40;
  const s = Math.min((w - 2 * padx) / (x1 - x0), (h - 2 * pady) / (y1 - y0));
  if (!(s > 0)) return;
  const cx = w / 2 - ((x0 + x1) / 2) * s, cy = h / 2 - ((y0 + y1) / 2) * s;
  const P = (x, y, z) => { const [a, b] = iso(x, y, z); return [cx + a * s, cy + b * s]; };
  const r = v.bx / 2;
  const path = (points, close) => {
    cr.beginPath();
    points.forEach(([a, b], i) => (i ? cr.lineTo(a, b) : cr.moveTo(a, b)));
    if (close) cr.closePath();
  };
  const circle = (z) => Array.from({ length: 97 }, (_, i) => P(r + r * Math.cos((i * 2 * Math.PI) / 96), r + r * Math.sin((i * 2 * Math.PI) / 96), z));
  cr.lineJoin = cr.lineCap = "round";
  // The plate.
  path(v.round ? circle(0) : [P(0, 0, 0), P(v.bx, 0, 0), P(v.bx, v.by, 0), P(0, v.by, 0)], true);
  cr.fillStyle = accent + "0.16)";
  cr.fill();
  // The bed texture of the model on the plate: the image spans the plate,
  // its top row at the back. In the isometric view this is one affine map.
  if (v.tex) {
    const iw = v.tex.naturalWidth, ih = v.tex.naturalHeight;
    cr.save();
    cr.clip();
    cr.transform(0.866 * s * v.bx / iw, 0.5 * s * v.bx / iw, -0.866 * s * v.by / ih, 0.5 * s * v.by / ih, cx + 0.866 * s * v.by, cy - 0.5 * s * v.by);
    cr.globalAlpha = 0.55;
    cr.drawImage(v.tex, 0, 0);
    cr.restore();
  }
  cr.strokeStyle = accent + "0.9)";
  cr.lineWidth = 2;
  cr.stroke();
  // The grid.
  const step = Math.max(v.bx, v.by) > 160 ? 50 : 10;
  cr.beginPath();
  for (let x = step; x < v.bx - 0.5; x += step) {
    const d = v.round ? Math.sqrt(Math.max(r * r - (x - r) ** 2, 0)) : 0;
    const [a, b] = v.round ? [r - d, r + d] : [0, v.by];
    cr.moveTo(...P(x, a, 0));
    cr.lineTo(...P(x, b, 0));
  }
  for (let y = step; y < v.by - 0.5; y += step) {
    const d = v.round ? Math.sqrt(Math.max(r * r - (y - r) ** 2, 0)) : 0;
    const [a, b] = v.round ? [r - d, r + d] : [0, v.bx];
    cr.moveTo(...P(a, y, 0));
    cr.lineTo(...P(b, y, 0));
  }
  cr.strokeStyle = accent + "0.35)";
  cr.lineWidth = 1;
  cr.stroke();
  // The build volume.
  cr.strokeStyle = fg + "0.55)";
  cr.lineWidth = 1.2;
  if (v.round) {
    path(circle(v.bz), false);
    cr.stroke();
    cr.beginPath();
    for (const a of [Math.PI / 4 + Math.PI, Math.PI / 4]) {
      cr.moveTo(...P(r + r * Math.cos(a), r + r * Math.sin(a), 0));
      cr.lineTo(...P(r + r * Math.cos(a), r + r * Math.sin(a), v.bz));
    }
    cr.stroke();
  } else {
    cr.setLineDash([4, 4]);
    path([P(0, v.by, 0), P(0, v.by, v.bz)], false);
    cr.stroke();
    cr.setLineDash([]);
    cr.beginPath();
    for (const [x, y] of [[0, 0], [v.bx, 0], [v.bx, v.by]]) {
      cr.moveTo(...P(x, y, 0));
      cr.lineTo(...P(x, y, v.bz));
    }
    cr.stroke();
    path([P(0, 0, v.bz), P(v.bx, 0, v.bz), P(v.bx, v.by, v.bz), P(0, v.by, v.bz)], true);
    cr.stroke();
  }
  // The G-code origin.
  const gx = -v.ox, gy = -v.oy;
  if (gx >= -1 && gx <= v.bx + 1 && gy >= -1 && gy <= v.by + 1) {
    const [a, b] = P(gx, gy, 0);
    cr.fillStyle = "rgba(224,28,36,0.95)";
    cr.beginPath();
    cr.arc(a, b, 3.5, 0, 2 * Math.PI);
    cr.fill();
  }
  // The sizes.
  cr.fillStyle = fg + "0.85)";
  cr.font = "bold 13px sans-serif";
  cr.textBaseline = "middle";
  const label = (pt, t, align, dx, dy) => { cr.textAlign = align; cr.fillText(t, pt[0] + dx, pt[1] + dy); };
  if (v.round) {
    const a = -Math.PI / 4;
    label(P(r + r * Math.cos(a), r + r * Math.sin(a), 0), `⌀ ${Math.round(v.bx)} mm`, "center", 0, 16);
    const z = Math.PI / 4 + Math.PI;
    label(P(r + r * Math.cos(z), r + r * Math.sin(z), v.bz / 2), `Z ${Math.round(v.bz)} mm`, "right", -10, 0);
  } else {
    label(P(v.bx / 2, 0, 0), `X ${Math.round(v.bx)} mm`, "center", -10, 16);
    label(P(v.bx, v.by / 2, 0), `Y ${Math.round(v.by)} mm`, "left", 10, 14);
    label(P(0, 0, v.bz / 2), `Z ${Math.round(v.bz)} mm`, "right", -10, 0);
  }
}

// ---- the window ----

function el(tag, cls, txt) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (txt !== undefined) e.textContent = txt;
  return e;
}

const fmt = (v) => String(Math.round(v * 1000) / 1000);

// Opens the picker. onAdd({ name, profile, filament, bedX, bedY, height,
// url }) adds the printer. hooks: { welcome } for the first visit, and
// { query, model, step } for tests (step "2": the second step, "add": add
// the printer at once).
export async function openPrinterPicker(wasm, onAdd, hooks = {}) {
  const shade = el("div", "picker-shade");
  const win = el("div", "picker");
  win.setAttribute("role", "dialog");
  win.setAttribute("aria-label", "Add a printer");
  shade.append(win);
  document.body.append(shade);
  const close = () => shade.remove();

  const head = el("div", "picker-head");
  const cancel = el("button", "", hooks.welcome ? "Skip" : "Cancel");
  const back = el("button", "icon", "‹");
  back.title = "Back to the list";
  back.hidden = true;
  const title = el("div", "picker-title", hooks.welcome ? "Welcome to zslice: set up your printer" : "Add a printer");
  const next = el("button", "suggested", "Next");
  next.disabled = true;
  head.append(cancel, back, title, next);
  win.append(head);
  const body = el("div", "picker-body");
  body.textContent = "Loading the printer library…";
  win.append(body);
  cancel.onclick = close;

  try {
    await load(wasm);
  } catch (e) {
    body.textContent = `The printer library did not load: ${e.message}`;
    return;
  }
  body.textContent = "";

  // A beginner starts with the printers that most people have
  // ("Popular"), and not with the whole list in the order of the alphabet.
  const st = { brand: -2, current: -1 };
  const popular = popularModels(wasm);
  const allBrands = brands(wasm);
  const total = wasm.x.zs_printers_model_count(lib);

  // Step 1.
  const choose = el("div", "picker-choose");
  const side = el("div", "picker-side");
  side.append(el("div", "picker-section", "On your network"));
  side.append(el("div", "picker-note",
    "A web page cannot search the network: browsers do not allow the mDNS packets that find printers. Enter the address of your printer in the next step. The zslice apps for Linux and macOS find printers by themselves."));
  side.append(Object.assign(el("div", "picker-section", "Brands"), { style: "margin-top:10px" }));
  const brandList = el("div", "picker-list brands");
  const brandRow = (name, count, index) => {
    const b = el("button", "picker-brand");
    b.append(el("span", "", name), el("span", "dim num", String(count)));
    b.onclick = () => { st.brand = index; markBrand(); fill(); };
    b.dataset.brand = index;
    return b;
  };
  if (popular.length > 0) brandList.append(brandRow("Popular", popular.length, -2));
  brandList.append(brandRow("All brands", total, -1));
  allBrands.forEach((b, i) => brandList.append(brandRow(b.name, b.count, i)));
  side.append(brandList);
  const markBrand = () => {
    for (const b of brandList.children) b.classList.toggle("selected", Number(b.dataset.brand) === st.brand);
    brandList.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
  };

  const mid = el("div", "picker-mid");
  const searchBox = el("input", "picker-search");
  searchBox.type = "search";
  searchBox.placeholder = "Search 1000+ printers: “ender 3”, “mk4”, “voron”";
  const count = el("div", "dim caption");
  const list = el("div", "picker-list models");
  mid.append(searchBox, count, list);

  const card = el("div", "picker-card");
  const cardTitle = el("div", "picker-name-big");
  const cardSub = el("div", "dim");
  const canvas = el("canvas", "picker-bed");
  const facts = el("div", "picker-facts");
  card.append(cardTitle, cardSub, canvas, facts);
  choose.append(side, mid, card);

  const volumeOf = (m) => m ? { bx: m.bedX, by: m.bedY, bz: m.height, ox: m.originX, oy: m.originY, round: m.round, tex: bedImage(wasm, m.index, () => updateCard()) }
    : st.current === -2 ? { bx: 220, by: 220, bz: 250, ox: 0, oy: 0, round: false } : null;

  const updateCard = () => {
    const m = st.current >= 0 ? model(wasm, st.current) : null;
    facts.replaceChildren();
    if (m) {
      cardTitle.textContent = m.title;
      cardSub.textContent = text(wasm, wasm.x.zs_printers_facts, m.index) ?? "";
      const others = m.nozzles.split(";").filter((x) => x && Math.abs(Number(x) - m.nozzle) > 1e-6);
      const rows = [
        ["Build volume", m.round ? `⌀ ${fmt(m.bedX)} mm round bed, ${fmt(m.height)} mm high` : `${fmt(m.bedX)} × ${fmt(m.bedY)} × ${fmt(m.height)} mm`],
        ["Nozzle", `${fmt(m.nozzle)} mm${others.length ? ` (also ${others.join(", ")})` : ""}`],
        ["Filament", `${fmt(m.filament)} mm`],
        ["Heating", m.heatedChamber ? "Heated bed and chamber" : m.heatedBed ? "Heated bed" : "No heated bed"],
        ["Firmware", m.firmware || "Marlin"],
      ];
      if (m.maxAccel > 0) rows.push(["Motion", m.maxSpeed > 0 ? `${fmt(m.maxAccel)} mm/s², up to ${fmt(m.maxSpeed)} mm/s` : `${fmt(m.maxAccel)} mm/s²`]);
      rows.push(["Start G-code", m.hasStartGcode ? "From the printer profile" : "The start G-code of zslice (the profile uses scripts). Check it before the first print."]);
      rows.push(["Data from", text(wasm, wasm.x.zs_printers_sources, m.index) ?? ""]);
      for (const [k, v] of rows) facts.append(el("div", "dim", k), el("div", "", v));
    } else if (st.current === -2) {
      cardTitle.textContent = "Another printer";
      cardSub.textContent = "Set the bed size and the nozzle yourself.";
      facts.append(el("div", "dim", "Settings"), el("div", "", "The generic printer of zslice. Enter the bed size in the next step."));
    } else {
      cardTitle.textContent = "No printer selected";
      cardSub.textContent = "Search, or pick a brand and a model.";
    }
    facts.hidden = st.current === -1;
    drawVolume(canvas, volumeOf(m));
    next.disabled = st.current === -1;
  };

  const select = (i) => {
    st.current = i;
    for (const r of list.children) r.classList.toggle("selected", Number(r.dataset.model) === i);
    updateCard();
  };

  const fill = () => {
    list.replaceChildren();
    const q = searchBox.value;
    const { total: n, idx } = st.brand === -2 && q === "" ? { total: popular.length, idx: popular } : search(wasm, q, st.brand === -2 ? -1 : st.brand);
    const bySeries = st.brand >= 0 && q === "";
    let group = null;
    for (const i of idx) {
      const m = model(wasm, i);
      if (bySeries && m.series !== group) {
        group = m.series;
        list.append(el("div", "picker-group", group));
      }
      const row = el("button", "picker-row");
      const t = el("div", "texts");
      t.append(el("div", "picker-name", m.name),
        el("div", "dim caption", bySeries ? `${m.firmware || "Marlin"}${m.heatedChamber ? " · heated chamber" : ""}` : `${m.brand} · ${m.firmware || "Marlin"}`));
      const r0 = Math.round;
      row.append(t, el("div", "dim num", m.round ? `⌀ ${r0(m.bedX)} × ${r0(m.height)}` : `${r0(m.bedX)} × ${r0(m.bedY)} × ${r0(m.height)}`));
      row.dataset.model = i;
      row.onclick = () => select(i);
      row.ondblclick = () => { select(i); goSetup(); };
      list.append(row);
    }
    const custom = el("button", "picker-row");
    const ct = el("div", "texts");
    ct.append(el("div", "picker-name", "＋ My printer is not in the list"), el("div", "dim caption", "Start from the generic printer, and enter its size"));
    custom.append(ct);
    custom.dataset.model = -2;
    custom.onclick = () => select(-2);
    list.append(custom);
    count.textContent = n === 0 ? `No printer matches “${q}”.` : idx.length < n ? `${n} printers; the first ${idx.length} show. Type to narrow the list.` : `${n} printer${n === 1 ? "" : "s"}`;
    for (const r of list.children) r.classList?.toggle("selected", Number(r.dataset.model) === st.current);
    list.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
  };
  searchBox.oninput = fill;
  searchBox.onkeydown = (e) => {
    if (e.key === "Enter") {
      const first = list.querySelector(".picker-row");
      if (first && Number(first.dataset.model) >= 0) select(Number(first.dataset.model));
    }
  };

  // Step 2.
  const setup = el("div", "picker-setup");
  setup.hidden = true;
  const left = el("div", "picker-card");
  const sumTitle = el("div", "picker-name-big");
  const sumFacts = el("div", "dim");
  const canvas2 = el("canvas", "picker-bed");
  left.append(sumTitle, sumFacts, canvas2);
  const form = el("div", "picker-form");
  const field = (label, input) => { form.append(el("label", "dim", label), input); return input; };
  form.append(Object.assign(el("div", "picker-section span", "Printer")));
  const nameIn = field("Name", el("input"));
  const nozzleIn = field("Nozzle", el("select"));
  const filIn = field("Filament", el("select"));
  for (const d of ["1.75", "2.85"]) filIn.append(Object.assign(el("option", "", `${d} mm`), { value: d }));
  const bedBox = el("div", "picker-bedbox");
  const num = () => Object.assign(el("input"), { type: "number", min: 10, max: 2000, step: 1 });
  const bx = num(), by = num(), bz = num();
  bedBox.append(bx, el("span", "", "×"), by, el("span", "", "×"), bz, el("span", "", "mm"));
  field("Build volume", bedBox);
  form.append(el("span"), el("div", "dim caption", "Change the size only if your printer differs from the profile."));
  form.append(Object.assign(el("div", "picker-section span", "Connection"), { style: "margin-top:12px" }));
  const urlIn = field("Address", Object.assign(el("input"), { placeholder: "http://printer.local" }));
  form.append(el("span"), el("div", "dim caption",
    "Browsers cannot search the network, so enter the address yourself. The web app keeps it with the printer; sending a print from a browser is not in the web app yet (the printer needs CORS headers)."));
  form.append(Object.assign(el("div", "dim caption span", "You can change all of this later in the Printer settings."), { style: "margin-top:12px" }));
  setup.append(left, form);
  const redraw2 = () => {
    const m = st.current >= 0 ? model(wasm, st.current) : null;
    const v = volumeOf(m);
    v.bx = Number(bx.value) || v.bx;
    v.by = m?.round ? v.bx : Number(by.value) || v.by;
    v.bz = Number(bz.value) || v.bz;
    drawVolume(canvas2, v);
  };
  bx.oninput = by.oninput = bz.oninput = redraw2;

  const goSetup = () => {
    if (st.current === -1) return;
    const m = st.current >= 0 ? model(wasm, st.current) : null;
    const name = m ? m.title : "My printer";
    nameIn.value = name;
    sumTitle.textContent = name;
    sumFacts.textContent = m ? text(wasm, wasm.x.zs_printers_facts, m.index) ?? "" : "The generic printer of zslice";
    nozzleIn.replaceChildren();
    const sizes = m && m.nozzles ? m.nozzles.split(";") : ["0.2", "0.25", "0.3", "0.4", "0.5", "0.6", "0.8", "1"];
    for (const z of sizes) nozzleIn.append(Object.assign(el("option", "", `${z} mm`), { value: z, selected: Math.abs(Number(z) - (m?.nozzle ?? 0.4)) < 1e-6 }));
    filIn.value = m && m.filament > 2.2 ? "2.85" : "1.75";
    const v = volumeOf(m);
    bx.value = fmt(v.bx);
    by.value = fmt(v.by);
    bz.value = fmt(v.bz);
    by.disabled = v.round;
    choose.hidden = true;
    setup.hidden = false;
    back.hidden = false;
    next.textContent = "Add printer";
    requestAnimationFrame(redraw2);
    nameIn.focus();
  };
  const goChoose = () => {
    choose.hidden = false;
    setup.hidden = true;
    back.hidden = true;
    next.textContent = "Next";
    updateCard();
  };
  back.onclick = goChoose;

  const finish = async () => {
    const nozzle = Number(nozzleIn.value) || 0;
    const profile = st.current >= 0 ? text(wasm, wasm.x.zs_printers_profile, st.current, nozzle) : `extends = "generic"\n`;
    close();
    await onAdd({
      name: nameIn.value || "My printer", profile, nozzle,
      filament: filIn.value, bedX: Number(bx.value), bedY: Number(by.value), height: Number(bz.value), url: urlIn.value,
    });
  };
  next.onclick = () => (setup.hidden ? goSetup() : finish());
  shade.onkeydown = (e) => {
    if (e.key === "Escape") {
      e.stopPropagation();
      if (!setup.hidden) goChoose();
      else close();
    }
  };

  body.append(choose, setup);
  markBrand();
  fill();
  updateCard();
  searchBox.focus();
  new ResizeObserver(() => { updateCard(); if (!setup.hidden) redraw2(); }).observe(canvas);

  // The test hooks (?printers&q=..&model=..&step=2).
  if (hooks.query) { searchBox.value = hooks.query; fill(); }
  if (hooks.model) {
    const i = wasm.withString(hooks.model, (p) => wasm.x.zs_printers_find(lib, p));
    if (i >= 0) {
      if (!hooks.query) { st.brand = model(wasm, i).brandIndex; markBrand(); fill(); }
      select(i);
      list.querySelector(".selected")?.scrollIntoView({ block: "center" });
    }
  }
  if (hooks.step === "2" || hooks.step === "add") goSetup();
  if (hooks.step === "add") await finish();
}
