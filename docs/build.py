#!/usr/bin/env python3
"""zslice: write the documentation site in docs/ (https://zslice.beetlebug.org/docs.html).

Each Markdown file of the repository below is one page of the site:

  README.md                    the home page of the docs (docs.html; the web app is the site root)
  docs/README.md               all documents
  docs/user/*.md               the user guide (tools/settings_doc.py makes settings.md)
  docs/embedding/*.md          the library guides
  docs/internals/*.md          the internals
  docs/app/README.md           the app
  REFERENCES.md, ROADMAP.md    the references and the roadmap

A page goes in its own folder, as index.html (the home page is docs.html). A link to one of these files goes to its page. A
link to another file of the repository goes to the file on GitHub.

Run it after a change to a Markdown file. It needs only Python 3. At the end it checks each link
of the site, and stops with an error for a link to a file or an anchor that does not exist.

  python3 docs/build.py
"""

import html
import posixpath
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent
ROOT = DOCS.parent
REPO = "https://github.com/beetlebugorg/zslice"
BRANCH = "main"
SITE = "https://zslice.beetlebug.org/"

esc = html.escape

# The pages: (source file, folder on the site, group in the sidebar, title in the sidebar).
# The order is the order of the sidebar, and of the previous and next links.
SOURCES = [
    ("README.md", "docs.html", None, "Home"),
    ("docs/README.md", "contents/", None, "All documents"),
    ("docs/user/getting-started.md", "user/getting-started/", "User guide", "Getting started"),
    ("docs/user/settings.md", "user/settings/", "User guide", "Settings"),
    ("docs/user/profiles.md", "user/profiles/", "User guide", "Profiles"),
    ("docs/user/projects.md", "user/projects/", "User guide", "Projects"),
    ("docs/user/troubleshooting.md", "user/troubleshooting/", "User guide", "Troubleshooting"),
    ("docs/embedding/overview.md", "embedding/", "Embedding", "Overview"),
    ("docs/embedding/c.md", "embedding/c/", "Embedding", "C"),
    ("docs/embedding/zig.md", "embedding/zig/", "Embedding", "Zig"),
    ("docs/embedding/javascript.md", "embedding/javascript/", "Embedding", "JavaScript"),
    ("docs/internals/architecture.md", "internals/architecture/", "Internals", "Architecture"),
    ("docs/internals/how-slicing-works.md", "internals/how-slicing-works/", "Internals", "How slicing works"),
    ("docs/internals/layer-settings.md", "internals/layer-settings/", "Internals", "Settings for some layers"),
    ("docs/internals/arachne.md", "internals/arachne/", "Internals", "Arachne walls"),
    ("docs/internals/cura-compare.md", "internals/cura-compare/", "Internals", "Compared with other slicers"),
    ("docs/internals/contributing.md", "internals/contributing/", "Internals", "Contributing"),
    ("docs/internals/code-quality.md", "internals/code-quality/", "Internals", "Code quality"),
    ("docs/app/README.md", "app/", "Project", "App"),
    ("REFERENCES.md", "references/", "Project", "References"),
    ("ROADMAP.md", "roadmap/", "Project", "Roadmap"),
    ("PRIVACY.md", "privacy/", "Project", "Privacy"),
]
PAGE_OF = {src: path for src, path, _, _ in SOURCES}

# Files that the site links to, but that can be missing. The check prints a note for each.
# The site root is the web app: the Pages workflow puts it there.
OPTIONAL = {"img/benchy.png", "index.html"}


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


# ---------------------------------------------------------------------------------------------
# Markdown. The files use headings, paragraphs, lists (with task boxes and nested lists), fenced
# code, tables, inline code, bold, links and HTML comments. This converter does only those.

