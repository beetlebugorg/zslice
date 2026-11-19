// project.js: the Project tab. A project is a repository with a
// printdeck.yml (src/project.zig): the parts to print, with their files,
// printer, Cura profile, material, and settings.
//
// - Open a project from GitHub ("owner/repo", or a github.com URL, also
//   with /tree/<branch>), or from a folder on this computer.
// - Choose the parts and their counts. The core puts them on plates: the
//   parts with the same printer, profile, material, and plate settings
//   share a plate.
// - Open a plate: the app loads its profiles (the Cura stack of
//   profiles/<folder>/), its settings, and its parts, and slices it. Then
//   print it as any other plate.
// - Each plate has a status (to print, printing, printed, failed). The
//   project, the counts, and the status stay in this browser
//   (localStorage) across a reload. After a reload, a GitHub project gets
//   its files again from GitHub; a folder must be opened again.
//
// GitHub: the app reads public repositories through api.github.com (the
// commit and the list of files, 3 requests) and raw.githubusercontent.com
// (the files that a plate needs). It sends no token. A file in Git LFS
// comes from media.githubusercontent.com.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import { el } from "./settings.js";

// A div with children.
function box(cls, ...children) {
  const d = el("div", cls);
  d.append(...children);
  return d;
}

const KEY = "zslice.project";

export const STATUS = {
  todo: "To print",
  printing: "Printing",
  printed: "Printed",
  failed: "Failed",
};

// "owner/repo", "github.com/owner/repo", or a URL with /tree/<ref>.
export function parseGithub(text) {
  let t = text.trim().replace(/\.git$/, "");
  t = t.replace(/^https?:\/\//, "").replace(/^(www\.)?github\.com\//, "");
  const m = /^([\w.-]+)\/([\w.-]+)(?:\/tree\/(.+))?\/?$/.exec(t);
  if (!m) return null;
  return { owner: m[1], repo: m[2], ref: m[3] ?? "" };
}

function load() {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "null");
  } catch {
    return null;
  }
}

function save(state) {
  try {
    if (state) localStorage.setItem(KEY, JSON.stringify(state));
    else localStorage.removeItem(KEY);
  } catch {
    // Storage is off: the project lasts for this page only.
  }
}

// The files of a GitHub repository at one commit.
class GithubSource {
  constructor(owner, repo, sha, paths) {
    this.owner = owner;
    this.repo = repo;
    this.sha = sha;
    this.paths = paths; // the paths of the files (blobs)
    this.cache = new Map();
  }

  static async open({ owner, repo, ref }) {
    const api = `https://api.github.com/repos/${owner}/${repo}`;
    const get = async (url) => {
      const r = await fetch(url, { headers: { Accept: "application/vnd.github+json" }, credentials: "omit" });
      if (r.status === 404) throw new Error(`GitHub has no public repository ${owner}/${repo}${ref ? ` with ${ref}` : ""}.`);
      if (r.status === 403 || r.status === 429) throw new Error("GitHub refused the request (the limit of requests with no login is 60 an hour). Try again later.");
      if (!r.ok) throw new Error(`GitHub answered ${r.status}.`);
      return r.json();
    };
    let branch = ref;
    if (!branch) branch = (await get(api)).default_branch;
    const commit = await get(`${api}/commits/${encodeURIComponent(branch)}`);
    const tree = await get(`${api}/git/trees/${commit.sha}?recursive=1`);
    const paths = tree.tree.filter((e) => e.type === "blob").map((e) => e.path);
    return new GithubSource(owner, repo, commit.sha, paths);
  }

  get label() {
    return `${this.owner}/${this.repo} @ ${this.sha.slice(0, 7)}`;
  }

  get saved() {
    return { kind: "github", owner: this.owner, repo: this.repo, sha: this.sha };
  }

  has(path) {
    return this.paths.includes(path);
  }

  list(folder) {
    return this.paths.filter((p) => p.startsWith(folder + "/"));
  }

