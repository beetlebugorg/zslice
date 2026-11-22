#!/usr/bin/env python3
"""zslice: write the documentation site in docs/ (https://zslice.beetlebug.org/docs.html).

Each Markdown file of the repository below is one page of the site:

  README.md                    the home page of the docs (docs.html; the web app is the site root)
  docs/README.md               all documents
  docs/user/*.md               the user guide (tools/settings_doc.py makes settings.md)
  docs/embedding/*.md          the library guides
  docs/internals/*.md          the internals
  docs/app/README.md           the app
  docs/references/*.md         the references (the explorer comes from their ref blocks)
  ROADMAP.md                   the roadmap

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
    ("docs/user/getting-started.md", "user/getting-started/", "Start", "Your first print"),
    ("docs/user/look.md", "user/look/", "Everyday tasks", "Look at the print"),
    ("docs/user/lines.md", "user/lines/", "Everyday tasks", "Click a line"),
    ("docs/user/change-settings.md", "user/change-settings/", "Everyday tasks", "Change a setting"),
    ("docs/user/parts.md", "user/parts/", "Everyday tasks", "Place the parts"),
    ("docs/user/support.md", "user/support/", "Everyday tasks", "Add support"),
    ("docs/user/filaments.md", "user/filaments/", "Everyday tasks", "Print in colors"),
    ("docs/user/labels.md", "user/labels/", "Everyday tasks", "Labels on a part"),
    ("docs/user/check.md", "user/check/", "Everyday tasks", "Check the print"),
    ("docs/user/calibrate.md", "user/calibrate/", "Everyday tasks", "Calibrate the filament"),
    ("docs/user/plates.md", "user/plates/", "Everyday tasks", "Plates and files"),
    ("docs/user/printers.md", "user/printers/", "Everyday tasks", "Send to a printer"),
    ("docs/user/history.md", "user/history/", "Everyday tasks", "Undo and history"),
    ("docs/user/features.md", "user/features/", "Features", "The best features"),
    ("docs/user/print-as-it-forms.md", "user/print-as-it-forms/", "Features", "The print as it forms"),
    ("docs/user/projects.md", "user/projects/", "Features", "printdeck projects"),
    ("docs/user/farm.md", "user/farm/", "Features", "A print farm"),
    ("docs/user/keys.md", "user/keys/", "Reference", "Keys and mouse"),
    ("docs/user/settings.md", "user/settings/", "Reference", "Settings"),
    ("docs/user/expert.md", "user/expert/", "Reference", "Formulas and rules"),
    ("docs/user/profiles.md", "user/profiles/", "Reference", "Profiles"),
    ("docs/user/setting-coverage.md", "user/setting-coverage/", "Reference", "Cura and OrcaSlicer settings"),
    ("docs/user/command-line.md", "user/command-line/", "Reference", "The command line"),
    ("docs/user/apps.md", "user/apps/", "Reference", "Web, Linux, and Mac"),
    ("docs/user/macos.md", "user/macos/", "Reference", "The macOS app"),
    ("docs/user/windows.md", "user/windows/", "Reference", "The Windows app"),
    ("docs/user/troubleshooting.md", "user/troubleshooting/", "Reference", "Problems and errors"),
    ("docs/embedding/overview.md", "embedding/", "Embedding", "Overview"),
    ("docs/embedding/c.md", "embedding/c/", "Embedding", "C"),
    ("docs/embedding/zig.md", "embedding/zig/", "Embedding", "Zig"),
    ("docs/embedding/javascript.md", "embedding/javascript/", "Embedding", "JavaScript"),
    ("docs/embedding/print-view.md", "embedding/print-view/", "Embedding", "The print view"),
    ("docs/embedding/viewer.md", "embedding/viewer/", "Embedding", "The G-code viewer"),
    ("docs/embedding/labels.md", "embedding/labels/", "Embedding", "Labels"),
    ("docs/internals/architecture.md", "internals/architecture/", "Internals", "Architecture"),
    ("docs/internals/one-view.md", "internals/one-view/", "Internals", "Plan: one view"),
    ("docs/internals/how-slicing-works.md", "internals/how-slicing-works/", "Internals", "How slicing works"),
    ("docs/internals/layer-settings.md", "internals/layer-settings/", "Internals", "Settings for some layers"),
    ("docs/internals/arachne.md", "internals/arachne/", "Internals", "Arachne walls"),
    ("docs/internals/print-sim.md", "internals/print-sim/", "Internals", "The print simulation"),
    ("docs/internals/performance.md", "internals/performance/", "Internals", "Speed: the lower bound"),
    ("docs/internals/cura-compare.md", "internals/cura-compare/", "Internals", "Compared with other slicers"),
    ("docs/internals/contributing.md", "internals/contributing/", "Internals", "Contributing"),
    ("docs/internals/code-quality.md", "internals/code-quality/", "Internals", "Code quality"),
    ("docs/internals/macos.md", "internals/macos/", "Internals", "The macOS app"),
    ("docs/internals/windows.md", "internals/windows/", "Internals", "The Windows app"),
    ("docs/internals/open-links.md", "internals/open-links/", "Internals", "Links that open a model"),
    ("docs/internals/model-import.md", "internals/model-import/", "Internals", "Import from a model page"),
    ("docs/internals/release.md", "internals/release/", "Internals", "CI and releases"),
    ("docs/app/README.md", "app/", "Project", "App"),
    ("ROADMAP.md", "roadmap/", "Project", "Roadmap"),
    ("PRIVACY.md", "privacy/", "Project", "Privacy"),
    ("docs/references/README.md", "references/", "References", "References"),
    ("docs/references/explore.md", "references/explore/", "References", "Explorer"),
    ("docs/references/libraries.md", "references/libraries/", "References", "Libraries and tools"),
    ("docs/references/cura.md", "references/cura/", "References", "Cura"),
    ("docs/references/orcaslicer.md", "references/orcaslicer/", "References", "OrcaSlicer"),
    ("docs/references/prusaslicer.md", "references/prusaslicer/", "References", "PrusaSlicer"),
    ("docs/references/bambu-studio.md", "references/bambu-studio/", "References", "Bambu Studio"),
    ("docs/references/slicer-techniques.md", "references/slicer-techniques/", "References", "Slicer techniques"),
    ("docs/references/printer-data.md", "references/printer-data/", "References", "Printer data"),
    ("docs/references/klipper-marlin-firmware.md", "references/klipper-marlin-firmware/", "References", "Firmware and G-code"),
    ("docs/references/fonts.md", "references/fonts/", "References", "Fonts"),
    ("docs/references/papers-and-algorithms.md", "references/papers-and-algorithms/", "References", "Papers and algorithms"),
    ("docs/references/physics-and-materials.md", "references/physics-and-materials/", "References", "Physics and materials"),
    ("docs/references/formats-and-protocols.md", "references/formats-and-protocols/", "References", "Formats and protocols"),
    ("docs/references/printables.md", "references/printables/", "References", "Printables"),
    ("docs/references/thingiverse.md", "references/thingiverse/", "References", "Thingiverse"),
]
PAGE_OF = {src: path for src, path, _, _ in SOURCES}

# The guide: the pages of these groups have a number, as the pages of a
# gamebook. The links at the end of a page say "Go to 4".
GUIDE = ("Start", "Everyday tasks", "Features")
NUMBER = {}
for _src, _path, _group, _ in SOURCES:
    if _group in GUIDE:
        NUMBER[_path] = len(NUMBER) + 1

# Files that the site links to, but that can be missing. The check prints a note for each.
# The site root is the web app: the Pages workflow puts it there.
OPTIONAL = {"index.html"}


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


# ---------------------------------------------------------------------------------------------
# Markdown. The files use headings, paragraphs, lists (with task boxes and nested lists), fenced
# code, tables, inline code, bold, links and HTML comments. This converter does only those.

def fix_link(url, src_dir, root):
    """The URL of a link in a Markdown file in src_dir, for a page at root."""
    # A link to a page of this site (README.md links so, for readers on GitHub) stays on the
    # site that the reader reads: it becomes a relative link, and the link check checks it.
    if url.startswith(SITE) and url != SITE:
        return root + url[len(SITE):]
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
    # A title in quotes is the caption of a figure (see Markdown.paragraph).
    t = re.sub(r'!\[([^\]]*)\]\(([^)\s]+)(?: +"([^"]*?)")?\)',
               lambda m: f'<img src="{esc(image_link(html.unescape(m.group(2)), src_dir, root))}" alt="{m.group(1)}" loading="lazy"'
                         + (f' title="{m.group(3)}"' if m.group(3) else "") + ">", t)
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
            elif line.strip() == "```ref":
                j = i + 1
                while j < n and not lines[j].lstrip().startswith("```"):
                    j += 1
                out.append(self.ref_card(ref_fields(lines[i + 1:j])))
                i = j + 1
            elif line.lstrip().startswith("```"):
                fence = line[:len(line) - len(line.lstrip())]
                j = i + 1
                while j < n and not lines[j].lstrip().startswith("```"):
                    j += 1
                body = [l[len(fence):] if l.startswith(fence) else l for l in lines[i + 1:j]]
                # A live example: the fence "```html live" puts its HTML in the page, and then
                # shows the same HTML as code. The page runs the code that it shows.
                if line.strip() == "```html live":
                    out.append('<div class="live">' + "\n".join(body) + "</div>")
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
                out.append(self.paragraph(" ".join(s.strip() for s in lines[i:j])))
                i = j
        return "\n".join(out)

    def ref_card(self, f):
        """The fields of a reference entry, as a card (see docs/references/README.md)."""
        rows = []
        for key, label in REF_LABELS:
            v = f.get(key)
            if not v:
                continue
            if key == "link":
                h = f'<a href="{esc(v)}">{esc(v)}</a>'
            elif key in ("files", "texts"):
                h = ", ".join(f'<a href="{esc(repo_url(x))}"><code>{esc(x)}</code></a>' for x in split_list(v))
            else:
                h = self.inline(v)
            rows.append(f"<dt>{label}</dt><dd>{h}</dd>")
        kind = esc(f.get("kind", ""))
        return (f'<div class="ref"><span class="kind k-{kind}">{kind}</span>'
                f'<span class="area">{esc(f.get("area", ""))}</span><dl>{"".join(rows)}</dl></div>')

    def paragraph(self, text):
        """A paragraph. A paragraph of one picture is a figure, with the title of the picture as
        its caption. A paragraph that starts with **Tip:** or **Note:** is a note in a box."""
        h = self.inline(text)
        if (m := re.fullmatch(r'<img ([^>]*?)(?: title="([^"]*)")?>', h)):
            cap = f"<figcaption>{m.group(2)}</figcaption>" if m.group(2) else ""
            return f'<figure class="shot"><img {m.group(1)}>{cap}</figure>'
        if re.match(r"<strong>(Tip|Note):</strong>", h):
            return f'<p class="note">{h}</p>'
        return f"<p>{h}</p>"

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
        items = [m.group(3) for m in map(LIST_ITEM.match, lines) if m]
        if len(items) == len(lines) and all(t.startswith("→ [") for t in items):
            return self.goto(items)
        if len(items) == len(lines) and all(t.startswith("![") for t in items):
            return self.tiles(items)
        return self.plain_list(lines)

    def goto(self, items):
        """A list of "→ [Title](link): text" items: the links to the next pages, as cards."""
        out = []
        for t in items:
            m = re.match(r"→ \[([^\]]+)\]\(([^)\s]+)\):? *(.*)$", t)
            url = fix_link(m.group(2), self.src_dir, self.root)
            num = NUMBER.get(url[len(self.root):].partition("#")[0]) if url.startswith(self.root) else None
            badge = f'<span class="num">{num if num else "→"}</span>'
            out.append(f'<a class="go" href="{esc(url)}">{badge}<b>{self.inline(m.group(1))}</b>'
                       f'<span>{self.inline(m.group(3))}</span></a>')
        return '<nav class="goto">' + "".join(out) + "</nav>"

    def tiles(self, items):
        """A list of "![picture](file) **Title.** text" items: a grid of tiles."""
        out = []
        for t in items:
            h = self.inline(t)
            m = re.match(r"(<img [^>]*>)\s*(.*)$", h, re.S)
            out.append(f'<div class="tile">{m.group(1)}<div>{m.group(2)}</div></div>')
        return '<div class="tiles">' + "".join(out) + "</div>"

    def plain_list(self, lines):
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


# ---------------------------------------------------------------------------------------------
# The references. Each entry of docs/references/*.md is a level 3 heading and a ref block of
# fields. The explorer page lists all entries, with filters, a search, and an index by area.

REF_DIR = "docs/references"
REF_KINDS = ("idea", "code", "data", "font", "paper", "format", "tool", "setting")
REF_AREAS = ("slicing", "walls", "infill", "support", "gcode", "printers", "plate", "physics",
             "files", "network", "fonts", "ui", "build")
REF_NEEDED = ("kind", "source", "license", "files", "area", "summary")
REF_LABELS = (("source", "Source"), ("summary", "What zslice uses"), ("license", "License"),
              ("link", "Link"), ("version", "Version"), ("files", "Used in"), ("texts", "License texts"))


def ref_fields(lines):
    """The fields of a ref block: one "key: value" line each."""
    f = {}
    for line in lines:
        key, sep, value = line.partition(":")
        if sep and key.strip():
            f[key.strip()] = value.strip()
    return f


def split_list(value):
    return [x.strip() for x in value.split(",") if x.strip()]


def repo_url(path):
    kind = "tree" if (ROOT / path).is_dir() else "blob"
    return f"{REPO}/{kind}/{BRANCH}/{path}"


def ref_pages():
    return [src for src, _, group, _ in SOURCES
            if group == "References" and src.startswith(REF_DIR + "/") and not src.endswith(("README.md", "explore.md"))]


def load_refs():
    """All entries: the fields, the title, the page, and the anchor of each."""
    refs = []
    for src in ref_pages():
        lines = read(src).split("\n")
        ids = Markdown("", "")
        title, fence, i = None, False, 0
        while i < len(lines):
            line = lines[i]
            if line.strip() == "```ref" and not fence:
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith("```"):
                    j += 1
                refs.append(dict(ref_fields(lines[i + 1:j]), title=title[0] if title else "", anchor=title[1] if title else "",
                                 page=PAGE_OF[src], src=src))
                i = j + 1
                continue
            if line.lstrip().startswith("```"):
                fence = not fence
            elif not fence and (m := re.match(r"^(#{2,6}) +(.*?)#*$", line)):
                title = (m.group(2).strip(), ids.heading_id(m.group(2).strip()))
            i += 1
    return refs


def check_refs(refs):
    """Stops with an error for an entry with no title, a missing field, an unknown kind or
    area, or a path in files or texts that does not exist."""
    bad = []
    for r in refs:
        where = f"{r['src']}: {r['title'] or '(no heading)'}"
        if not r["title"]:
            bad.append(f"{where}: no level 3 heading")
        for key in REF_NEEDED:
            if not r.get(key):
                bad.append(f"{where}: no {key}")
        if r.get("kind") and r["kind"] not in REF_KINDS:
            bad.append(f"{where}: kind {r['kind']} is not one of {', '.join(REF_KINDS)}")
        if r.get("area") and r["area"] not in REF_AREAS:
            bad.append(f"{where}: area {r['area']} is not one of {', '.join(REF_AREAS)}")
        for key in ("files", "texts"):
            for path in split_list(r.get(key, "")):
                if not (ROOT / path).exists():
                    bad.append(f"{where}: {path} does not exist")
    if bad:
        print("Reference entries with problems:")
        print("\n".join("  " + b for b in bad))
        sys.exit(1)
    print(f"checked {len(refs)} reference entries")


def chips(name, values):
    out = [f'<button type="button" class="chip" data-{name}="" aria-pressed="true">All</button>']
    out += [f'<button type="button" class="chip" data-{name}="{esc(v)}" aria-pressed="false">{esc(v)} <small>{n}</small></button>'
            for v, n in values]
    return f'<div class="chips" role="group" aria-label="{name}">{"".join(out)}</div>'


def explorer(refs, root):
    """The explorer: the chips, the search box, the list of entries, and the index by area. The
    list is plain HTML; the script only hides the entries that do not match."""
    def count(key, many=False):
        c = {}
        # The authors of a paper are not chips: the search finds them.
        for r in (r for r in refs if not many or r["kind"] != "paper"):
            for v in (split_list(r[key]) if many else [r[key]]):
                c[v] = c.get(v, 0) + 1
        return c
    kinds = count("kind")
    areas = count("area")
    sources = sorted(((v, n) for v, n in count("source", True).items() if n > 1 and v != "General"),
                     key=lambda x: (-x[1], x[0]))
    conv = Markdown(REF_DIR, root)
    items = []
    for r in sorted(refs, key=lambda r: r["title"].lower()):
        href = f"{root}{r['page']}#{r['anchor']}"
        files = " ".join(f'<a href="{esc(repo_url(x))}"><code>{esc(x)}</code></a>' for x in split_list(r["files"]))
        link = f' · <a href="{esc(r["link"])}">source</a>' if r.get("link") else ""
        ver = f' · {esc(r["version"])}' if r.get("version") else ""
        text = " ".join([r["title"], r["source"], r["license"], r["summary"], r["files"], r.get("version", "")]).lower()
        items.append(
            f'<li class="rx-item" data-kind="{esc(r["kind"])}" data-area="{esc(r["area"])}" '
            f'data-source="|{esc("|".join(split_list(r["source"])))}|" data-text="{esc(text)}">'
            f'<span class="kind k-{esc(r["kind"])}">{esc(r["kind"])}</span>'
            f'<a class="rx-title" href="{href}">{esc(r["title"])}</a>'
            f'<span class="rx-src">{esc(r["source"])} · {esc(r["license"])}{ver}{link}</span>'
            f'<span class="rx-sum">{conv.inline(r["summary"])}</span>'
            f'<span class="rx-files">{files}</span></li>')
    index = []
    for area in REF_AREAS:
        rs = sorted((r for r in refs if r["area"] == area), key=lambda r: r["title"].lower())
        if not rs:
            continue
        links = "".join(f'<li><a href="{root}{r["page"]}#{r["anchor"]}">{esc(r["title"])}</a> '
                        f'<span class="kind k-{esc(r["kind"])}">{esc(r["kind"])}</span></li>' for r in rs)
        index.append(f'<details><summary>{esc(area)} <small>{len(rs)}</small></summary><ul>{links}</ul></details>')
    by_file = {}
    for r in refs:
        for x in split_list(r["files"]):
            by_file.setdefault(x, []).append(r)
    files = "".join(
        f'<li><a href="{esc(repo_url(x))}"><code>{esc(x)}</code></a>: '
        + ", ".join(f'<a href="{root}{r["page"]}#{r["anchor"]}">{esc(r["title"])}</a>' for r in by_file[x]) + "</li>"
        for x in sorted(by_file))
    return f"""