def fix_link(url, src_dir, root):
    """The URL of a link in a Markdown file in src_dir, for a page at root."""
    if re.match(r"^(https?:|mailto:|#)", url):
        return url
    url, _, anchor = url.partition("#")
    anchor = "#" + anchor if anchor else ""
    p = posixpath.normpath(posixpath.join(src_dir, url))
    if p in PAGE_OF:
        return root + PAGE_OF[p] + anchor
    kind = "tree" if (ROOT / p).is_dir() else "blob"
    return f"{REPO}/{kind}/{BRANCH}/{p}{anchor}"


def slug(text):
    """The anchor of a heading, as GitHub makes it."""
    text = re.sub(r"<[^>]+>", "", text).replace("`", "")
    return re.sub(r"[^\w\- ]", "", html.unescape(text).lower()).replace(" ", "-")


def image_link(url, src_dir, root):
    """A picture in docs/ is a file of the site: a path from the page."""
    if re.match(r"^https?:", url):
        return url
    path = posixpath.normpath(posixpath.join(src_dir, url))
    if path.startswith("docs/"):
        return root + path[len("docs/"):]
    return fix_link(url, src_dir, root)


def inline(text, src_dir, root):
    codes = []

    def keep(m):
        codes.append(f"<code>{esc(m.group(1))}</code>")
        return f"\x00{len(codes) - 1}\x00"

    t = re.sub(r"`([^`]+)`", keep, text)
    t = esc(t, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])", r"<em>\1</em>", t)
    # Images: ![alt](path), before the links.
    t = re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)",
               lambda m: f'<img src="{esc(image_link(html.unescape(m.group(2)), src_dir, root))}" alt="{m.group(1)}" loading="lazy">', t)
    t = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)",
               lambda m: f'<a href="{esc(fix_link(html.unescape(m.group(2)), src_dir, root))}">{m.group(1)}</a>', t)
    t = re.sub(r'(?<!["\'>=])(https?://[^\s<)]+?)([.,;:]?)(?=[\s<)]|$)', r'<a href="\1">\1</a>\2', t)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], t)


LIST_ITEM = re.compile(r"^( *)([-*+]|\d+\.) +(.*)$")
BLOCK_START = re.compile(r"^(#{1,6} |```|\|| {0,3}(?:[-*+]|\d+\.) )")


def split_row(row):
    """The cells of a table row. A | in inline code does not split a cell."""
    cells, cur, code = [], "", False
    for ch in row.strip().strip("|"):
        if ch == "`":
            code = not code
        if ch == "|" and not code:
            cells.append(cur.strip())
            cur = ""
        else:
            cur += ch
    cells.append(cur.strip())
    return cells


