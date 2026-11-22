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

# The settings of each nozzle after the first: the fields of `Nozzle`, by
# the names machine.nozzle.k.<field> (k: the nozzle, from 1). They are a
# section of the machine group.
NOZZLE = ("Nozzle", "machine.nozzle.k", "Other nozzles",
          "The settings of each nozzle after the first, on a printer with more than one nozzle "
          "(`machine.nozzles`). k is the nozzle, from 1 (the second nozzle, tool T1) to 15. "
          "A value of 0 is the value of the first nozzle. In a profile: `nozzle.1.diameter = 0.6`.")


def parse(src):
    groups = {}
    for struct in [g[0] for g in GROUPS] + [NOZZLE[0]]:
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
            if typ.startswith("[max_nozzles]"):
                # The list of the nozzles after the first: see NOZZLE.
                doc = []
                continue
            if default == "":
                # A multi-line string: the lines that start with \\.
                parts = []
                while i < len(lines) and lines[i].strip().startswith("\\\\"):
                    parts.append(lines[i].strip()[2:])
                    i += 1
                default = "(multi-line text)\n\n```gcode\n" + "\n".join(parts) + "\n```"
            else:
                default = "`" + default.rstrip(",").lstrip(".") + "`"
            if struct == NOZZLE[0]:
                section = NOZZLE[2]
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
    out.write("//! Do not edit by hand. A test in src/app/setting_info.zig checks that each\n")
    out.write("//! setting has an entry.\n\n")
    out.write("pub const Meta = struct {\n    name: []const u8,\n    section: []const u8,\n    doc: []const u8,\n};\n\n")
    out.write("pub const all = [_]Meta{\n")
    for struct, key, _ in GROUPS + [NOZZLE[:3]]:
        for sec, name, typ, default, doc in groups[struct]:
            out.write("    .{ .name = %s, .section = %s, .doc = %s },\n" % (
                zig_string(key + "." + name), zig_string(sec or ""), zig_string(doc)))
    out.write("};\n")


def main():
    src = open("src/settings.zig").read()
    enums = dict(re.findall(r"pub const (\w+) = enum \{ ([^}]*) \};", src))
    groups = parse(src)
    block = re.search(r"pub const layer_settings = \[_\]\[\]const u8\{(.*?)\n\};", src, re.S).group(1)
    per_layer = set(re.findall(r'"([\w.]+)"', block))
    if "--zig" in sys.argv:
        main_zig(groups)
        return
    out = sys.stdout
    out.write("# Settings reference\n\n")
    out.write("<!-- Made by tools/settings_doc.py from src/settings.zig. Do not edit by hand. -->\n\n")
    out.write("Each setting has a name in the form `group.name`. Set it on the command line with `-s group.name=value`, ")
    out.write("in C with `zs_settings_set`, and in JavaScript as a key of the settings object.\n\n")
    out.write("Units: lengths in mm, speeds in mm/s, flow in mm³/s, temperatures in °C. A ratio is 0 to 1.\n\n")
    out.write("A setting marked \"Per layer\" can change for some layers of a part (for example \"This layer and up\" in the app). ")
    out.write("[Settings for some layers](../internals/layer-settings.md) explains the others.\n\n")
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
            if key + "." + name in per_layer:
                t += "; per layer"
            out.write("**`%s.%s`** (%s). Default: %s\n\n" % (key, name, t, default))
            if doc:
                out.write("%s\n\n" % doc)
        if key == "machine":
            out.write("### %s\n\n%s\n\n" % (NOZZLE[2], NOZZLE[3]))
            for sec, name, typ, default, doc in groups[NOZZLE[0]]:
                out.write("**`%s.%s`** (%s). Default: %s\n\n" % (NOZZLE[1], name, type_name(typ), default))
                if doc:
                    out.write("%s\n\n" % doc)


main()
