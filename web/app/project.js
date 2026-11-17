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
    this.state = load(); // { source, text, counts, status, active }
    this.busy = "";
    if (this.state?.text) this.replan().then(() => this.render());
    this.render();
    // After a reload, a GitHub project gets its files again.
    if (this.state?.source?.kind === "github") this.reopen();
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

  close() {
    this.source = null;
    this.plan = null;
    this.state = null;
    save(null);
    this.render();
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

  async openPlate(i) {
    const plate = this.plan.plates[i];
    if (!this.source) {
      this.ctx.toast(this.state.source.kind === "folder" ? `Open the folder ${this.state.source.name} again to load its files.` : "GitHub did not answer. Try again.");
      return;
    }
    await this.run(`Loading plate ${i + 1}…`, async () => {
      const files = {};
      const folder = plate.profile.split("/")[0];
      if (folder) for (const p of this.source.list(`profiles/${folder}`)) files[p] = await this.source.read(p);
      for (const it of plate.items) {
        for (const f of this.plan.parts[it.part].files) files[f] = await this.source.read(f);
      }
      // The profiles of the plate replace the profiles of the user's
      // printer on the view, and do not change that printer.
      this.ctx.loading();
      const r = await this.ctx.client.call("projectLoad", { text: this.state.text, counts: this.state.counts ?? [], plate: i, files });
      this.ctx.applySettings(r);
      if (r.error) throw new Error(`Plate ${i + 1}: ${r.error}`);
      if (r.fits === false) this.ctx.toast(r.message);
      this.state.active = plateKey(this.plan, plate);
      save(this.state);
      const names = plate.items.map((it) => this.plan.parts[it.part].name);
      this.ctx.opened(names.length === 1 ? names[0] : `${names[0]} and ${names.length - 1} more`);
      // The printer of the plate, if the user has one with its name.
      const match = this.ctx.printers().find((n) => n.toLowerCase() === plate.printer.toLowerCase());
      if (match) this.ctx.usePrinter(match);
    });
  }

  setStatus(key, status) {
    this.state.status[key] = status;
    save(this.state);
    this.render();
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
    closeBtn.title = "Close the project. The status of its plates goes too.";
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
      const open = el("button", this.state.active === key ? "" : "flat", this.state.active === key ? "Open again" : "Open");
      open.disabled = !!this.busy || !!resin;
      open.title = resin ? "This plate has no Cura profile stack (a resin plate?). zslice slices FDM plates only, for now." : "Load the plate on the view, with its profiles and settings, and slice it.";
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
      const count = counts[i] ?? part.count;
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
        c[i] = value === part.count ? null : value;
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
