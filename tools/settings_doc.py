#!/usr/bin/env python3
"""Make docs/user/settings.md from the doc comments in src/settings.zig.

Usage:
  python3 -I tools/settings_doc.py > docs/user/settings.md
  python3 -I tools/settings_doc.py --zig > src/settings_meta.zig

The --zig form writes the section and the help text of each setting for
the app core, which gives them to the settings panel of each app.

Run it after each change to src/settings.zig (see AGENTS.md).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import re
import sys

GROUPS = [
    ("Machine", "machine", "Facts about the printer. They change only when the printer changes."),
    ("Filament", "filament", "Facts about the material."),
    ("Project", "project", "What you want for this part."),
    ("EngineOptions", "engine", "Options for the engine. They do not change the print."),
]


def parse(src):
    groups = {}
    for struct, _, _ in GROUPS:
        m = re.search(r"pub const %s = struct \{\n(.*?)\n\};" % struct, src, re.S)
        body = m.group(1)
        fields = []
        doc = []
        section = None
        lines = body.split("\n")
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            i += 1
            if line.startswith("///"):
                doc.append(line[3:].strip())
                continue
            if line.startswith("//"):
                # A section comment can have more than one line. The heading
                # is the first line, up to the first comma, colon, or period.
                prev = lines[i - 2].strip() if i >= 2 else ""
                if not (prev.startswith("//") and not prev.startswith("///")):
                    section = re.split(r"[,:.]", line[2:].strip())[0].strip()
                doc = []
                continue
            m = re.match(r"(\w+): ([\w\[\]\s]+?) =\s*(.*)$", line)
            if not m:
                doc = []
                continue
            name, typ, default = m.groups()
            if default == "":
                # A multi-line string: the lines that start with \\.
                parts = []
                while i < len(lines) and lines[i].strip().startswith("\\\\"):
                    parts.append(lines[i].strip()[2:])
                    i += 1
                default = "(multi-line text)\n\n```gcode\n" + "\n".join(parts) + "\n```"
            else:
                default = "`" + default.rstrip(",").lstrip(".") + "`"
            fields.append((section, name, typ.strip(), default, " ".join(doc)))
            doc = []
        groups[struct] = fields
    return groups


def type_name(t):
    return {"f64": "number", "u32": "integer", "bool": "true or false", "[]const u8": "text"}.get(t, t)


def zig_string(t):
    return '"' + t.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main_zig(groups):
    out = sys.stdout
    out.write("//! The section and the help text of each setting, for the settings panel\n")
    out.write("//! of each app. Made by tools/settings_doc.py from src/settings.zig.\n")
    out.write("//! Do not edit by hand. A test in src/app.zig checks that each setting\n")
    out.write("//! has an entry.\n\n")
    out.write("pub const Meta = struct {\n    name: []const u8,\n    section: []const u8,\n    doc: []const u8,\n};\n\n")
    out.write("pub const all = [_]Meta{\n")
    for struct, key, _ in GROUPS:
        for sec, name, typ, default, doc in groups[struct]:
            out.write("    .{ .name = %s, .section = %s, .doc = %s },\n" % (
                zig_string(key + "." + name), zig_string(sec or ""), zig_string(doc)))
    out.write("};\n")


def main():
    src = open("src/settings.zig").read()
    enums = dict(re.findall(r"pub const (\w+) = enum \{ ([^}]*) \};", src))
    groups = parse(src)
    if "--zig" in sys.argv:
        main_zig(groups)
        return
    out = sys.stdout
    out.write("# Settings reference\n\n")
    out.write("<!-- Made by tools/settings_doc.py from src/settings.zig. Do not edit by hand. -->\n\n")
    out.write("Each setting has a name in the form `group.name`. Set it on the command line with `-s group.name=value`, ")
    out.write("in C with `zs_settings_set`, and in JavaScript as a key of the settings object.\n\n")
    out.write("Units: lengths in mm, speeds in mm/s, flow in mm³/s, temperatures in °C. A ratio is 0 to 1.\n\n")
    for struct, key, intro in GROUPS:
        out.write("## %s\n\n%s\n\n" % (key, intro))
        section = None
        for sec, name, typ, default, doc in groups[struct]:
            if sec != section and sec:
                out.write("### %s\n\n" % sec)
                section = sec
            t = type_name(typ)
            if typ in enums:
                t = "one of: " + ", ".join("`%s`" % v.strip() for v in enums[typ].split(","))
            out.write("**`%s.%s`** (%s). Default: %s\n\n" % (key, name, t, default))
            if doc:
                out.write("%s\n\n" % doc)


main()