  async read(path) {
    if (this.cache.has(path)) return this.cache.get(path);
    const enc = path.split("/").map(encodeURIComponent).join("/");
    const raw = `https://raw.githubusercontent.com/${this.owner}/${this.repo}/${this.sha}/${enc}`;
    let r = await fetch(raw, { credentials: "omit" });
    if (!r.ok) throw new Error(`GitHub has no file ${path} (${r.status}).`);
    let bytes = new Uint8Array(await r.arrayBuffer());
    // A Git LFS pointer: the file is in LFS storage.
    if (bytes.length < 400 && new TextDecoder().decode(bytes.subarray(0, 40)).startsWith("version https://git-lfs")) {
      r = await fetch(`https://media.githubusercontent.com/media/${this.owner}/${this.repo}/${this.sha}/${enc}`, { credentials: "omit" });
      if (!r.ok) throw new Error(`GitHub has no LFS file ${path} (${r.status}).`);
      bytes = new Uint8Array(await r.arrayBuffer());
    }
    this.cache.set(path, bytes);
    return bytes;
  }
}

// The files of a folder that the person chose (input webkitdirectory).
class FolderSource {
  constructor(name, files) {
    this.name = name;
    this.files = files; // Map path -> File
  }

  static fromList(list) {
    const files = new Map();
    let name = "";
    for (const f of list) {
      const parts = (f.webkitRelativePath || f.name).split("/");
      // The first part is the name of the folder.
      if (parts.length > 1) {
        name = parts[0];
        parts.shift();
      }
      files.set(parts.join("/"), f);
    }
    return new FolderSource(name, files);
  }

  get label() {
    return `the folder ${this.name}`;
  }

  get saved() {
    return { kind: "folder", name: this.name };
  }

  has(path) {
    return this.files.has(path);
  }

  list(folder) {
    return [...this.files.keys()].filter((p) => p.startsWith(folder + "/"));
  }

  async read(path) {
    const f = this.files.get(path);
    if (!f) throw new Error(`The folder has no file ${path}.`);
    return new Uint8Array(await f.arrayBuffer());
  }
}

// A key of a plate for its status: its printer, profile, material, and
// parts with their counts.
function plateKey(plan, plate) {
  const items = plate.items.map((it) => `${plan.parts[it.part].name}x${it.count}`).join(",");
  return `${plate.printer}|${plate.profile}|${plate.material}|${items}`;
}

export class ProjectPage {
  // ctx: { client, applySettings(r), toast(text), loading() (a plate
  //        loads), opened(name) (a plate is on the view), printers() (the names of the printers of the
  //        user), usePrinter(name) }
  constructor(root, ctx) {
    this.root = root;
    this.ctx = ctx;
    this.source = null;
    this.text = "";
    this.plan = null;
    this.state = load(); // { source, text, counts, status, active, setLoaded }
    this.busy = "";
    this.planned = Promise.resolve();
    this.render();
    // After a reload, a GitHub project gets its files again; app.js calls
    // restoreSet when the worker is ready, and the plates load again if
    // they were on the view.
    this.reopened = this.state?.source?.kind === "github" ? this.reopen() : Promise.resolve();
  }

  // ---- open ----

  async openGithub(text) {
    const g = parseGithub(text);
    if (!g) {
      this.ctx.toast("Type owner/repo, or the address of a repository on github.com.");
      return;
    }
    await this.run(`Opening ${g.owner}/${g.repo}…`, async () => {
      const src = await GithubSource.open(g);
      await this.use(src);
    });
  }

  async openFolder(list) {
    const src = FolderSource.fromList(list);
    await this.run("Opening the folder…", () => this.use(src));
  }