class Markdown:
    def __init__(self, src_dir, root):
        self.src_dir, self.root = src_dir, root
        self.ids = set()

    def inline(self, s):
        return inline(s, self.src_dir, self.root)

    def heading_id(self, title):
        base = slug(title)
        sid, n = base, 0
        while sid in self.ids:
            n += 1
            sid = f"{base}-{n}"
        self.ids.add(sid)
        return sid

    def convert(self, text):
        text = re.sub(r"<!--.*?-->\n?", "", text, flags=re.S)
        lines = text.split("\n")
        out, i, n = [], 0, len(lines)
        while i < n:
            line = lines[i]
            if not line.strip():
                i += 1
            elif line.lstrip().startswith("```"):
                fence = line[:len(line) - len(line.lstrip())]
                j = i + 1
                while j < n and not lines[j].lstrip().startswith("```"):
                    j += 1
                body = [l[len(fence):] if l.startswith(fence) else l for l in lines[i + 1:j]]
                out.append("<pre><code>" + esc("\n".join(body), quote=False) + "</code></pre>")
                i = j + 1
            elif (m := re.match(r"^(#{1,6}) +(.*?)#*$", line)):
                level, title = len(m.group(1)), m.group(2).strip()
                out.append(f'<h{level} id="{self.heading_id(title)}">{self.inline(title)}</h{level}>')
                i += 1
            elif line.startswith("|"):
                j = i
                while j < n and lines[j].startswith("|"):
                    j += 1
                out.append(self.table(lines[i:j]))
                i = j
            elif LIST_ITEM.match(line):
                j = self.list_end(lines, i)
                out.append(self.list(lines[i:j]))
                i = j
            else:
                j = i + 1
                while j < n and lines[j].strip() and not BLOCK_START.match(lines[j]):
                    j += 1
                out.append("<p>" + self.inline(" ".join(s.strip() for s in lines[i:j])) + "</p>")
                i = j
        return "\n".join(out)

    def list_end(self, lines, i):
        """The index of the first line after the list that starts at line i."""
        indent = len(LIST_ITEM.match(lines[i]).group(1))
        j, n = i + 1, len(lines)
        while j < n:
            line = lines[j]
            if line.strip():
                m = LIST_ITEM.match(line)
                if not line.startswith(" " * (indent + 1)) and not (m and len(m.group(1)) == indent):
                    break
                j += 1
                continue
            # A blank line: the list goes on if an item or an indented line comes next.
            k = j
            while k < n and not lines[k].strip():
                k += 1
            if k < n and (lines[k].startswith(" " * (indent + 1)) or
                          ((m := LIST_ITEM.match(lines[k])) and len(m.group(1)) == indent)):
                j = k
            else:
                break
        return j

    def list(self, lines):
        first = LIST_ITEM.match(lines[0])
        indent = len(first.group(1))
        ordered = first.group(2)[0].isdigit()
        items = []
        for line in lines:
            m = LIST_ITEM.match(line)
            if m and len(m.group(1)) == indent:
                width = len(line) - len(m.group(3))
                items.append([width, [m.group(3)]])
            else:
                width = items[-1][0]
                pad = len(line) - len(line.lstrip(" "))
                items[-1][1].append(line[min(pad, width):])
        out = []
        for _, body in items:
            box = ""
            if (t := re.match(r"^\[([ xX])\] +", body[0])):
                done = t.group(1) != " "
                box = f'<span class="box{" done" if done else ""}" aria-label="{"done" if done else "to do"}"></span>'
                body[0] = body[0][t.end():]
            inner = Markdown(self.src_dir, self.root)
            inner.ids = self.ids
            h = inner.convert("\n".join(body))
            if h.startswith("<p>") and h.count("<p>") == 1:
                h = h[3:].replace("</p>", "", 1)
            out.append((box, h))
        tasks = any(box for box, _ in out)
        if tasks:
            # A task list puts the box and the text in two columns of a grid.
            out = [(box or '<span class="box none"></span>', f"<div>{h}</div>") for box, h in out]
        out = [f"<li>{box}{h}</li>" for box, h in out]
        tag = "ol" if ordered else "ul"
        cls = ' class="tasks"' if tasks else ""
        return f"<{tag}{cls}>" + "".join(out) + f"</{tag}>"

    def table(self, rows):
        cells = [split_row(r) for r in rows]
        head, body = cells[0], cells[1:]
        if body and all(re.match(r"^:?-{3,}:?$", c) for c in body[0]):
            body = body[1:]
        h = "".join(f"<th>{self.inline(c)}</th>" for c in head)
        b = "".join("<tr>" + "".join(f"<td>{self.inline(c)}</td>" for c in r) + "</tr>" for r in body)
        return f'<div class="table-wrap"><table><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table></div>'


def parse(src, root):
    """A Markdown file as (title, lede, body HTML). The title is the level 1 heading. The lede is
    the first paragraph, if it is short and comes directly after the title."""
    text = read(src)
    m = re.match(r"^# +(.*)\n", text)
    title = m.group(1).strip()
    text = text[m.end():]
    conv = Markdown(posixpath.dirname(src), root)
    body = conv.convert(text)
    lede = ""
    if (p := re.match(r"^<p>(.*?)</p>\n?", body, re.S)) and len(re.sub("<[^>]+>", "", p.group(1))) < 320:
        lede, body = p.group(1), body[p.end():]
    return title, lede, body


