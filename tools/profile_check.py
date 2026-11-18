#!/usr/bin/env python3
"""Slice a 20 mm cube with each printer of the printer library, and check
the G-code.

Usage: python3 -I tools/profile_check.py <zslice binary> <report folder>
           [--jobs N] [--only ID ...] [--keep]

The tool lists the printers with `zslice printers`, and slices the cube
with `-m <id>` for each one, on all threads. The slices use material
values that no profile has as a fixed number (a first layer nozzle of
207 C, a nozzle of 203 C, a bed of 58 C, a first layer of 0.27 mm), so a
fixed temperature in a start G-code does not pass by chance. Acceleration
control is on, so the G-code has the commands of the flavor.

The checks of each G-code:

- slice: zslice writes a G-code with a first layer.
- vars: no variable of the start or the end G-code stays in a command (a
  {...} or a [name]). Comments do not count.
- temps: at the first layer, the nozzle target is a material value (first
  layer or other layers), and the bed target is the bed value (on a
  printer with a heated bed). The nozzle and the bed targets come from
  M104, M109, M140, M190, SET_HEATER_TEMPERATURE, and the temperature
  arguments of a macro (for example PRINT_START BED=58 EXTRUDER=207).
- flavor: the commands of the flavor of the firmware are in the G-code
  of zslice, and the commands of the other flavors are not.
- bed: each move of zslice (the travels and the extrusions after the
  start of the first layer) stays inside the bed.
- z: the first layer prints at the first layer height.
- end: the commands of the end G-code (the lines with no variable and no
  condition) are the last commands of the file, in their order.

A start G-code that sets a fixed temperature, other than 0 and the
material values, gets a note in the report. It does not fail.

The report folder gets report.txt (the counts, and each failing profile
with its reasons) and results.tsv (one line for each profile). With
--keep, it also gets the G-code of each failing profile in gcode/.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import argparse
import concurrent.futures
import math
import os
import re
import struct
import subprocess
import sys
import tomllib

FIRST_NOZZLE = 207
NOZZLE = 203
BED = 58
FIRST_LAYER = 0.27
SETS = [
    "filament.first_layer_nozzle_temp=%d" % FIRST_NOZZLE,
    "filament.nozzle_temp=%d" % NOZZLE,
    "filament.bed_temp=%d" % BED,
    "project.first_layer_height=%g" % FIRST_LAYER,
    "machine.accel_control=true",
]
CHECKS = ["slice", "vars", "temps", "flavor", "bed", "z", "end"]
TIMEOUT_S = 120
# The start G-code of zslice: a profile with it has no start G-code of
# its vendor.
DEFAULT_START = ""

# The commands of each flavor that zslice writes with acceleration control.
FLAVOR_CMDS = {
    "marlin": [r"^M204 S", r"^M205 X"],
    "klipper": [r"^SET_VELOCITY_LIMIT ACCEL=", r"^SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY="],
    "reprap": [r"^M204 P", r"^M566 X"],
    "repetier": [r"^M201 X", r"^M207 X"],
}


def flavor_of(firmware):
    f = firmware.lower()
    if "klipper" in f:
        return "klipper"
    if "reprap" in f:
        return "reprap"
    if "repetier" in f:
        return "repetier"
    return "marlin"


def write_cube(path, size=20.0):
    """A binary STL of a cube with its corner at the origin."""
    v = [(x, y, z) for x in (0, size) for y in (0, size) for z in (0, size)]
    # Two triangles for each face, with the normals out.
    faces = [
        (0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4),
        (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5),
    ]
    tris = []
    for a, b, c, d in faces:
        tris += [(a, b, c), (a, c, d)]
    with open(path, "wb") as f:
        f.write(b"\0" * 80 + struct.pack("<I", len(tris)))
        for t in tris:
            f.write(struct.pack("<3f", 0, 0, 0))
            for i in t:
                f.write(struct.pack("<3f", *v[i]))
            f.write(b"\0\0")


def command(line):
    """The command part of a G-code line: the text before a comment."""
    return line.split(";", 1)[0].strip()


def words(cmd):
    """The letters of a G-code command with their numbers."""
    out = {}
    for m in re.finditer(r"([A-Z])\s*(-?\d*\.?\d+(?:[eE][-+]?\d+)?)", cmd.upper()):
        out.setdefault(m.group(1), float(m.group(2)))
    return out


OBJECT_MODEL = re.compile(r"\{[^}]*\b[a-z]+\.[a-z]")
PLACEHOLDER = re.compile(r"\{[^{}]*\}|\[[A-Za-z_][A-Za-z_0-9]*(?:\[[^\]]*\])?\]")


def static_lines(template):
    """The commands of a G-code template that have no variable and are in
    no condition, in their order, and True if the last command of the
    template is one of them."""
    out = []
    last_static = False
    depth = 0
    for raw in template.split("\n"):
        line = raw
        opens = len(re.findall(r"\{\s*if\b", line))
        closes = len(re.findall(r"\{\s*endif\s*\}", line))
        inside = depth > 0 or opens > 0
        depth += opens - closes
        cmd = command(line)
        if not cmd and not inside:
            continue
        if inside or "{" in cmd or "}" in cmd or "[" in cmd or "]" in cmd:
            last_static = False
            continue
        out.append(re.sub(r"\s+", " ", cmd))
        last_static = True
    return out, last_static


def temps_of(cmd, state, notes):
    """Updates the nozzle and bed targets in `state` from one command."""
    up = cmd.upper()
    w = words(cmd)
    head = up.split()[0] if up.split() else ""
    def setnoz(v):
        state["nozzle"] = v
        if v not in (0, FIRST_NOZZLE, NOZZLE):
            notes.add("fixed nozzle %g" % v)
    def setbed(v):
        state["bed"] = v
        if v not in (0, BED):
            notes.add("fixed bed %g" % v)
    if head in ("M104", "M109"):
        tool = w.get("T", 0)
        if tool != 0:
            return
        v = w.get("S", w.get("R"))
        if v is not None:
            setnoz(v)
    elif head in ("M140", "M190"):
        v = w.get("S", w.get("R"))
        if v is not None:
            setbed(v)
    elif head == "SET_HEATER_TEMPERATURE":
        m = re.search(r"HEATER=(\S+)", up)
        t = re.search(r"TARGET=(-?\d+\.?\d*)", up)
        if m and t:
            if m.group(1) == "EXTRUDER":
                setnoz(float(t.group(1)))
            elif m.group(1) in ("HEATER_BED", "BED"):
                setbed(float(t.group(1)))
    elif re.match(r"^[A-Z_][A-Z_0-9]*$", head) and "=" in up:
        # A macro: its temperature arguments. A value can be a list for
        # each tool (EXTRUDER_TEMP=207,207): the first is tool 0.
        for k, v in re.findall(r"\b([A-Z_0-9]+)=(-?\d+\.?\d*)", up):
            if any(x in k for x in ("CHAMBER", "MIN", "MAX", "SOAK", "OTHER", "PROBE", "IDLE", "STANDBY", "TOOL", "LAYER_COUNT")):
                if not ("TOOL_TEMP" in k):
                    continue
            if "BED" in k or "PLATE" in k or k in ("B", "BT"):
                setbed(float(v))
            elif any(x in k for x in ("EXTRUDER", "HOTEND", "NOZZLE", "TOOL_TEMP")) or k in ("H", "E", "T", "ET", "TEMP"):
                # EXTRUDER=1 names a tool.
                if float(v) >= 20:
                    setnoz(float(v))


def check(binary, pid, firmware, flags, cube, keep_dir):
    res = {"id": pid, "firmware": firmware, "fail": {}, "notes": set(), "no_value": set(), "vendor": False}
    try:
        prof = subprocess.run([binary, "profile", "machine", "-m", pid], capture_output=True, text=True, timeout=TIMEOUT_S)
        machine = tomllib.loads(prof.stdout)
        res["vendor"] = machine.get("start_gcode", DEFAULT_START) != DEFAULT_START
    except Exception as e:
        res["fail"]["slice"] = "no profile: %s" % e
        return res
    args = [binary, "slice", cube, "-m", pid]
    for s in SETS:
        args += ["-s", s]
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        res["fail"]["slice"] = "time out"
        return res
    g = p.stdout
    if p.returncode != 0 or ";LAYER:0" not in g:
        res["fail"]["slice"] = "exit %d: %s" % (p.returncode, p.stderr.strip().replace("\n", " ")[:200])
        return res
    lines = g.split("\n")
    first = lines.index(";LAYER:0")

    # vars. RepRapFirmware reads its object model in braces
    # ({move.axes[0].min}): these stay.
    rrf = flavor_of(firmware) == "reprap"
    left = []
    for ln in lines:
        c = command(ln)
        if c:
            found = [x for x in PLACEHOLDER.findall(c) if not (rrf and OBJECT_MODEL.search(x))]
            # A brace with no pair is a broken variable.
            rest = PLACEHOLDER.sub("", c)
            if "{" in rest or "}" in rest:
                found.append(c)
            left += found
        m = re.match(r"; zslice: (?:no value for )?([^:,]+)", ln)
        if m and not ln.startswith("; zslice: the start G-code"):
            res["no_value"].add(m.group(1).strip())
    if left:
        res["fail"]["vars"] = "left: " + " ".join(sorted(set(left))[:6])

    # temps: up to the first move of the first layer.
    state = {"nozzle": None, "bed": None}
    for i, ln in enumerate(lines):
        c = command(ln)
        if not c:
            continue
        if i > first and c.split()[0] in ("G0", "G1"):
            break
        temps_of(c, state, res["notes"])
    why = []
    if state["nozzle"] not in (FIRST_NOZZLE, NOZZLE):
        why.append("nozzle %s" % state["nozzle"])
    if "heated" in flags and state["bed"] != BED:
        why.append("bed %s" % state["bed"])
    if why:
        res["fail"]["temps"] = ", ".join(why)

    # The G-code of zslice: from the first layer to the last extrusion.
    last = first
    for i in range(first, len(lines)):
        c = command(lines[i])
        if c.startswith("G1 ") and "E" in c and ("X" in c or "Y" in c):
            if words(c).get("E", 0) > 0:
                last = i
    body = [command(ln) for ln in lines[first:last + 1]]
    body = [c for c in body if c]

    # flavor: zslice writes its first commands after the start G-code
    # ("M83 ; relative extrusion").
    after = max([i for i in range(first) if lines[i] == "M83 ; relative extrusion"] or [first])
    zs = [command(ln) for ln in lines[after:last + 1]]
    zs = [c for c in zs if c]
    want = flavor_of(firmware)
    why = []
    for pat in FLAVOR_CMDS[want]:
        if not any(re.match(pat, c) for c in zs):
            why.append("no %s" % pat[1:].strip())
    for other, pats in FLAVOR_CMDS.items():
        if other == want:
            continue
        for pat in pats:
            if any(re.match(pat, c) for c in zs):
                why.append("%s command %s" % (other, pat[1:].strip()))
    if why:
        res["fail"]["flavor"] = "%s: %s" % (want, ", ".join(why))

    # bed and z
    x0 = machine.get("origin_x", 0)
    y0 = machine.get("origin_y", 0)
    bx = machine.get("bed_size_x", 220)
    by = machine.get("bed_size_y", 220)
    eps = 0.01
    rel = False
    out = []
    z = None
    for c in body:
        head = c.split()[0]
        if head == "G91":
            rel = True
        elif head == "G90":
            rel = False
        if head not in ("G0", "G1") or rel:
            continue
        w = words(c)
        if z is None and "Z" in w:
            z = w["Z"]
        if "X" in w or "Y" in w:
            x = w.get("X")
            y = w.get("Y")
            bad = (x is not None and not (x0 - eps <= x <= x0 + bx + eps)) or (y is not None and not (y0 - eps <= y <= y0 + by + eps))
            if not bad and "round" in flags and x is not None and y is not None:
                cx, cy = x0 + bx / 2, y0 + by / 2
                bad = math.hypot(x - cx, y - cy) > min(bx, by) / 2 + eps
            if bad:
                out.append(c)
    if out:
        res["fail"]["bed"] = "%d moves out, first: %s (bed %g..%g, %g..%g)" % (len(out), out[0], x0, x0 + bx, y0, y0 + by)
    if z is None or abs(z - FIRST_LAYER) > 0.0005:
        res["fail"]["z"] = "first z %s" % z

    # end
    tail = [re.sub(r"\s+", " ", command(ln)) for ln in lines[last + 1:]]
    tail = [c for c in tail if c]
    want_end, last_static = static_lines(machine.get("end_gcode", ""))
    if want_end:
        k = 0
        for c in tail:
            if k < len(want_end) and c.upper() == want_end[k].upper():
                k += 1
        if k < len(want_end):
            res["fail"]["end"] = "missing: %s" % want_end[k]
        elif last_static and tail and tail[-1].upper() != want_end[-1].upper():
            res["fail"]["end"] = "after the end G-code: %s" % tail[-1]

    if res["fail"] and keep_dir:
        with open(os.path.join(keep_dir, pid + ".gcode"), "w") as f:
            f.write(g)
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("binary")
    ap.add_argument("report")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.report, exist_ok=True)
    cube = os.path.join(a.report, "cube20.stl")
    write_cube(cube)
    keep = None
    if a.keep:
        keep = os.path.join(a.report, "gcode")
        os.makedirs(keep, exist_ok=True)
    global DEFAULT_START
    DEFAULT_START = tomllib.loads(subprocess.run([a.binary, "profile", "machine"], capture_output=True, text=True, check=True).stdout).get("start_gcode", "")
    listing = subprocess.run([a.binary, "printers"], capture_output=True, text=True, check=True).stdout
    printers = [ln.split("\t") for ln in listing.split("\n") if ln]
    if a.only:
        printers = [p for p in printers if p[0] in a.only]
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        results = list(ex.map(lambda p: check(a.binary, p[0], p[1], p[2], cube, keep), printers))

    total = len(results)
    with open(os.path.join(a.report, "results.tsv"), "w") as f:
        f.write("id\tfirmware\tvendor_start\t" + "\t".join(CHECKS) + "\tno_value\tnotes\n")
        for r in results:
            cols = ["fail" if c in r["fail"] else ("-" if "slice" in r["fail"] else "ok") for c in CHECKS]
            f.write("%s\t%s\t%s\t%s\t%s\t%s\n" % (r["id"], r["firmware"], "yes" if r["vendor"] else "no", "\t".join(cols), " ".join(sorted(r["no_value"])), "; ".join(sorted(r["notes"]))))
    lines = []
    passed = sum(1 for r in results if not r["fail"])
    lines.append("zslice printer profile check: %d profiles, %d pass all checks" % (total, passed))
    lines.append("material: first layer nozzle %d, nozzle %d, bed %d, first layer %g mm" % (FIRST_NOZZLE, NOZZLE, BED, FIRST_LAYER))
    lines.append("")
    for c in CHECKS:
        lines.append("%-7s %4d of %d pass" % (c, sum(1 for r in results if c not in r["fail"] and "slice" not in r["fail"]), total))
    noted = sum(1 for r in results if r["notes"])
    lines.append("")
    lines.append("%d profiles have the start G-code of their vendor (the others: the start G-code of zslice)" % sum(1 for r in results if r["vendor"]))
    nv = [r for r in results if r["no_value"]]
    lines.append("%d profiles have lines that zslice made comments (a variable with no value)" % len(nv))
    names = {}
    for r in nv:
        for n in r["no_value"]:
            names[n] = names.get(n, 0) + 1
    if names:
        lines.append("  the variables: " + ", ".join("%s (%d)" % kv for kv in sorted(names.items(), key=lambda kv: -kv[1])))
    lines.append("%d profiles set a fixed temperature in the start G-code (a note, no failure)" % noted)
    by_fw = {}
    for r in results:
        k = flavor_of(r["firmware"])
        t = by_fw.setdefault(k, [0, 0])
        t[0] += 1
        t[1] += 0 if r["fail"] else 1
    lines.append("")
    for k, (n, ok) in sorted(by_fw.items()):
        lines.append("flavor %-9s %4d of %4d pass" % (k, ok, n))
    lines.append("")
    lines.append("Failures:")
    for r in sorted(results, key=lambda r: r["id"]):
        if r["fail"]:
            lines.append("%s (%s): %s" % (r["id"], r["firmware"], "; ".join("%s: %s" % (k, v) for k, v in r["fail"].items())))
    lines.append("")
    lines.append("Notes:")
    for r in sorted(results, key=lambda r: r["id"]):
        if r["notes"]:
            lines.append("%s: %s" % (r["id"], "; ".join(sorted(r["notes"]))))
    text = "\n".join(lines) + "\n"
    with open(os.path.join(a.report, "report.txt"), "w") as f:
        f.write(text)
    print("\n".join(lines[: lines.index("Failures:")]))
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