  // GitHub again, at the commit of the saved project.
  async reopen() {
    const s = this.state?.source;
    if (s?.kind !== "github") return;
    try {
      const api = await fetch(`https://api.github.com/repos/${s.owner}/${s.repo}/git/trees/${s.sha}?recursive=1`, { credentials: "omit" });
      if (!api.ok) return;
      const tree = await api.json();
      this.source = new GithubSource(s.owner, s.repo, s.sha, tree.tree.filter((e) => e.type === "blob").map((e) => e.path));
      this.render();
    } catch {
      // No network: the plates show, and an open says why.
    }
  }

  // True if the plates of a saved project load again after the start (so
  // the page keeps no other plate of the last visit).
  willRestore() {
    return !!this.state?.setLoaded && this.state?.source?.kind === "github";
  }

  // The tag of a session of the plates of this project, or null if the
  // plates are not of a project. A session with this tag has the plates
  // as the user left them: removed plates, moved parts, and changes.
  sessionTag() {
    if (!this.state?.setLoaded) return null;
    return JSON.stringify([this.state.source, this.planKey()]);
  }

  // The plates came back from a session with the tag of this project
  // (app.js): they are the set of the project, and do not load again.
  adopt() {
    this.loaded = this.planKey();
    this.setMap = Array.isArray(this.state.setMap) ? this.state.setMap : null;
    this.adopted = true;
    this.render();
  }

  // After the worker starts (app.js): the plan of the saved project, and
  // its plates on the view again.
  start() {
    this.planned = this.state?.text ? this.replan().then(() => this.render()) : Promise.resolve();
    return this.restoreSet();
  }

  // The plates of the project on the view again after a reload (a GitHub
  // project; a folder must be opened again). The active plate stays.
  async restoreSet() {
    await this.reopened;
    if (this.adopted || !this.state?.setLoaded || !this.source) return;
    await this.planned;
    if (!this.plan || this.plan.error || this.plan.plates.length === 0) return;
    const i = Math.max(0, this.plan.plates.findIndex((p) => plateKey(this.plan, p) === this.state.active));
    // The plates that the user removed stay away (the map is kept at
    // once; the session can be older).
    const keep = Array.isArray(this.state.setMap) ? [...this.state.setMap] : null;
    await this.openPlate(i);
    if (!keep || !this.setMap) return;
    for (let k = this.setMap.length - 1; k >= 0; k--) {
      if (keep.includes(this.setMap[k])) continue;
      this.ctx.applySettings(await this.ctx.client.call("plateRemove", { index: k }));
      this.removed(k);
    }
  }

  async use(src) {
    if (!src.has("printdeck.yml")) throw new Error(`${src.label} has no printdeck.yml at its root.`);
    const text = new TextDecoder().decode(await src.read("printdeck.yml"));
    const same = this.state?.text === text;
    this.source = src;
    this.text = text;
    this.state = {
      source: src.saved,
      text,
      counts: same ? this.state.counts : [],
      status: same ? this.state.status : {},
      active: same ? this.state.active : null,
    };
    await this.replan();
    if (this.plan?.error) throw new Error(`printdeck.yml${this.plan.line ? `, line ${this.plan.line}` : ""}: ${this.plan.error}`);
    save(this.state);
  }

  // Closes the project. Its plates stay on the view as plates of the
  // user, and a reload keeps them (the session).
  close() {
    this.source = null;
    this.plan = null;
    this.state = null;
    this.loaded = null;
    this.setMap = null;
    this.adopted = false;
    save(null);
    this.render();
    this.ctx.closed?.();
  }

  // The name of the open project, or null.
  openName() {
    if (!this.state) return null;
    const s = this.state.source;
    return this.plan?.name || (s.kind === "github" ? `${s.owner}/${s.repo}` : s.name);
  }

  async replan() {
    this.plan = await this.ctx.client.call("projectPlan", { text: this.state.text, counts: this.state.counts ?? [] });
  }

  async run(label, fn) {
    this.busy = label;
    this.render();
    try {
      await fn();
    } catch (e) {
      this.ctx.toast(e.message);
    } finally {
      this.busy = "";
      this.render();
    }
  }

  // ---- plates ----