def sections(src):
    """The level 2 sections of a Markdown file: a dict of title -> text, with "" for the text
    before the first level 2 heading. A line in fenced code does not start a section."""
    out, title, buf, fence = {}, "", [], False
    for line in read(src).split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
        if not fence and line.startswith("## "):
            out[title] = "\n".join(buf)
            title, buf = line[3:].strip(), []
        else:
            buf.append(line)
    out[title] = "\n".join(buf)
    return out


# ---------------------------------------------------------------------------------------------
# The pages.

CSS = r"""
:root { --paper: #f4f0e6; --ink: #171717; --dim: #4a4742; --edge: #a9a59c; --orange: #ff5a1f; --blue: #1d47b5;
  --plate: #e6e3dc; --plate2: #ece8dd; --outside: #d3d0c8;
  /* The fonts of the system: the site loads nothing from other sites. */
  --sans: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; --mono: "IBM Plex Mono", ui-monospace, "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace;
  color-scheme: light; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) { --paper: #1b1a17; --ink: #ebe6da; --dim: #b3ac9f; --edge: #5c574e; --orange: #ff6a33;
    --blue: #8fb0ff; --plate: #26241f; --plate2: #2d2b25; --outside: #121110; color-scheme: dark; }
}
:root[data-theme="dark"] { --paper: #1b1a17; --ink: #ebe6da; --dim: #b3ac9f; --edge: #5c574e; --orange: #ff6a33;
  --blue: #8fb0ff; --plate: #26241f; --plate2: #2d2b25; --outside: #121110; color-scheme: dark; }
* { box-sizing: border-box; }
html { background: var(--outside); }
body { margin: 0; background: var(--paper); color: var(--ink); font: 16px/1.5 var(--sans); }
a { color: var(--blue); }
code, pre, kbd { font-family: var(--mono); font-variant-ligatures: none; }
code { font-size: .92em; background: var(--plate); padding: 0 .25em; border-radius: 3px; }
pre { background: var(--plate); border-left: 4px solid var(--edge); padding: 12px 14px; overflow-x: auto; font-size: 13px; line-height: 1.45; }
pre code { background: none; padding: 0; font-size: inherit; }
h1, h2, h3, h4 { font-family: var(--mono); letter-spacing: .02em; line-height: 1.2; }
h1 { font-size: clamp(26px, 4vw, 34px); margin: 6px 0 10px; text-transform: uppercase; }
h2 { font-size: 20px; margin: 40px 0 10px; padding-bottom: 6px; border-bottom: 3px solid var(--ink); }
h3 { font-size: 16px; margin: 28px 0 8px; text-transform: uppercase; letter-spacing: .08em; color: var(--dim); }
h4 { font-size: 14px; margin: 20px 0 6px; }
p, li { max-width: 76ch; }
li { margin-bottom: 4px; }
li > ul, li > ol { margin-top: 4px; }
img { max-width: 100%; height: auto; }
.eyebrow { margin: 0; font: 700 12px var(--mono); text-transform: uppercase; letter-spacing: .14em; color: var(--orange); }
.lede { font-size: 18px; color: var(--dim); max-width: 60ch; margin-top: 0; }
.table-wrap { overflow-x: auto; margin: 12px 0; }
table { border-collapse: collapse; width: 100%; }
td, th { border-top: 2px solid var(--edge); padding: 7px 10px; vertical-align: top; text-align: left; }
th { font: 700 11px var(--mono); text-transform: uppercase; letter-spacing: .08em; color: var(--dim); border-top: 0; border-bottom: 2px solid var(--ink); }
td:first-child { font-family: var(--mono); font-size: 14px; }
td code { overflow-wrap: anywhere; }

/* The task lists of the roadmap */
ul.tasks { list-style: none; padding-left: 4px; }
ul.tasks li { display: grid; grid-template-columns: 26px 1fr; }
.box { width: 16px; height: 16px; margin-top: 3px; border: 2px solid var(--edge); border-radius: 3px; }
.box.done { border-color: var(--orange); background: var(--orange) center / 12px no-repeat
  url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M3 8.5l3.2 3L13 4.5' fill='none' stroke='%23fff' stroke-width='2.4'/%3E%3C/svg%3E"); }
.box.none { visibility: hidden; }
ul.tasks li > div > p:first-child { margin-top: 0; }

/* The top bar */
#menu { display: none; }
.top { display: flex; align-items: center; gap: 16px; padding: 10px 16px; border-bottom: 3px solid var(--ink); background: var(--paper); }
.brand { display: flex; align-items: center; gap: 10px; text-decoration: none; color: var(--ink); }
.mark { display: inline-block; background: var(--ink); color: var(--paper); border-radius: 6px; padding: 2px 10px 5px;
  font: 700 16px/1.3 var(--mono); letter-spacing: .12em; box-shadow: inset 0 -4px 0 var(--orange); }
.brand span.docs { font: 700 12px var(--mono); letter-spacing: .3em; }
.top-links { margin-left: auto; display: flex; gap: 14px; font: 600 13px var(--mono); }
.top-links a { color: var(--ink); text-decoration: none; }
.menu-btn { display: none; margin-left: auto; font: 600 13px var(--mono); border: 2px solid var(--ink); border-radius: 6px; padding: 4px 10px; cursor: pointer; }

/* The sidebar and the page */
.layout { display: grid; grid-template-columns: 230px minmax(0, 1fr); gap: 36px; max-width: 1220px; margin: 0 auto; padding: 0 16px; }
.side { position: sticky; top: 0; align-self: start; max-height: 100vh; overflow-y: auto; padding: 20px 0 32px; font-size: 14px; }
.side .group { font: 700 11px var(--mono); text-transform: uppercase; letter-spacing: .12em; color: var(--dim); margin: 18px 0 4px; padding-left: 10px; }
.side a { display: block; padding: 3px 10px; color: var(--ink); text-decoration: none; border-left: 3px solid transparent; }
.side a:hover { background: var(--plate); }
.side a[aria-current] { border-left-color: var(--orange); background: var(--plate); font-weight: 600; }
main { padding: 28px 0 72px; min-width: 0; overflow-wrap: break-word; }
pre { overflow-wrap: normal; }
.onpage { margin: 16px 0 28px; padding: 10px 16px; border: 2px solid var(--edge); border-radius: 8px; background: var(--plate2); font-size: 14px; }
.onpage b { font: 700 11px var(--mono); text-transform: uppercase; letter-spacing: .12em; color: var(--dim); }
.onpage ol { margin: 4px 0 0; padding: 0; list-style: none; columns: 2; column-gap: 24px; }
.onpage li { break-inside: avoid; margin: 0; }
.onpage a { color: var(--ink); text-decoration: none; }
.onpage a:hover { text-decoration: underline; }
.pager { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 48px; padding-top: 16px; border-top: 2px solid var(--edge); }
.pager a { display: block; padding: 10px 14px; border: 2px solid var(--edge); border-radius: 8px; color: var(--ink); text-decoration: none; background: var(--plate2); }
.pager a:hover { background: var(--plate); }
.pager a.next { grid-column: 2; text-align: right; }
.pager span { display: block; font: 700 11px var(--mono); text-transform: uppercase; letter-spacing: .12em; color: var(--dim); }
.pager b { font-family: var(--mono); }
footer { border-top: 3px solid var(--ink); margin-top: 24px; padding: 18px 16px 40px; color: var(--dim); font-size: 13px; text-align: center; }
footer a { color: inherit; }

/* The home page */
.btn { display: inline-block; font: 600 13px var(--mono); color: var(--ink); border: 2px solid var(--ink); border-radius: 99px; padding: 6px 14px;
  text-decoration: none; margin: 0 8px 8px 0; background: var(--paper); }
.btn:hover { background: var(--plate); }
.btn.primary { background: var(--orange); border-color: var(--orange); color: #fff; }
.chips { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0 0; }
.chip { font: 600 12px var(--mono); border: 1.5px solid var(--ink); border-radius: 99px; padding: 3px 10px; }
.hero { position: relative; margin: 20px 0 24px; aspect-ratio: 5 / 2; border: 2px solid var(--edge); border-radius: 10px; overflow: hidden;
  background: repeating-linear-gradient(to bottom, var(--plate) 0 10px, var(--plate2) 10px 12px); }
.hero::before { content: ""; position: absolute; left: 50%; bottom: 0; width: 42%; height: 62%; transform: translateX(-50%);
  border-radius: 46% 46% 0 0 / 70% 70% 0 0;
  background: repeating-linear-gradient(to bottom, var(--orange) 0 9px, #e04a14 9px 12px); opacity: .85; }
.hero::after { content: "zslice"; position: absolute; left: 0; right: 0; top: 14%; text-align: center;
  font: 700 clamp(28px, 6vw, 56px) var(--mono); letter-spacing: .2em; color: var(--ink); opacity: .85; }
.hero img { position: absolute; inset: 0; z-index: 1; width: 100%; height: 100%; object-fit: cover; background: var(--plate); }
.hero img[hidden] { display: none; }
.map { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 16px; margin: 16px 0; }
.map a.card { display: block; border: 2px solid var(--edge); border-radius: 10px; background: var(--plate2); text-decoration: none;
  color: var(--ink); padding: 14px 16px; font-size: 14px; }
.map a.card:hover { background: var(--plate); }
.map .card b { display: block; font-family: var(--mono); font-size: 15px; margin-bottom: 4px; }
.map .card span { color: var(--dim); }

@media (max-width: 899px) {
  .layout { grid-template-columns: 1fr; gap: 0; }
  .side { position: static; max-height: none; padding: 8px 0 0; display: none; border-bottom: 2px solid var(--edge); }
  #menu:checked ~ .layout .side { display: block; }
  .menu-btn { display: inline-block; }
  .top-links { display: none; }
  .onpage ol { columns: 1; }
  .hero { aspect-ratio: 4 / 3; }
  .pager { grid-template-columns: 1fr; }
  .pager a.next { grid-column: 1; }
}
"""

