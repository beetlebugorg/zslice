#!/usr/bin/env python3
"""Slice each STL of a corpus (gen.py) in several setups, and check the G-code.

Each file slices with the support off, on with a grid, and on with trees
(zig-out/bin/zslice slice FILE -s ... -o OUT), at most 60 s each, on 4
processes. The checks of each result:

- the exit code, and the text on stderr;
- the G-code is there and has layers;
- no NaN or inf in it;
- each X and Y of a move is on the bed (the generic printer: 220 x 220
  mm) or within the margin around it;
- no Z under 0;
- the time of the slice.

A part larger than the printer (wider or deeper than the bed, or higher
than its max height: --max-height) must be refused (exit 2, PartTooLarge),
and a part that fits must slice.

Writes OUT_DIR/report.tsv (one line for each case) and prints a summary:
the failures by their reason, and the 10 slowest cases.

Usage: run.py STL_DIR OUT_DIR [--zslice PATH] [--jobs N] [--timeout S]
              [--bed X,Y] [--margin MM] [--max-height MM]
              [--setups off,grid,tree]
              [--only TEXT] [--keep]

--only TEXT slices only the files whose name has TEXT. --keep keeps the
G-code files (else each one goes after its check).

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
import time

SETUPS = {
    "off": ["-s", "project.support=off"],
    "grid": ["-s", "project.support=everywhere", "-s", "project.support_style=grid"],
    "tree": ["-s", "project.support=everywhere", "-s", "project.support_style=tree"],
}

WORD = re.compile(r"([XYZEF])(\S+)")


def stl_size(path):
    """The size of the part of an STL file (x, y, z), binary or ASCII."""
    with open(path, "rb") as f:
        data = f.read()
    lo = [math.inf] * 3
    hi = [-math.inf] * 3

    def add(v):
        for k in range(3):
            lo[k] = min(lo[k], v[k])
            hi[k] = max(hi[k], v[k])

    count = struct.unpack_from("<I", data, 80)[0] if len(data) >= 84 else 0
    if len(data) == 84 + 50 * count:
        for i in range(count):
            o = 84 + 50 * i + 12
            for k in range(3):
                add(struct.unpack_from("<3f", data, o + 12 * k))
    else:
        for m in re.finditer(rb"vertex\s+(\S+)\s+(\S+)\s+(\S+)", data):
            add([float(g) for g in m.groups()])
    return [hi[k] - lo[k] for k in range(3)] if hi[0] >= lo[0] else [0, 0, 0]


def check_gcode(path, bed, margin):
    """The checks of a G-code file: (problems, layers, moves)."""
    problems = []
    layers = 0
    moves = 0
    last_z = None
    bad_xy = 0
    bad_z = 0
    bad_num = 0
    first_bad = ""
    with open(path, "r", errors="replace") as f:
        for line in f:
            if line.startswith(";LAYER:") or line.startswith(";LAYER_CHANGE"):
                layers += 1
                continue
            code = line.split(";", 1)[0].strip()
            if not code or not (code.startswith("G0") or code.startswith("G1")):
                continue
            if code[2:3] not in ("", " "):
                continue  # G10, G11, ... are not moves
            moves += 1
            for key, text in WORD.findall(code):
                try:
                    v = float(text)
                except ValueError:
                    bad_num += 1
                    first_bad = first_bad or code
                    continue
                if math.isnan(v) or math.isinf(v):
                    bad_num += 1
                    first_bad = first_bad or code
                    continue
                if key == "X" and not (-margin <= v <= bed[0] + margin):
                    bad_xy += 1
                    first_bad = first_bad or code
                elif key == "Y" and not (-margin <= v <= bed[1] + margin):
                    bad_xy += 1
                    first_bad = first_bad or code
                elif key == "Z":
                    if v < 0:
                        bad_z += 1
                        first_bad = first_bad or code
                    if last_z is None or v > last_z:
                        last_z = v
    if moves == 0:
        problems.append("no moves")
    if layers == 0:
        problems.append("no layers")
    if bad_num:
        problems.append(f"{bad_num} NaN or inf")
    if bad_xy:
        problems.append(f"{bad_xy} X or Y off the bed")
    if bad_z:
        problems.append(f"{bad_z} Z under 0")
    return problems, layers, moves, first_bad


def run_case(zslice, stl, setup, out_dir, timeout, bed, margin, max_height, keep):
    name = os.path.basename(stl)[:-4]
    out = os.path.join(out_dir, f"{name}__{setup}.gcode")
    cmd = [zslice, "slice", stl] + SETUPS[setup] + ["-o", out]
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        code = p.returncode
        err = p.stderr.strip().replace("\n", " | ")
    except subprocess.TimeoutExpired:
        code = None
        err = f"timeout after {timeout} s"
    secs = time.monotonic() - t0
    problems = []
    layers = moves = 0
    first_bad = ""
    size = stl_size(stl)
    too_large = size[0] > bed[0] or size[1] > bed[1] or size[2] > max_height
    refused = code == 2 and "PartTooLarge" in err
    if code is None:
        problems.append("timeout")
    elif code < 0:
        problems.append(f"signal {-code}")
    elif too_large and code == 0:
        # The printer cannot print it: the slicer must say so.
        problems.append("a part larger than the printer sliced")
    elif not too_large and refused:
        problems.append("a part that fits was refused")
    elif code != 0 and not refused:
        problems.append(f"exit {code}")
    if code == 0 and not too_large:
        if not os.path.exists(out):
            problems.append("no G-code")
        else:
            found, layers, moves, first_bad = check_gcode(out, bed, margin)
            problems += found
    if os.path.exists(out) and not keep:
        os.remove(out)
    return {
        "file": name,
        "setup": setup,
        "ok": not problems,
        "refused": refused,
        "problems": "; ".join(problems),
        "exit": "" if code is None else str(code),
        "seconds": secs,
        "layers": layers,
        "moves": moves,
        "stderr": err[:300],
        "first_bad": first_bad[:120],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stl_dir")
    ap.add_argument("out_dir")
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--zslice", default=os.path.join(root, "zig-out", "bin", "zslice"))
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--bed", default="220,220")
    ap.add_argument("--margin", type=float, default=5)
    ap.add_argument("--max-height", type=float, default=250)
    ap.add_argument("--setups", default="off,grid,tree")
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    bed = [float(v) for v in a.bed.split(",")]
    setups = [s for s in a.setups.split(",") if s in SETUPS]
    os.makedirs(a.out_dir, exist_ok=True)
    stls = sorted(os.path.join(a.stl_dir, f) for f in os.listdir(a.stl_dir) if f.lower().endswith(".stl") and a.only in f)
    cases = [(s, u) for s in stls for u in setups]
    print(f"{len(cases)} cases: {len(stls)} files x {len(setups)} setups, {a.jobs} at a time", flush=True)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(run_case, a.zslice, s, u, a.out_dir, a.timeout, bed, a.margin, a.max_height, a.keep) for s, u in cases]
        for i, fut in enumerate(concurrent.futures.as_completed(futs), 1):
            r = fut.result()
            results.append(r)
            if not r["ok"]:
                print(f"FAIL {r['file']} {r['setup']}: {r['problems']} {r['stderr'][:120]}", flush=True)
            if i % 50 == 0:
                print(f"{i} of {len(cases)} done", flush=True)
    results.sort(key=lambda r: (r["file"], r["setup"]))
    cols = ["file", "setup", "ok", "refused", "problems", "exit", "seconds", "layers", "moves", "stderr", "first_bad"]
    with open(os.path.join(a.out_dir, "report.tsv"), "w") as f:
        f.write("\t".join(cols) + "\n")
        for r in results:
            f.write("\t".join(f"{r[c]:.3f}" if c == "seconds" else str(r[c]).replace("\t", " ") for c in cols) + "\n")
    fails = [r for r in results if not r["ok"]]
    refused = sum(1 for r in results if r["ok"] and r["refused"])
    print(f"\n{len(results) - len(fails)} of {len(results)} cases pass ({refused} of them: a part larger than the printer, refused)")
    by = {}
    for r in fails:
        for p in r["problems"].split("; "):
            key = re.sub(r"^\d+ ", "", p)
            by.setdefault(key, []).append(f"{r['file']} ({r['setup']})")
    for key, items in sorted(by.items(), key=lambda kv: -len(kv[1])):
        print(f"- {key}: {len(items)}: " + ", ".join(items[:8]) + (" ..." if len(items) > 8 else ""))
    print("\nThe 10 slowest cases:")
    for r in sorted(results, key=lambda r: -r["seconds"])[:10]:
        print(f"  {r['seconds']:7.2f} s  {r['file']} ({r['setup']}) {r['problems']}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
