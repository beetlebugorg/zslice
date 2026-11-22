#!/usr/bin/env python3
"""Make docs/user/setting-coverage.md: each setting of Cura and of
OrcaSlicer, and the zslice setting that does the same, or why zslice
does not have it.

The lists of the settings come from the sources of the two slicers. The
zslice side comes from tools/setting_coverage_cura.txt and
tools/setting_coverage_orca.txt.

Usage:
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Ultimaker/Cura.git <dir>/cura
  git -C <dir>/cura sparse-checkout set --no-cone '/resources/definitions/fdm*.def.json'
  git clone --depth 1 --filter=blob:none --sparse https://github.com/SoftFever/OrcaSlicer.git <dir>/orca
  git -C <dir>/orca sparse-checkout set --no-cone '/src/libslic3r/PrintConfig.cpp'
  python3 -I tools/setting_coverage.py <dir> > docs/user/setting-coverage.md

  --usage FILE   a JSON file with the use of each key in real profiles
                 ({"cura": {key: n}, "curale": {...}, "orca": {...}}).
                 With it, the tool writes the working table (with the use
                 counts, the missing settings first by use) in place of the
                 user page.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import json
import re
import subprocess
import sys
from collections import Counter, OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent

CURA_CATEGORIES = OrderedDict([
    ("resolution", "Quality"), ("shell", "Walls"), ("top_bottom", "Top and bottom"), ("infill", "Infill"),
    ("material", "Material"), ("speed", "Speed"), ("travel", "Travel"), ("cooling", "Cooling"),
    ("support", "Support"), ("platform_adhesion", "Build plate adhesion"), ("dual", "Dual extrusion"),
    ("meshfix", "Mesh fixes"), ("blackmagic", "Special modes"), ("experimental", "Experimental"),
    ("machine_settings", "Machine"), ("command_line_settings", "Command line"), ("ppr", "Print process reporting"),
])

# The blocks of PrintConfig.cpp that are not FDM print settings.
ORCA_BLOCKS = {
    "init_sla_params": ("not", "resin (SLA) printers: zslice slices for FDM printers"),
    "CLIActionsConfigDef": ("not", "an option of the orca-slicer command line"),
    "CLITransformConfigDef": ("not", "an option of the orca-slicer command line"),
    "CLIMiscConfigDef": ("not", "an option of the orca-slicer command line"),
}
ORCA_VARIABLE_BLOCKS = {
    "ReadOnlySlicingStatesConfigDef", "ReadWriteSlicingStatesConfigDef", "OtherSlicingStatesConfigDef",
    "PrintStatisticsConfigDef", "ObjectsInfoConfigDef", "DimensionsConfigDef", "TemperaturesConfigDef",
    "TimestampsConfigDef", "OtherPresetsConfigDef", "CustomGcodeSpecificConfigDef",
}

STATUS_NAMES = {"same": "Same", "derived": "Covered", "missing": "Missing", "not": "Not for zslice"}


def cura_settings(root):
    out = []
    for name in ("fdmprinter", "fdmextruder"):
        d = json.loads((root / "resources/definitions" / f"{name}.def.json").read_text(encoding="utf-8"))

        def walk(node, cat):
            for k, v in node.items():
                if not isinstance(v, dict):
                    continue
                if v.get("type") == "category":
                    walk(v.get("children", {}), k)
                    continue
                out.append({"key": k, "label": v.get("label", ""), "category": cat})
                walk(v.get("children", {}), cat)

        walk(d["settings"], None)
    seen, unique = set(), []
    for s in out:
        if s["key"] not in seen:
            seen.add(s["key"])
            unique.append(s)
    return unique


def orca_settings(root):
    src = (root / "src/libslic3r/PrintConfig.cpp").read_text(encoding="utf-8")
    blocks = [(m.start(), m.group(1) or m.group(2))
              for m in re.finditer(r"\n(?:void \w+::(\w+)\(\)|(\w+ConfigDef)::\w+ConfigDef\(\))", src)]
    out, seen = [], set()
    for m in re.finditer(r'def\s*=\s*this->add(?:_nullable)?\("([^"]+)",\s*co\w+\);(.*?)(?=def\s*=\s*this->add|\n}\n)', src, re.S):
        key, body = m.group(1), m.group(2)
        if key in seen:
            continue
        seen.add(key)
        block = ""
        for at, name in blocks:
            if at < m.start():
                block = name
        lab = re.search(r'def->label\s*=\s*L?\(?"([^"]*)"', body)
        cat = re.search(r'def->category\s*=\s*L?\(?"([^"]*)"', body)
        out.append({"key": key, "label": lab.group(1) if lab else "", "category": cat.group(1) if cat else "", "block": block})
    return out


def read_table(path):
    table = {}
    for n, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3 or parts[1] not in STATUS_NAMES:
            sys.exit(f"{path.name}:{n}: expected 'key | same|derived|missing|not | text'")
        table[parts[0]] = (parts[1], parts[2])
    return table


def gcode_variable_names():
    """The G-code variable names that zslice fills in (src/gcode_vars.zig)."""
    text = (HERE.parent / "src/gcode_vars.zig").read_text(encoding="utf-8")
    return set(re.findall(r'\.\{ "([a-z0-9_]+)", (?:just|each)\(', text))


def zslice_settings():
    """The dotted names of the zslice settings (src/settings_meta.zig)."""
    text = (HERE.parent / "src/settings_meta.zig").read_text(encoding="utf-8")
    return set(re.findall(r'\.name = "([a-z]+\.[a-z0-9_.]+)"', text))


def classify(root):
    cura = cura_settings(root / "cura")
    orca = orca_settings(root / "orca")
    ct = read_table(HERE / "setting_coverage_cura.txt")
    ot = read_table(HERE / "setting_coverage_orca.txt")
    names = zslice_settings()
    variables = gcode_variable_names()
    problems = []
    for table, keys, who in ((ct, {s["key"] for s in cura}, "Cura"), (ot, {s["key"] for s in orca}, "OrcaSlicer")):
        for k, (status, text) in table.items():
            if k not in keys:
                problems.append(f"{who}: {k} is not a setting of the source")
            if status == "same":
                for n in re.findall(r"\b(?:machine|filament|project|engine)\.[a-z0-9_]+(?:\.k\.[a-z0-9_]+)?", text):
                    if n not in names:
                        problems.append(f"{who}: {k}: {n} is not a zslice setting")
    for s in cura:
        s["status"], s["text"] = ct.get(s["key"], ("missing", s["label"]))
    for s in orca:
        if s["key"] in ot:
            s["status"], s["text"] = ot[s["key"]]
        elif s["block"] in ORCA_BLOCKS:
            s["status"], s["text"] = ORCA_BLOCKS[s["block"]]
        elif s["block"] in ORCA_VARIABLE_BLOCKS:
            if s["key"] in variables:
                s["status"], s["text"] = "derived", "a G-code variable that zslice fills in (src/gcode_vars.zig)"
            else:
                s["status"], s["text"] = "missing", "a G-code variable"
        else:
            s["status"], s["text"] = "missing", s["label"]
    return cura, orca, problems


def code(text):
    """The zslice setting names of a text in backticks."""
    return re.sub(r"(?<!`)\b((?:machine|filament|project|engine)\.[a-z0-9_]+(?:\.k\.[a-z0-9_]+)?(?: = [a-z_]+)?)", r"`\1`", text)


def counts(rows):
    c = Counter(r["status"] for r in rows)
    return [c[s] for s in STATUS_NAMES]


def commit(path):
    try:
        return subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "?"


def user_page(root, cura, orca):
    out = ["# Cura and OrcaSlicer settings", "",
           "Each setting of Cura and of OrcaSlicer, and the zslice setting that does the same. "
           "Use this page to move a profile from another slicer to zslice. "
           "`zslice import cura` converts the settings of a Cura profile with a zslice setting.", "",
           "<!-- tools/setting_coverage.py makes this page. Do not edit it by hand. -->", "",
           "The status of a setting:", "",
           "- **Same**: zslice has a setting with the same meaning. The column names it.",
           "- **Covered**: zslice does the same with no setting of its own, or another setting covers it.",
           "- **Missing**: zslice does not have it yet.",
           "- **Not for zslice**: a setting for other hardware, for the app of the other slicer, or for a method that zslice does in another way.", "",
           f"The lists come from Cura `resources/definitions/fdmprinter.def.json` and `fdmextruder.def.json` (commit `{commit(root / 'cura')[:12]}`) "
           f"and OrcaSlicer `src/libslic3r/PrintConfig.cpp` (commit `{commit(root / 'orca')[:12]}`).", "",
           "## Totals", "",
           "| Slicer | Settings | Same | Covered | Missing | Not for zslice |", "|---|---|---|---|---|---|"]
    for name, rows in (("Cura", cura), ("OrcaSlicer", orca)):
        out.append(f"| {name} | {len(rows)} | " + " | ".join(str(n) for n in counts(rows)) + " |")
    out += ["", "## Cura", ""]
    for cat, title in CURA_CATEGORIES.items():
        rows = [r for r in cura if r["category"] == cat]
        if not rows:
            continue
        out += [f"### {title}", "", "| Cura setting | Status | zslice |", "|---|---|---|"]
        for r in rows:
            out.append(f"| `{r['key']}` ({r['label']}) | {STATUS_NAMES[r['status']]} | {code(r['text'])} |")
        out.append("")
    out += ["## OrcaSlicer", "",
            "The print, printer, and filament settings first, by status. The settings of resin printers, the options of the command line, and the G-code variables are at the end.", ""]
    fff = [r for r in orca if r["block"] in ("init_fff_params", "init_common_params")]
    other = [r for r in orca if r not in fff]
    for status in STATUS_NAMES:
        rows = sorted((r for r in fff if r["status"] == status), key=lambda r: r["key"])
        if not rows:
            continue
        out += [f"### {STATUS_NAMES[status]}", "", "| OrcaSlicer setting | zslice |", "|---|---|"]
        for r in rows:
            label = f" ({r['label']})" if r["label"] else ""
            out.append(f"| `{r['key']}`{label} | {code(r['text'])} |")
        out.append("")
    out += ["### Other blocks", "", "| OrcaSlicer key | Status | Note |", "|---|---|---|"]
    for r in sorted(other, key=lambda r: (r["block"], r["key"])):
        out.append(f"| `{r['key']}` | {STATUS_NAMES[r['status']]} | {code(r['text'])} |")
    return "\n".join(out) + "\n"


def working_table(cura, orca, usage):
    out = ["# 120: Setting coverage (working table)", "",
           "Made by `tools/setting_coverage.py --usage`. The use counts are the profiles that set the key:",
           "Cura resources (quality and intent), Cura LulzBot Edition (quality and definitions), and the",
           "OrcaSlicer vendor profiles (process, filament, machine).", ""]
    for name, rows, uses in (("Cura", cura, lambda k: (usage["cura"].get(k, 0), usage["curale"].get(k, 0))),
                             ("OrcaSlicer", [r for r in orca if r["block"] in ("init_fff_params", "init_common_params")],
                              lambda k: (usage["orca"].get(k, 0),))):
        out += [f"## {name}: missing, by use", ""]
        miss = sorted((r for r in rows if r["status"] == "missing"), key=lambda r: -sum(uses(r["key"])))
        head = "| Key | Use (Cura, LE) | Note |" if name == "Cura" else "| Key | Use | Note |"
        out += [head, "|---|---|---|"]
        for r in miss:
            out.append(f"| `{r['key']}` | {', '.join(str(u) for u in uses(r['key']))} | {r['text']} |")
        out.append("")
    return "\n".join(out) + "\n"


def main():
    args = sys.argv[1:]
    usage = None
    if "--usage" in args:
        i = args.index("--usage")
        usage = json.loads(Path(args[i + 1]).read_text(encoding="utf-8"))
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    root = Path(args[0])
    cura, orca, problems = classify(root)
    if problems:
        sys.exit("\n".join(problems))
    sys.stdout.write(working_table(cura, orca, usage) if usage else user_page(root, cura, orca))
    for name, rows in (("Cura", cura), ("OrcaSlicer", orca)):
        print(f"{name}: {len(rows)} settings: " + ", ".join(f"{STATUS_NAMES[s]} {n}" for s, n in zip(STATUS_NAMES, counts(rows))), file=sys.stderr)


if __name__ == "__main__":
    main()