  // The key of the plan of the plate set in the worker: the text and the
  // counts of the parts.
  planKey() {
    return `${this.state?.text ?? ""}\n${JSON.stringify(this.state?.counts ?? [])}`;
  }

  // Opens plate i. All plates of the project load into the plate set (one
  // app for each plate), so they all slice and show at once; plate i is
  // the active plate. With the set loaded, plate i only becomes active.
  async openPlate(i) {
    // The place of plan plate i in the set; -1 if the user removed it
    // (then the set loads again).
    const at = this.setMap?.indexOf(i) ?? i;
    if (this.loaded === this.planKey() && at >= 0) {
      await this.ctx.activate(at);
      this.showActive(at);
      return;
    }
    if (!this.source) {
      this.ctx.toast(this.state.source.kind === "folder" ? `Open the folder ${this.state.source.name} again to load its files.` : "GitHub did not answer. Try again.");
      return;
    }
    const plates = this.plan.plates;
    await this.run(`Loading ${plates.length} plates…`, async () => {
      // The files of all plates: the profile folders and the models. The
      // core finds the plates with no Cura stack (cura.json in the profile
      // folder): resin plates, which zslice does not slice yet. It loads
      // their parts for their footprints on the view.
      const files = {};
      const read = async (f) => {
        if (!(f in files)) files[f] = await this.source.read(f);
      };
      for (const plate of plates) {
        const folder = plate.profile.split("/")[0];
        if (folder && this.source.has(`profiles/${folder}/cura.json`)) {
          for (const p of this.source.list(`profiles/${folder}`)) await read(p);
        }
        for (const it of plate.items) {
          for (const f of this.plan.parts[it.part].files) await read(f);
        }
      }
      // The profiles of the plates replace the profiles of the user's
      // printer on the view, and do not change that printer.
      this.ctx.loading();
      const r = await this.ctx.client.call("projectSet", { text: this.state.text, counts: this.state.counts ?? [], files, active: i });
      this.ctx.applySettings(r);
      this.loaded = this.planKey();
      // The plan plate of each plate of the set.
      this.setMap = plates.map((_, k) => k);
      this.state.setMap = this.setMap;
      this.state.setLoaded = true;
      save(this.state);
      const bad = r.results.map((x, k) => (x.error ? `Plate ${k + 1}: ${x.error}` : x.fits === false ? x.message : "")).filter(Boolean);
      if (bad.length > 0) this.ctx.toast(bad.join(" "));
      this.ctx.opened(this.ctx.plateName(i));
      this.showActive(i);
      // The printer of the plate, if the user has one with its name.
      const match = this.ctx.printers().find((n) => n.toLowerCase() === plates[i].printer.toLowerCase());
      if (match) this.ctx.usePrinter(match);
    });
  }

  // Plate i of the set is the active plate (from the view or this page).
  showActive(i) {
    if (!this.plan || this.loaded !== this.planKey()) return;
    const plate = this.plan.plates[this.planIndex(i)];
    // A plate after the plates of the project ("+ Plate"): no plate of the
    // project is active.
    const key = plate ? plateKey(this.plan, plate) : null;
    if (this.state.active === key) return;
    this.state.active = key;
    save(this.state);
    this.render();
  }

  // The print status of plate i of the set ("todo", "printing",
  // "printed", "failed"), or null when the set is not this project.
  printStatus(i) {
    if (!this.plan || this.loaded !== this.planKey()) return null;
    const plate = this.plan.plates[this.planIndex(i)];
    return plate ? this.state.status?.[plateKey(this.plan, plate)] ?? "todo" : null;
  }

  // Sets the print status of plate i of the set.
  setPrintStatus(i, status) {
    const plate = this.plan?.plates[this.planIndex(i)];
    if (plate) this.setStatus(plateKey(this.plan, plate), status);
  }

  // The plan plate of plate i of the set (-1 for a plate of the user).
  planIndex(i) {
    if (!this.setMap) return i;
    return i < this.setMap.length ? this.setMap[i] : -1;
  }