# A favicon: three layers of a print.
ICON = ("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E"
        "%3Crect width='32' height='32' rx='6' fill='%23171717'/%3E"
        "%3Crect x='11' y='8' width='10' height='4' rx='1' fill='%23f4f0e6'/%3E"
        "%3Crect x='8' y='14' width='16' height='4' rx='1' fill='%23f4f0e6'/%3E"
        "%3Crect x='5' y='20' width='22' height='4' rx='1' fill='%23ff5a1f'/%3E%3C/svg%3E")

PAGES = {}  # folder -> HTML


def nav_html(current, root):
    out, group = [], None
    for _, path, g, title in SOURCES:
        if g != group:
            group = g
            out.append(f'<div class="group">{esc(g)}</div>')
        cur = ' aria-current="page"' if path == current else ""
        out.append(f'<a href="{root}{path}"{cur}>{esc(title)}</a>')
    return "\n".join(out)


def onpage(body):
    """The list of the level 2 headings of a page."""
    heads = re.findall(r'<h2 id="([^"]+)">(.*?)</h2>', body)
    if len(heads) < 2:
        return ""
    items = "".join(f'<li><a href="#{i}">{re.sub("<[^>]+>", "", t)}</a></li>' for i, t in heads)
    return f'<nav class="onpage"><b>On this page</b><ol>{items}</ol></nav>'