<div class="rx" id="rx">
<input type="search" id="rx-q" placeholder="Search: a name, a license, a file such as src/offset.zig" aria-label="Search the references">
<p class="rx-label">Kind</p>{chips("kind", sorted(kinds.items()))}
<p class="rx-label">Area of zslice</p>{chips("area", [(a, areas[a]) for a in REF_AREAS if a in areas])}
<p class="rx-label">Source</p>{chips("source", sources)}
<p class="rx-count" id="rx-count">{len(refs)} entries</p>
<ul class="rx-list">{"".join(items)}</ul>
</div>
<h2 id="used-in-by-area">Used in, by area</h2>
{"".join(index)}
<h2 id="used-in-by-file">Used in, by file</h2>
<details><summary>All files <small>{len(by_file)}</small></summary><ul class="rx-files-index">{files}</ul></details>
<script>
(() => {{
  const q = document.getElementById("rx-q"), count = document.getElementById("rx-count");
  const items = [...document.querySelectorAll(".rx-item")];
  const pick = {{ kind: "", area: "", source: "" }};
  function apply() {{
    const words = q.value.toLowerCase().split(/\\s+/).filter(Boolean);
    let shown = 0;
    for (const li of items) {{
      const ok = (!pick.kind || li.dataset.kind === pick.kind) && (!pick.area || li.dataset.area === pick.area) &&
        (!pick.source || li.dataset.source.includes("|" + pick.source + "|")) &&
        words.every((w) => li.dataset.text.includes(w));
      li.hidden = !ok;
      if (ok) shown++;
    }}
    count.textContent = shown + " of " + items.length + " entries";
  }}
  for (const name of Object.keys(pick)) {{
    const group = document.querySelectorAll("[data-" + name + "].chip");
    for (const b of group) b.addEventListener("click", () => {{
      pick[name] = b.dataset[name];
      for (const o of group) o.setAttribute("aria-pressed", String(o === b));
      apply();
    }});
  }}
  q.addEventListener("input", apply);
  const h = new URLSearchParams(location.search);
  if (h.get("q")) {{ q.value = h.get("q"); apply(); }}
}})();
</script>
"""


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
.live { border: 1px solid var(--edge); padding: 12px; margin: 0 0 1.2em; }
.live canvas { display: block; background: var(--plate); }
.live label { display: flex; gap: 10px; align-items: center; margin-top: 10px; flex-wrap: wrap; }
.live input[type="range"] { flex: 1; min-width: 160px; accent-color: var(--orange); }
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

/* The references: the card of an entry, and the explorer */
.ref { margin: 8px 0 14px; padding: 10px 14px; border: 2px solid var(--edge); border-radius: 8px; background: var(--plate2); font-size: 14px; }
.ref dl { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px; margin: 8px 0 0; }
.ref dt { font: 700 11px/1.9 var(--mono); text-transform: uppercase; letter-spacing: .08em; color: var(--dim); }
.ref dd { margin: 0; overflow-wrap: anywhere; }
.kind, .area { display: inline-block; font: 700 11px var(--mono); text-transform: uppercase; letter-spacing: .08em;
  padding: 1px 7px; border-radius: 4px; margin-right: 6px; background: var(--plate); border: 1px solid var(--edge); color: var(--ink); }
.kind.k-code { background: var(--orange); border-color: var(--orange); color: #fff; }
.kind.k-data, .kind.k-font { background: var(--blue); border-color: var(--blue); color: var(--paper); }
.kind.k-paper { border-color: var(--ink); }
.area { background: none; color: var(--dim); }
.rx input[type=search] { width: 100%; font: 15px var(--sans); padding: 8px 12px; border: 2px solid var(--ink); border-radius: 6px;
  background: var(--paper); color: var(--ink); }
.rx-label { margin: 12px 0 4px; font: 700 11px var(--mono); text-transform: uppercase; letter-spacing: .12em; color: var(--dim); }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { font: 600 12px var(--mono); padding: 3px 10px; border: 2px solid var(--edge); border-radius: 999px; background: var(--paper);
  color: var(--ink); cursor: pointer; }
.chip small { color: var(--dim); }
.chip[aria-pressed="true"] { border-color: var(--orange); background: var(--orange); color: #fff; }
.chip[aria-pressed="true"] small { color: #fff; }
.rx-count { font: 600 13px var(--mono); color: var(--dim); }
.rx-list { list-style: none; padding: 0; }
.rx-item { max-width: none; display: grid; grid-template-columns: max-content 1fr; gap: 2px 8px; padding: 10px 0; border-top: 2px solid var(--edge); }
.rx-item[hidden] { display: none; }
.rx-title { font-weight: 600; }
.rx-src, .rx-sum, .rx-files { grid-column: 2; font-size: 14px; }
.rx-src { color: var(--dim); }
.rx-files a { margin-right: 6px; }
details { margin: 6px 0; } details summary { font: 700 14px var(--mono); cursor: pointer; }
details summary small { color: var(--dim); }

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
.map div.card { border: 3px solid var(--ink); border-radius: 10px; background: var(--plate2); padding: 12px 16px; font-size: 14px; }
.map div.card b { display: block; font: 700 12px var(--mono); text-transform: uppercase; letter-spacing: .12em; color: var(--dim); margin-bottom: 6px; }
.map div.card ul { list-style: none; margin: 0; padding: 0; }
.map div.card a { color: var(--ink); text-decoration: none; }
.map div.card a:hover { text-decoration: underline; }
.map div.card .n { display: inline-block; min-width: 24px; font: 700 11px var(--mono); color: var(--orange); }

/* The guide, as a gamebook: a number for each page, a big picture, short steps, and cards
   that say where to go next. */
.side a .n { display: inline-block; min-width: 24px; font: 700 11px var(--mono); color: var(--orange); }
h1 .num { display: inline-block; background: var(--ink); color: var(--paper); border-radius: 6px; padding: 0 10px 2px;
  margin-right: 14px; box-shadow: inset 0 -4px 0 var(--orange); }
figure.shot { margin: 18px 0 28px; max-width: 980px; }
/* The side pictures of the home page (from the README): beside the text,
   on each side in turn; full width on a narrow screen. */
img.side { width: 340px; max-width: 45%; border-radius: 10px; margin: 4px 0 14px; }
img.side-right { float: right; margin-left: 22px; }
img.side-left { float: left; margin-right: 22px; }
.side-clear { clear: both; }
h3 { clear: both; }
@media (max-width: 720px) { img.side { float: none; width: 100%; max-width: 100%; margin: 8px 0; } }
figure.shot img { display: block; width: 100%; border: 4px solid var(--ink); border-radius: 12px; box-shadow: 6px 6px 0 var(--edge);
  background: var(--plate); }
figure.shot figcaption { margin-top: 12px; font: 600 13px/1.4 var(--mono); color: var(--dim); max-width: 76ch; }
p.note { border-left: 6px solid var(--orange); padding: 8px 12px; background: var(--plate); border-radius: 0 8px 8px 0; }
main > ol { list-style: none; padding-left: 0; counter-reset: step; }
main > ol > li { counter-increment: step; position: relative; padding-left: 36px; margin-bottom: 8px; }
main > ol > li::before { content: counter(step); position: absolute; left: 0; top: 0; display: flex; align-items: center; justify-content: center; width: 24px; height: 24px;
  border-radius: 4px; background: var(--orange); color: #fff; font: 700 14px var(--mono); }
.goto { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 12px; margin: 16px 0 8px; }
.goto a.go { display: grid; grid-template-columns: 40px 1fr; column-gap: 10px; align-items: start; padding: 12px 14px;
  border: 3px solid var(--ink); border-radius: 10px; background: var(--plate2); color: var(--ink); text-decoration: none; font-size: 14px; }
.goto a.go:hover { background: var(--plate); box-shadow: 4px 4px 0 var(--edge); }
.goto .num { grid-row: span 2; display: flex; align-items: center; justify-content: center; width: 36px; height: 36px;
  border-radius: 50%; background: var(--orange); color: #fff; border: 3px solid var(--ink); font: 700 15px var(--mono); }
.goto b { font-family: var(--mono); font-size: 15px; }
.goto span:not(.num) { color: var(--dim); }
.tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; margin: 16px 0 24px; }
.tile { border: 3px solid var(--ink); border-radius: 12px; overflow: hidden; background: var(--plate2); box-shadow: 5px 5px 0 var(--edge); }
.tile img { display: block; width: 100%; aspect-ratio: 16 / 10; object-fit: cover; border-bottom: 3px solid var(--ink); background: var(--plate); }
.tile > div { padding: 10px 14px 14px; font-size: 15px; }
.tile > div > strong:first-child { display: block; font-family: var(--mono); font-size: 16px; margin-bottom: 4px; }

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

# The favicon: the small zslice icon (assets/icon/zslice-small.svg).
def _icon():
    import urllib.parse
    svg = (ROOT / "assets" / "icon" / "zslice-small.svg").read_text()
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S)
    svg = re.sub(r"\s+", " ", svg).strip()
    return "data:image/svg+xml," + urllib.parse.quote(svg, safe=" =/:'\"")


ICON = _icon()

PAGES = {}  # folder -> HTML


def nav_html(current, root):
    out, group = [], None
    for _, path, g, title in SOURCES:
        if g != group:
            group = g
            out.append(f'<div class="group">{esc(g)}</div>')
        cur = ' aria-current="page"' if path == current else ""
        num = f'<span class="n">{NUMBER[path]}</span>' if path in NUMBER else ""
        out.append(f'<a href="{root}{path}"{cur}>{num}{esc(title)}</a>')
    return "\n".join(out)


def onpage(body):
    """The list of the level 2 headings of a page."""
    heads = re.findall(r'<h2 id="([^"]+)">(.*?)</h2>', body)
    if len(heads) < 2:
        return ""
    items = "".join(f'<li><a href="#{i}">{re.sub("<[^>]+>", "", t)}</a></li>' for i, t in heads)
    return f'<nav class="onpage"><b>On this page</b><ol>{items}</ol></nav>'


def go_label(path, verb):
    """The label of a link of the pager: "Go to 4" for a page of the guide."""
    if path in NUMBER:
        return f"{verb} {NUMBER[path]}"
    return "Previous" if verb == "Back to" else "Next"


def pager(path, root):
    """The links to the previous and the next page, in the order of the sidebar."""
    paths = [p for _, p, _, _ in SOURCES]
    i = paths.index(path)
    out = []
    if i > 0:
        _, p, _, t = SOURCES[i - 1]
        out.append(f'<a class="prev" href="{root}{p}"><span>{go_label(p, "Back to")}</span><b>{esc(t)}</b></a>')
    if i + 1 < len(SOURCES):
        _, p, _, t = SOURCES[i + 1]
        out.append(f'<a class="next" href="{root}{p}"><span>{go_label(p, "Go to")}</span><b>{esc(t)}</b></a>')
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
<h1>{f'<span class="num">{NUMBER[path]}</span>' if path in NUMBER else ''}{esc(title)}</h1>
{f'<p class="lede">{lede}</p>' if lede else ''}
{body_html}
</main>
</div>
<footer>zslice is free software (AGPL-3.0-or-later). <a href="{root}privacy/">Privacy</a>: no analytics, no cookies, nothing from other sites. <a href="{REPO}/blob/{BRANCH}/docs/build.py">docs/build.py</a> writes this site from <a href="{REPO}/blob/{BRANCH}/{src}">{esc(src)}</a>.</footer>
</body>
</html>
"""