  // Plate i of the set was removed. Its print status stays in the plan.
  removed(i) {
    if (this.setMap && i < this.setMap.length) this.setMap.splice(i, 1);
    if (this.state) {
      this.state.setMap = this.setMap;
      save(this.state);
    }
    this.render();
  }

  // The plate set is no longer the plates of this project (a file opened).
  unload() {
    this.loaded = null;
    this.setMap = null;
    if (this.state?.setLoaded) {
      this.state.setLoaded = false;
      save(this.state);
    }
  }

  setStatus(key, status) {
    this.state.status[key] = status;
    save(this.state);
    this.render();
    this.ctx.statusChanged?.();
  }

  // The plate on the view was sent to a printer.
  sent() {
    if (!this.state?.active) return;
    this.setStatus(this.state.active, "printing");
  }

  // ---- the page ----

  render() {
    const root = this.root;
    const page = el("div", "project");
    if (!this.state) {
      page.append(this.openForm());
      root.replaceChildren(page);
      return;
    }
    const s = this.state.source;
    const head = el("div", "proj-head");
    const title = el("div", "proj-title", this.plan?.name || (s.kind === "github" ? `${s.owner}/${s.repo}` : s.name));
    const from = el("div", "dim", s.kind === "github" ? `GitHub ${s.owner}/${s.repo} @ ${s.sha.slice(0, 7)}` : `Folder ${s.name}`);
    const closeBtn = el("button", "flat", "Close");
    closeBtn.title = "Close the project. Its plates stay, and the print status of its plates goes.";
    closeBtn.onclick = () => this.close();
    head.append(box("", title, from), closeBtn);
    page.append(head);
    if (this.busy) page.append(el("div", "proj-busy", this.busy));
    if (s.kind === "folder" && !this.source) {
      const again = el("button", "", `Open the folder ${s.name} again`);
      again.onclick = () => this.pickFolder();
      page.append(el("div", "dim", "The browser forgets the files of a folder after a reload."), again);
    }
    if (!this.plan) {
      root.replaceChildren(page);
      return;
    }
    if (this.plan.error) {
      page.append(el("div", "proj-error", `printdeck.yml${this.plan.line ? `, line ${this.plan.line}` : ""}: ${this.plan.error}`));
      root.replaceChildren(page);
      return;
    }
    page.append(el("h3", "proj-h", "Plates"), this.platesList());
    page.append(el("h3", "proj-h", "Parts"), this.partsList());
    root.replaceChildren(page);
  }

  openForm() {
    const form = el("div", "proj-open");
    form.append(
      el("div", "proj-title", "Open a project"),
      el("div", "dim", "A project is a repository with a printdeck.yml: the parts, their printers, Cura profiles, and settings. zslice puts the parts on plates, and keeps the status of each plate."),
    );
    const input = Object.assign(document.createElement("input"), { placeholder: "owner/repo or a github.com address", spellcheck: false });
    const go = el("button", "", "Open");
    go.onclick = () => this.openGithub(input.value);
    input.onkeydown = (e) => {
      if (e.key === "Enter") go.click();
    };
    const row = box("proj-row", input, go);
    const folder = el("button", "", "Open a folder…");
    folder.onclick = () => this.pickFolder();
    form.append(el("label", "proj-label", "From GitHub (a public repository)"), row, el("label", "proj-label", "From this computer"), folder);
    if (this.busy) form.append(el("div", "proj-busy", this.busy));
    return form;
  }

  pickFolder() {
    const input = document.createElement("input");
    input.type = "file";
    input.webkitdirectory = true;
    input.onchange = () => {
      if (input.files.length > 0) this.openFolder([...input.files]);
    };
    input.click();
  }