def pager(path, root):
    """The links to the previous and the next page, in the order of the sidebar."""
    paths = [p for _, p, _, _ in SOURCES]
    i = paths.index(path)
    out = []
    if i > 0:
        _, p, _, t = SOURCES[i - 1]
        out.append(f'<a class="prev" href="{root}{p}"><span>Previous</span><b>{esc(t)}</b></a>')
    if i + 1 < len(SOURCES):
        _, p, _, t = SOURCES[i + 1]
        out.append(f'<a class="next" href="{root}{p}"><span>Next</span><b>{esc(t)}</b></a>')
    return '<nav class="pager">' + "".join(out) + "</nav>"


def page(path, section, title, lede, body, src, description=None, toc=True):
    root = "../" * path.count("/")
    body_html = (onpage(body) if toc else "") + body + pager(path, root)
    desc = description or re.sub(r"<[^>]+>", "", html.unescape(lede)) or f"{title}: zslice documentation."
    PAGES[path] = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} · zslice</title>
<meta name="description" content="{esc(desc)}">
<link rel="canonical" href="{SITE}{path}">
<link rel="icon" href="{ICON}">
<link rel="stylesheet" href="{root}site.css">
</head>
<body>
<input type="checkbox" id="menu">
<header class="top">
  <a class="brand" href="{root}docs.html"><span class="mark">ZSLICE</span><span class="docs">DOCS</span></a>
  <label class="menu-btn" for="menu">Contents</label>
  <nav class="top-links"><a href="{root}index.html">Open the app</a><a href="{root}user/getting-started/">Get started</a><a href="{root}roadmap/">Roadmap</a><a href="{root}privacy/">Privacy</a><a href="{REPO}">GitHub</a></nav>
