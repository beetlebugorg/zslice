#!/usr/bin/env python3
"""Makes src/printers/bambu.txt: the facts of each Bambu Lab printer that
its file and its nozzles need, from the machine presets of Bambu Studio
(or of OrcaSlicer, which has a copy of them).

Usage:
  python3 -I tools/bambu_facts.py <BambuStudio>/resources/profiles/BBL/machine \
      --gcode src/printers > src/printers/bambu.txt

A sparse clone is enough:
  git clone --depth 1 --filter=blob:none --sparse https://github.com/bambulab/BambuStudio
  git -C BambuStudio sparse-checkout set resources/profiles/BBL/machine

With --gcode <folder>, the tool also writes the G-code templates of each
model into the folder, as the presets of its 0.4 nozzle have them:
bambu/<id>-start.gcode (machine_start_gcode), bambu/<id>-end.gcode
(machine_end_gcode), bambu/<id>-layer.gcode (layer_change_gcode), and
change/<id>.gcode (change_filament_gcode). printers.zig embeds them.

Each row (tab separated): B, the model id of the printer library
("bambu-lab-x2d"), the model code of Bambu Studio (model_id, "N6"), the
model name ("Bambu Lab X2D"), the number of nozzles, then for each nozzle
the least x, the most x, and the height that it reaches (mm; empty for a
printer with one nozzle: the bed), the extruder types, and the default
nozzle volume types (";" between nozzles), the extruder variant
lists ("|" between nozzles), and for each nozzle (";" between nozzles):
the retraction of a filament change (retract_length_toolchange, mm), the
heating and the cooling rate of the hotend (hotend_heating_rate and
hotend_cooling_rate, °C/s), the retraction before the cutter
(retraction_distances_when_cut, mm), and a long retraction at the cut
(long_retractions_when_cut, 0 or 1). Then the retraction of the travels
of the first nozzle, in the form of the last six fields of a P line of
the printer library (see src/printers.zig): z_hop (mm), "c" for the
z_hop_types "Auto Lift" or "a" for the other types, wipe (1 or 0),
wipe_distance (mm), retract_when_changing_layer (1 or 0), and
retraction_minimum_travel (mm).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import argparse
import json
import os
import subprocess
import sys

# The G-code templates of a preset, and the file of each in the --gcode
# folder ("{id}": the model id of the printer library).
TEMPLATES = [
    ("machine_start_gcode", "bambu/{id}-start.gcode"),
    ("machine_end_gcode", "bambu/{id}-end.gcode"),
    ("layer_change_gcode", "bambu/{id}-layer.gcode"),
    ("change_filament_gcode", "change/{id}.gcode"),
]


def source_of(d):
    """The name and the URL of the slicer of the preset folder `d`, from
    the remote of its git clone."""
    try:
        url = subprocess.run(["git", "-C", d, "remote", "get-url", "origin"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        url = ""
    url = url[:-4] if url.endswith(".git") else url
    name = "Bambu Studio" if "bambustudio" in url.lower() else "OrcaSlicer"
    return name, url or "https://github.com/bambulab/BambuStudio"


def first(v):
    """The value of the first nozzle of a preset value, as text, or ""."""
    if isinstance(v, list):
        v = v[0] if v else None
    return "" if v is None else str(v).strip()


def travel_of(get):
    """The retraction of the travels: the last six fields of a P line of
    the printer library. `get(key)` gives the value of a preset key."""
    def num(key):
        t = first(get(key))
        try:
            return "%g" % float(t)
        except ValueError:
            return ""

    def flag(key):
        t = first(get(key)).lower()
        return "1" if t in ("1", "true") else "0" if t in ("0", "false") else ""

    hop = first(get("z_hop_types"))
    # Auto Lift lifts the travels that leave the part (zslice:
    # z_hop_only_crossing); Normal, Slope, and Spiral Lift lift each one.
    mode = "" if not hop else "c" if hop == "Auto Lift" else "a"
    return [num("z_hop"), mode, flag("wipe"), num("wipe_distance"), flag("retract_when_changing_layer"), num("retraction_minimum_travel")]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("machine", help="the folder resources/profiles/BBL/machine")
    ap.add_argument("--gcode", help="the folder src/printers: write the G-code templates of each model")
    a = ap.parse_args()
    d = a.machine
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
    name, url = source_of(d)
    print("zslice-bambu 1")
    print("# The Bambu Lab printers: model codes and nozzles. Made by tools/bambu_facts.py; do not edit.")
    print("# From the machine presets of %s (AGPL-3.0), %s %s" % (name, url, commit))
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
        variants = res(preset, "extruder_variant_list") or [t + " Standard" for t in types[:n]]
        # The values of the extruder options: the presets have one for
        # each extruder variant (printer_extruder_id); each nozzle gets the
        # first variant of its extruder, the standard one.
        ext_ids = res(preset, "printer_extruder_id") or []

        def per_nozzle(key):
            vals = res(preset, key) or []
            vals = vals if isinstance(vals, list) else [vals]
            out = []
            for k in range(n):
                i = next((i for i, e in enumerate(ext_ids) if str(e) == str(k + 1)), k)
                out.append(str(vals[i]) if i < len(vals) else (str(vals[0]) if vals else ""))
            return ";".join(out)

        extra = [per_nozzle(k) for k in ("retract_length_toolchange", "hotend_heating_rate", "hotend_cooling_rate", "retraction_distances_when_cut", "long_retractions_when_cut")]
        extra += travel_of(lambda key: res(preset, key))
        row = ["B", lib_id, j["model_id"], name, str(n)] + reach + [";".join(types[:n]), ";".join(volumes[:n]), "|".join(variants[:n])] + extra
        print("\t".join(row))
        if a.gcode:
            for key, path in TEMPLATES:
                # The presets keep each template in a preset of its own:
                # "<preset> template <key>".
                t = by.get("%s template %s" % (preset, key)) or {}
                text = t.get(key) or res(preset, key)
                if not isinstance(text, str) or not text.strip():
                    continue
                out = os.path.join(a.gcode, path.format(id=lib_id))
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with open(out, "w", encoding="utf-8", newline="") as fh:
                    fh.write(text)


main()