  platesList() {
    const list = el("div", "proj-plates");
    const plan = this.plan;
    if (plan.plates.length === 0) list.append(el("div", "dim", "No parts are chosen."));
    plan.plates.forEach((plate, i) => {
      const key = plateKey(plan, plate);
      const status = this.state.status?.[key] ?? "todo";
      const card = el("div", "proj-plate" + (this.state.active === key ? " active" : "") + ` st-${status}`);
      const head = el("div", "proj-plate-head");
      head.append(el("span", "proj-plate-title", `Plate ${i + 1}`), el("span", "dim", [plate.printer, plate.profile.split("/")[1] ?? plate.profile, plate.material].filter(Boolean).join(" · ")));
      const sel = document.createElement("select");
      sel.className = "proj-status";
      for (const [k, label] of Object.entries(STATUS)) sel.append(new Option(label, k, false, k === status));
      sel.onchange = () => this.setStatus(key, sel.value);
      head.append(sel);
      card.append(head);
      const items = el("div", "proj-items");
      for (const it of plate.items) {
        const part = plan.parts[it.part];
        items.append(el("div", "", `${part.name}${it.count > 1 ? ` × ${it.count}` : ""}`));
      }
      card.append(items);
      // A plate with no Cura stack (cura.json) in its profile folder: a
      // resin plate, which zslice does not slice yet.
      const folder = plate.profile.split("/")[0];
      const resin = !folder || (this.source && !this.source.has(`profiles/${folder}/cura.json`));
      const inSet = this.loaded === this.planKey();
      const open = el("button", this.state.active === key ? "" : "flat", inSet ? (this.state.active === key ? "Active" : "Show") : (this.state.active === key ? "Open again" : "Open"));
      open.disabled = !!this.busy || !!resin;
      open.title = resin ? "This plate has no Cura profile stack (a resin plate?). zslice slices FDM plates only, for now." : inSet ? "Make this plate the active plate, and move the view to it." : "Load all plates of the project on the view, each with its profiles and settings, and slice them. This plate is the active plate.";
      open.onclick = () => this.openPlate(i);
      card.append(open);
      list.append(card);
    });
    const done = plan.plates.filter((p) => this.state.status?.[plateKey(plan, p)] === "printed").length;
    if (plan.plates.length > 0) list.append(el("div", "dim proj-count", `${done} of ${plan.plates.length} plates printed`));
    return list;
  }

  partsList() {
    const list = el("div", "proj-parts");
    const plan = this.plan;
    let group = null;
    plan.parts.forEach((part, i) => {
      if (part.group && part.group !== group) {
        group = part.group;
        list.append(el("div", "proj-group", group));
      }
      const counts = this.state.counts ?? [];
      // A later variant (part.on false) is off until the user chooses it.
      const base = part.on === false ? 0 : part.count;
      const count = counts[i] ?? base;
      const row = el("div", "proj-part");
      const on = document.createElement("input");
      on.type = "checkbox";
      on.checked = count > 0;
      const n = document.createElement("input");
      n.type = "number";
      n.min = "0";
      n.max = "99";
      n.value = String(count);
      n.className = "proj-n";
      n.title = "The copies of each file on the plate";
      const change = async (value) => {
        const c = [...(this.state.counts ?? [])];
        while (c.length < plan.parts.length) c.push(null);
        c[i] = value === base ? null : value;
        this.state.counts = c;
        save(this.state);
        await this.replan();
        this.render();
      };
      on.onchange = () => change(on.checked ? Math.max(1, part.count) : 0);
      n.onchange = () => change(Math.max(0, Math.min(99, Number(n.value) || 0)));
      const name = el("div", "proj-part-name", part.name);
      const facts = [part.printer, part.profile.split("/")[1] ?? part.profile, part.material].filter(Boolean).join(" · ");
      const info = box("", name, el("div", "dim proj-facts", facts));
      if (part.description) info.title = part.description;
      if (part.settings.length > 0) info.title = `${info.title ? info.title + "\n\n" : ""}Settings: ${part.settings.map((s) => `${s.key} = ${s.value}`).join(", ")}`;
      row.append(on, info, n);
      list.append(row);
    });
    return list;
  }
}