</header>
<div class="layout">
<aside class="side"><nav>{nav_html(path, root)}</nav></aside>
<main>
<p class="eyebrow">{esc(section)}</p>
<h1>{esc(title)}</h1>
{f'<p class="lede">{lede}</p>' if lede else ''}
{body_html}
</main>
</div>
<footer>zslice is free software (AGPL-3.0-or-later). <a href="{root}privacy/">Privacy</a>: no analytics, no cookies, nothing from other sites. <a href="{REPO}/blob/{BRANCH}/docs/build.py">docs/build.py</a> writes this site from <a href="{REPO}/blob/{BRANCH}/{src}">{esc(src)}</a>.</footer>
</body>
</html>
"""


def landing():
    """The home page, from README.md. The Documentation section of the README becomes a map of
    the site."""
    root, src = "", "README.md"
    sec = sections(src)
    intro = Markdown("", root).convert(re.sub(r"^# .*\n", "", sec[""]))
    paras = re.findall(r"<p>(.*?)</p>", intro, re.S)
    # The README picture under the title: the site has its own hero image.
    paras = [p for p in paras if not re.fullmatch(r"\s*<img [^>]*>\s*", p)]
    lede, rest = paras[0], "\n".join(f"<p>{p}</p>" for p in paras[1:])
    conv = Markdown("", root)
    conv.ids.update({"docs", "documentation"})
    parts = []
    for title in ("Features", "Build", "Command line", "Settings", "Embedding", "License"):
        if title not in sec:
            sys.exit(f"{src}: no section {title!r}")
        parts.append(f'<h2 id="{conv.heading_id(title)}">{esc(title)}</h2>')
        parts.append(conv.convert(sec[title]))
    body = f"""
<p>
  <a class="btn primary" href="user/getting-started/">Get started</a>
  <a class="btn" href="user/settings/">Settings</a>
  <a class="btn" href="embedding/">Embed the library</a>
  <a class="btn" href="internals/how-slicing-works/">How a slicer works</a>
  <a class="btn" href="{REPO}">Source on GitHub</a>
</p>
<figure class="hero"><img src="img/benchy.png" alt="A boat test model, sliced by zslice" onerror="this.hidden=true"></figure>
{rest}
<div class="chips"><span class="chip">Zig 0.16</span><span class="chip">C API</span><span class="chip">WebAssembly</span><span class="chip">GTK4 app</span><span class="chip">AGPL-3.0-or-later</span></div>

