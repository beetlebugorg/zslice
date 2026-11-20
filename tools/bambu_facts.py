#!/usr/bin/env python3
"""Makes src/printers/bambu.txt: the facts of each Bambu Lab printer that
its file and its nozzles need, from the machine presets of OrcaSlicer.

Usage:
  python3 -I tools/bambu_facts.py <OrcaSlicer>/resources/profiles/BBL/machine > src/printers/bambu.txt

A sparse clone is enough:
  git clone --depth 1 --filter=blob:none --sparse https://github.com/OrcaSlicer/OrcaSlicer
  git -C OrcaSlicer sparse-checkout set resources/profiles/BBL/machine

Each row (tab separated): B, the model id of the printer library
("bambu-lab-x2d"), the model code of Bambu Studio (model_id, "N6"), the
model name ("Bambu Lab X2D"), the number of nozzles, then for each nozzle
the least x, the most x, and the height that it reaches (mm; empty for a
printer with one nozzle: the bed), the extruder types, and the default
nozzle volume types (";" between nozzles).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import json
import os
import subprocess
import sys


def main():
    d = sys.argv[1]
    by = {}
    for f in sorted(os.listdir(d)):
        if not f.endswith(".json"):
            continue
        with open(os.path.join(d, f), encoding="utf-8") as fh:
            j = json.load(fh)
        by[j.get("name")] = j

    def res(name, key, depth=0):
        j = by.get(name)
        if not j or depth > 20:
            return None
        if key in j:
            return j[key]
        return res(j.get("inherits"), key, depth + 1) if j.get("inherits") else None

    commit = ""
    try:
        commit = subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        pass
    print("zslice-bambu 1")
    print("# The Bambu Lab printers: model codes and nozzles. Made by tools/bambu_facts.py; do not edit.")
    print("# From the machine presets of OrcaSlicer (AGPL-3.0), https://github.com/OrcaSlicer/OrcaSlicer %s" % commit)
    for name, j in sorted(by.items()):
        if j.get("type") != "machine_model" or not j.get("model_id"):
            continue
        preset = name + " 0.4 nozzle"
        lib_id = name.lower().replace(" ", "-")
        nozzles = res(preset, "nozzle_diameter") or ["0.4"]
        n = len(nozzles) if isinstance(nozzles, list) else 1
        areas = res(preset, "extruder_printable_area") or []
        heights = res(preset, "extruder_printable_height") or []
        reach = []
        for k in range(n):
            if k < len(areas) and areas[k]:
                xs = [float(p.split("x")[0]) for p in areas[k].split(",")]
                h = heights[k] if k < len(heights) else ""
                reach += ["%g" % min(xs), "%g" % max(xs), "%s" % h]
            else:
                reach += ["", "", ""]
        types = res(preset, "extruder_type") or ["Direct Drive"]
        volumes = res(preset, "default_nozzle_volume_type") or ["Standard"]
        row = ["B", lib_id, j["model_id"], name, str(n)] + reach + [";".join(types[:n]), ";".join(volumes[:n])]
        print("\t".join(row))


main()