def landing():
    """The home page, from README.md: its text under the title, with the buttons of the site in
    place of the README picture, and a map of the guide at the end."""
    root, src = "", "README.md"
    text = re.sub(r"^# .*\n", "", read(src))
    # The README picture under the title: the page shows it as the hero.
    text = re.sub(r"^\s*!\[[^\]]*\]\([^)]*\)\s*\n", "", text, count=1)
    text = re.sub(r"^\s*<img [^>]*>\s*\n", "", text, count=1)
    # The pictures of the README (HTML img, for their size and side) point
    # at docs/ from the root of the repo; the page is in docs/.
    text = text.replace('src="docs/', 'src="')
    # The note of the README (a quote with a list): plain text here.
    text = re.sub(r"(?m)^> ?", "", text)
    # The side pictures and their clears pass through as HTML: a token
    # each, put back after the Markdown.
    raw = []

    def keep(m):
        tag = m.group(0).strip()
        side = re.search(r'align="(left|right)"', tag)
        if side:
            tag = re.sub(r'\s(align|width)="[^"]*"', "", tag).replace("<img", f'<img class="side side-{side.group(1)}"', 1)
        elif tag.startswith("<br"):
            tag = '<div class="side-clear"></div>'
        raw.append(tag)
        return f"\nZSRAW{len(raw) - 1}\n"

    text = re.sub(r"(?m)^\s*(<img [^>]*>|<br clear=\"\w+\">)\s*$", keep, text)
    conv = Markdown("", root)
    conv.ids.update({"docs"})
    html_body = conv.convert(text)
    for k, tag in enumerate(raw):
        html_body = html_body.replace(f"<p>ZSRAW{k}</p>", tag)
    paras = re.match(r"<p>(.*?)</p>\n?", html_body, re.S)
    lede, rest = paras.group(1), html_body[paras.end():]
    # The map of the guide goes after the best features, before the start and the links.
    cut = rest.find('<h2 id="start">')
    best, after = (rest[:cut], rest[cut:]) if cut >= 0 else (rest, "")
    cards = []
    for group in GUIDE + ("Reference",):
        pages = [(p, t) for _, p, g, t in SOURCES if g == group]
        links = "".join(f'<li><a href="{p}">{f"<span class=n>{NUMBER[p]}</span>" if p in NUMBER else ""}{esc(t)}</a></li>'
                        for p, t in pages)
        cards.append(f'<div class="card"><b>{esc(group)}</b><ul>{links}</ul></div>')
    body = f"""
<p>
  <a class="btn primary" href="index.html">Open the app</a>
  <a class="btn" href="user/getting-started/">Your first print</a>
  <a class="btn" href="user/features/">The best features</a>
  <a class="btn" href="embedding/">Embed the library</a>
  <a class="btn" href="{REPO}">Source on GitHub</a>
</p>
<figure class="shot"><img src="img/hero.webp" alt="The zslice web app: a 3DBenchy, sliced, in the colors of its features"></figure>
{best}
<h2 id="docs">The guide</h2>
<div class="map">{"".join(cards)}</div>
{after}
"""
    page("docs.html", "Documentation", "zslice", lede, body, src, toc=False,
         description="The documentation of zslice, a slicer for FDM 3D printers, written from scratch in Zig.")


def doc_pages(refs):
    for src, path, group, _ in SOURCES[1:]:
        root = "../" * path.count("/")
        title, lede, body = parse(src, root)
        if src == REF_DIR + "/explore.md":
            body += explorer(refs, root)
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
    refs = load_refs()
    check_refs(refs)
    landing()
    doc_pages(refs)
    (DOCS / "site.css").write_text(CSS.strip() + "\n", encoding="utf-8")
    for path, doc in PAGES.items():
        out = DOCS / path if path.endswith(".html") else DOCS / path / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(doc, encoding="utf-8")
    print(f"wrote {len(PAGES)} pages")
    check_links()


if __name__ == "__main__":
    main()