<h2 id="docs">The documentation</h2>
<div class="map">
  <a class="card" href="user/getting-started/"><b>User guide</b><span>Build zslice, slice a part, and look at the layers.</span></a>
  <a class="card" href="user/settings/"><b>Settings</b><span>Each setting, its unit, and its default.</span></a>
  <a class="card" href="user/profiles/"><b>Profiles</b><span>Machine, filament, and project files, with inheritance.</span></a>
  <a class="card" href="embedding/"><b>Embedding</b><span>The library from Zig, from C, and from JavaScript.</span></a>
  <a class="card" href="internals/how-slicing-works/"><b>Internals</b><span>The stages from mesh to G-code, and the modules of the code.</span></a>
  <a class="card" href="app/"><b>The app</b><span>The app core and the native shells.</span></a>
  <a class="card" href="references/"><b>References</b><span>The sources that zslice uses, and their licenses.</span></a>
  <a class="card" href="roadmap/"><b>Roadmap</b><span>What works now, and what comes next.</span></a>
</div>
{chr(10).join(parts)}
"""
    page("docs.html", "Documentation", "zslice", lede, body, src, toc=False,
         description="The documentation of zslice, a slicer for FDM 3D printers, written from scratch in Zig.")


def doc_pages():
    for src, path, group, _ in SOURCES[1:]:
        title, lede, body = parse(src, "../" * path.count("/"))
        page(path, group or "Documentation", title, lede, body, src)


def check_sources():
    """Stops with an error for a Markdown file in docs/ that has no page."""
    missing = [p.relative_to(ROOT).as_posix() for p in sorted(DOCS.rglob("*.md"))
               if p.relative_to(ROOT).as_posix() not in PAGE_OF]
    if missing:
        sys.exit("Markdown files with no page in SOURCES: " + ", ".join(missing))


def check_links():
    """Checks that each link and picture of the site goes to a file of the site, and that each
    anchor is an id of its page."""
    bad, notes = [], set()
    pages = sorted(DOCS.rglob("*.html"))
    ids = {p: set(re.findall(r'\bid="([^"]+)"', p.read_text(encoding="utf-8"))) for p in pages}
    for p in pages:
        rel = p.relative_to(DOCS).as_posix()
        for m in re.finditer(r'(?:href|src)="([^"]+)"', p.read_text(encoding="utf-8")):
            url = html.unescape(m.group(1))
            if re.match(r"^(https?:|mailto:|data:|javascript:)", url):
                continue
            url, _, anchor = url.partition("#")
            if url == "":
                target = p
            else:
                target_rel = posixpath.normpath(posixpath.join(posixpath.dirname(rel), url))
                target = DOCS / target_rel
                if target.is_dir():
                    target = target / "index.html"
                if not target.exists():
                    if target_rel in OPTIONAL:
                        notes.add(target_rel)
                    else:
                        bad.append(f"{rel}: {url}")
                    continue
            if anchor and target.suffix == ".html" and anchor not in ids.get(target, set()):
                bad.append(f"{rel}: #{anchor} is not in {target.relative_to(DOCS)}")
    for n in sorted(notes):
        print(f"note: docs/{n} does not exist yet")
    if bad:
        print("Links that go nowhere:")
        print("\n".join("  " + b for b in bad))
        sys.exit(1)
    print(f"checked the links of {len(pages)} pages")


def main():
    check_sources()
    landing()
    doc_pages()
    (DOCS / "site.css").write_text(CSS.strip() + "\n", encoding="utf-8")
    for path, doc in PAGES.items():
        out = DOCS / path if path.endswith(".html") else DOCS / path / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(doc, encoding="utf-8")
    print(f"wrote {len(PAGES)} pages")
    check_links()


if __name__ == "__main__":
    main()
