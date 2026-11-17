#!/usr/bin/env python3
"""Slice a corpus of STL files with zslice and with CuraEngine, and compare.

Usage:
  python3 -I tools/compare_cura.py run <zslice binary> <out folder>
      [--root DIR] [--jobs N] [--timeout S] [--limit N] [--rescan]
  python3 -I tools/compare_cura.py summary <out folder>
  python3 -I tools/compare_cura.py check <model.stl> ...
  python3 -I tools/compare_cura.py walls <zslice binary> <model.stl> <out folder>

run: The script finds each STL file under the root folder (default
~/Projects). It skips .git, node_modules, .zig-cache, and the zslice-*
worktrees. It removes copies by the sha1 of the content. For each content
it keeps one path, and it prefers a path that git tracks in a main
checkout. The list goes in <out>/corpus.tsv. The next run uses that list
again; --rescan makes a new list.

Each unique file is sliced by zslice and by CuraEngine, one after the
other, with one thread each, at nice level 10. N files are sliced in
parallel. The default N is 2. Each slicer process has an address space
limit of 3 GB (MEMORY_CAP). These limits keep the computer usable.
Each slice has a time limit (default 120 s). The results go in
<out>/results.csv, one row for each file, as each file finishes. A new run skips the files that are in results.csv already, so
the script can stop and continue. At the end, the script writes
<out>/summary.md.

The two slicers get the same main settings (see ZSLICE_SETTINGS and
CURA_SETTINGS): the TAZ Workhorse SE machine with a 0.5 mm nozzle and
2.85 mm filament, a 2000 x 2000 x 2000 mm bed so that each part fits,
layer height 0.2 mm, first layer 0.3 mm, 2 walls, 0.8 mm top, 0.6 mm
bottom, 20 % grid infill, no support, a 1-loop skirt, and the part at the
center of the bed. The speeds are the same. Both slicers get a very high
acceleration, so that the time estimates compare without the two
acceleration models.

For each slicer, the row has: the status (ok, error, crash, timeout, oom), the
wall time, the CPU time, the peak memory (ru_maxrss of the child), the
layer count, the filament length, the print time estimate, the filament of
each feature type (from the ;TYPE: comments of the G-code), and the error
text.

check: Print the facts of a mesh: the triangle count, the size, the
degenerate triangles, the open edges (one triangle), the non-manifold edges
(more than two triangles), the edges with two triangles in the same
direction (flipped normals), and the parts (groups of triangles that share
edges).

walls: Slice one model with zslice (classic walls, and Arachne walls with
the Arachne settings of Cura) and with CuraEngine, and compare the walls:
the wall paths and the wall volume of each layer, and the share of the
wall length in each band of line width. The width of a move comes from its
extrusion: CuraEngine extrudes a rectangle of the line width and the layer
height, zslice the bead of flow.zig. The volumes differ by the two bead
models.

CuraEngine (AGPL-3.0) is a tool that this script runs. No code is copied.
See REFERENCES.md.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import concurrent.futures
import csv
import hashlib
import math
import os
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time

CURA_DIR = "/opt/ultimaker-cura"
CURA_ENGINE = CURA_DIR + "/CuraEngine"
# The CuraEngine binary of the AppImage has a relative path to its
# loader, so the script starts it with the system loader.
CURA_LOADER = "/lib64/ld-linux-x86-64.so.2"
CURA_DEFS = CURA_DIR + "/share/cura/resources/definitions"
CURA_EXTRUDERS = CURA_DIR + "/share/cura/resources/extruders"
TAZ_DEFS = os.path.expanduser(
    "~/Projects/printdeck/profiles/taz-workhorse-se/definitions")
TAZ_STACK = os.path.expanduser("~/Projects/printdeck/profiles/taz-workhorse-se")
TAZ_MACHINE = "lulzbot_taz_workhorse_se"

SKIP_DIRS = {".git", "node_modules", ".zig-cache", "zig-out"}

BED = 2000

# The address space limit of each slicer process. A slice that needs more
# gets the status "oom". The cap keeps the computer usable.
MEMORY_CAP = 3 * 1024 ** 3

OOM_TEXT = ("OutOfMemory", "bad_alloc", "out of memory", "Cannot allocate memory")

ZSLICE_SETTINGS = [
    "machine.bed_size_x=%d" % BED,
    "machine.bed_size_y=%d" % BED,
    "machine.max_height=%d" % BED,
    "machine.travel_speed=150",
    "machine.retract_length=1.5",
    "machine.retract_speed=35",
    # The same very high acceleration as CuraEngine (see CURA_SETTINGS), so
    # that the two time estimates compare.
    "machine.max_accel=100000",
    "machine.max_z_accel=100000",
    "machine.corner_speed=100",
    "filament.min_layer_time=6",
    "filament.min_speed=10",
    "project.layer_height=0.2",
    "project.first_layer_height=0.3",
    "project.wall_count=2",
    "project.top_thickness=0.8",
    "project.bottom_thickness=0.6",
    "project.infill_density=0.2",
    "project.infill_pattern=grid",
    "project.support=off",
    "project.skirt_loops=1",
    "project.skirt_distance=3",
    "project.skirt_layers=1",
    "project.brim_width=0",
    "project.placement=center",
    "engine.threads=1",
]

# CuraEngine on the command line does not compute the settings that have a
# "value" expression. It uses the "default_value". So each setting that
# depends on another one is given here with the value that Cura computes
# from these settings.
# zslice speeds are ratios of machine.max_speed (60 mm/s on the TAZ):
# outer wall 0.5, inner wall 0.8, skin 0.7, infill 1.0, first layer 0.3.
CURA_SETTINGS = [
    "center_object=true",
    "machine_width=%d" % BED,
    "machine_depth=%d" % BED,
    "machine_height=%d" % BED,
    "layer_height=0.2",
    "layer_height_0=0.3",
    "layer_0_z_overlap=0.15",
    "line_width=0.5",
    "wall_line_width=0.5",
    "wall_line_width_0=0.5",
    "wall_line_width_x=0.5",
    "skin_line_width=0.5",
    "infill_line_width=0.5",
    "skirt_brim_line_width=0.5",
    "initial_layer_line_width_factor=100",
    "wall_thickness=1.0",
    "wall_line_count=2",
    "top_bottom_thickness=0.8",
    "top_thickness=0.8",
    "bottom_thickness=0.6",
    "top_layers=4",
    "bottom_layers=3",
    "initial_bottom_layers=3",
    "roofing_layer_count=0",
    "flooring_layer_count=0",
    "infill_sparse_density=20",
    "infill_pattern=grid",
    # Grid has two line directions, so the line distance is
    # 2 * line width / density.
    "infill_line_distance=5.0",
    "zig_zaggify_infill=false",
    "infill_sparse_thickness=0.2",
    "skin_overlap_mm=0.025",
    "infill_overlap_mm=0.05",
    "infill_wipe_dist=0.125",
    "small_skin_width=1.0",
    "top_bottom_skin_merge_distance=1.5",
    "wall_transition_length=0.5",
    "wall_transition_filter_deviation=0.125",
    "min_wall_line_width=0.425",
    "min_even_wall_line_width=0.425",
    "min_odd_wall_line_width=0.425",
    "min_bead_width=0.425",
    "min_feature_size=0.125",
    "material_diameter=2.85",
    "material_print_temperature=210",
    "material_print_temperature_layer_0=210",
    "material_initial_print_temperature=210",
    "material_final_print_temperature=210",
    "material_bed_temperature=60",
    "material_bed_temperature_layer_0=60",
    "speed_print=60",
    "speed_infill=60",
    "speed_wall=48",
    "speed_wall_0=30",
    "speed_wall_x=48",
    "speed_topbottom=42",
    "speed_roofing=42",
    "speed_layer_0=18",
    "speed_print_layer_0=18",
    "speed_travel_layer_0=150",
    "skirt_brim_speed=18",
    "speed_travel=150",
    "speed_slowdown_layers=1",
    "cool_min_layer_time=6",
    "cool_min_speed=10",
    "support_enable=false",
    "adhesion_type=skirt",
    "skirt_line_count=1",
    "skirt_gap=3",
    "brim_line_count=0",
    # Cura adds skirt loops up to this length. zslice has no such setting.
    "skirt_brim_minimal_length=0",
    # The default is 3 layers when skirt_gap > 0. zslice prints 1 layer.
    "skirt_height=1",
    "retraction_enable=true",
    "retraction_amount=1.5",
    "retraction_speed=35",
    "retraction_retract_speed=35",
    "retraction_prime_speed=35",
    "acceleration_enabled=false",
    "jerk_enabled=false",
    "machine_acceleration=100000",
    "machine_max_acceleration_x=100000",
    "machine_max_acceleration_y=100000",
    "machine_max_acceleration_z=100000",
    "machine_max_acceleration_e=100000",
    "acceleration_travel=100000",
    "jerk_travel=1000",
    "machine_max_jerk_xy=1000",
    "machine_max_feedrate_z=10",
    "reset_flow_duration=0",
]

TYPES = ["WALL-OUTER", "WALL-INNER", "SKIN", "FILL", "SKIRT", "OTHER"]
SLICERS = ["z", "c"]
PER_SLICER = (["status", "wall_s", "cpu_s", "peak_mb", "layers", "filament_m",
               "time_s"] + ["fil_" + t.lower().replace("-", "_") for t in TYPES]
              + ["error"])
COLUMNS = (["sha1", "path", "bytes", "triangles"]
           + ["%s_%s" % (s, c) for s in SLICERS for c in PER_SLICER])

# The child merges the output and the errors of the slicer, and keeps
# the error lines and the last lines. The child measures the peak memory
# of its own child, because RUSAGE_CHILDREN in the parent adds up the
# children of all threads.
PROBE = r"""
import os, resource, subprocess, sys, time
os.nice(10)
timeout = float(sys.argv[1])
limit = int(sys.argv[2])

def cap():
    resource.setrlimit(resource.RLIMIT_AS, (limit, limit))

t0 = time.monotonic()
try:
    p = subprocess.run(sys.argv[3:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout, preexec_fn=cap)
    code, err = p.returncode, p.stdout
except subprocess.TimeoutExpired as e:
    code, err = "timeout", (e.stdout or b"")
dt = time.monotonic() - t0
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
sys.stdout.write("%s\n%.3f\n%.3f\n%d\n" % (code, dt, ru.ru_utime + ru.ru_stime, ru.ru_maxrss))
lines = err.decode("utf-8", "replace").splitlines()
bad = [l for l in lines if "[error]" in l or "[critical]" in l]
tail = [l for l in lines[-5:] if l not in bad[-5:]]
sys.stdout.write("\n".join(bad[-5:] + tail))
"""


# ---------------------------------------------------------------- corpus

def stl_triangles(path, size):
    """The triangle count from the binary header, or from the ASCII text."""
    with open(path, "rb") as f:
        head = f.read(84)
        if len(head) == 84:
            n = struct.unpack("<I", head[80:84])[0]
            if 84 + 50 * n == size:
                return n
        f.seek(0)
        count = 0
        for line in f:
            if line.lstrip().startswith(b"facet"):
                count += 1
        return count


def git_tracked(repo):
    p = subprocess.run(["git", "-C", repo, "ls-files", "-z", ":(icase)*.stl"],
                       capture_output=True)
    if p.returncode != 0:
        return set()
    return {os.path.join(repo, f) for f in p.stdout.decode().split("\0") if f}


def scan(root):
    """Return a list of (sha1, path, bytes) for each unique STL content."""
    files, tracked, main_repos = [], set(), set()
    for d, dirs, names in os.walk(root):
        if ".git" in dirs or ".git" in names:
            tracked |= git_tracked(d)
            if ".git" in dirs:
                main_repos.add(d + os.sep)
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS
                         and not (d == root and x.startswith("zslice-")))
        files += [os.path.join(d, n) for n in names if n.lower().endswith(".stl")]

    def rank(path):
        in_main = any(path.startswith(r) for r in main_repos) and "/worktrees/" not in path
        return (path not in tracked, not in_main, len(path), path)

    by_hash = {}
    for path in files:
        try:
            h = hashlib.sha1()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            size = os.path.getsize(path)
        except OSError:
            continue
        by_hash.setdefault(h.hexdigest(), []).append((rank(path), path, size))
    unique = []
    for digest, items in by_hash.items():
        items.sort()
        unique.append((digest, items[0][1], items[0][2]))
    unique.sort(key=lambda u: u[1])
    return len(files), unique


def load_corpus(out, root, rescan):
    path = os.path.join(out, "corpus.tsv")
    if os.path.exists(path) and not rescan:
        with open(path) as f:
            lines = f.read().splitlines()
        total = int(lines[0].split("\t")[1])
        rows = [l.split("\t") for l in lines[2:] if l]
        return total, [(r[0], r[2], int(r[1])) for r in rows]
    total, unique = scan(root)
    with open(path, "w") as f:
        f.write("files\t%d\n" % total)
        f.write("sha1\tbytes\tpath\n")
        for digest, p, size in unique:
            f.write("%s\t%d\t%s\n" % (digest, size, p))
    return total, unique


# ---------------------------------------------------------------- G-code

E_RE = re.compile(r"E(-?[\d.]+)")


def gcode_facts(path):
    """Return a dict: layers, filament_m, time_s, and the filament (m) of
    each feature type. Only extrusions with an X or Y move count, so the
    retracts and the start G-code do not count."""
    facts = {"layers": "", "filament_m": "", "time_s": ""}
    per = dict.fromkeys(TYPES, 0.0)
    relative, e_last, kind, in_print = False, 0.0, "OTHER", False
    with open(path, "r", errors="replace") as f:
        for line in f:
            if line[0] == ";":
                if line.startswith(";TYPE:"):
                    kind = line[6:].strip()
                    if kind not in per:
                        kind = "OTHER"
                elif line.startswith(";LAYER:"):
                    in_print = True
                elif line.startswith(";LAYER_COUNT:"):
                    facts["layers"] = int(line[13:])
                elif line.startswith(";TIME:"):
                    facts["time_s"] = float(line[6:])
                elif line.startswith(";Estimated time:"):
                    facts["time_s"] = float(line[16:].strip().rstrip("s"))
                elif line.startswith(";Filament used:"):
                    facts["filament_m"] = float(line[15:].strip().rstrip("m"))
                continue
            c = line[:3]
            if c == "M83":
                relative = True
            elif c == "M82":
                relative = False
            elif c == "G92":
                m = E_RE.search(line.split(";")[0])
                if m:
                    e_last = float(m.group(1))
            elif c == "G1 " or c == "G0 ":
                s = line.split(";")[0]
                m = E_RE.search(s)
                if not m:
                    continue
                v = float(m.group(1))
                d = v if relative else v - e_last
                if not relative:
                    e_last = v
                if d > 0 and in_print and ("X" in s or "Y" in s):
                    per[kind] += d
    for t in TYPES:
        facts["fil_" + t.lower().replace("-", "_")] = round(per[t] / 1000, 4)
    return facts


# ---------------------------------------------------------------- slicing

def run_probe(cmd, gcode, timeout, env=None):
    probe = [sys.executable, "-I", "-c", PROBE, str(timeout), str(MEMORY_CAP)] + cmd
    p = subprocess.run(probe, capture_output=True, env=env, timeout=timeout + 60)
    lines = p.stdout.decode("utf-8", "replace").split("\n", 4)
    code, wall, cpu, rss = lines[0], float(lines[1]), float(lines[2]), int(lines[3])
    err = lines[4] if len(lines) > 4 else ""
    if code == "timeout":
        status = "timeout"
    else:
        code = int(code)
        status = "ok" if code == 0 else ("crash" if code < 0 or code >= 128 else "error")
    if status == "ok" and not os.path.exists(gcode):
        status = "error"
    if status in ("error", "crash") and any(t in err for t in OOM_TEXT):
        status = "oom"
    return {"status": status, "wall_s": round(wall, 3), "cpu_s": round(cpu, 3),
            "peak_mb": round(rss / 1024, 1)}, err


def last_error(text, cura):
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if cura:
        bad = [l for l in lines if "[error]" in l or "[critical]" in l]
        lines = bad or lines[-2:]
        lines = [re.sub(r"^\[[^\]]*\] ", "", l) for l in lines]
    return " | ".join(lines[-3:])[:400]


def slice_zslice(ctx, stl, work):
    gcode = os.path.join(work, "z.gcode")
    cmd = [ctx["zslice"], "slice", stl, "-m", ctx["machine"]]
    for kv in ZSLICE_SETTINGS:
        cmd += ["-s", kv]
    cmd += ["-o", gcode]
    r, err = run_probe(cmd, gcode, ctx["timeout"])
    return finish(r, err, gcode, False)


def slice_cura(ctx, stl, work):
    gcode = os.path.join(work, "c.gcode")
    args = []
    for kv in CURA_SETTINGS:
        args += ["-s", kv]
    cmd = [CURA_LOADER, CURA_ENGINE, "slice", "-m1", "-j",
           os.path.join(ctx["defs"], TAZ_MACHINE + ".def.json")]
    cmd += args + ["-e0"] + args + ["-l", stl, "-o", gcode]
    env = dict(os.environ, LD_LIBRARY_PATH=CURA_DIR,
               CURA_ENGINE_SEARCH_PATH=":".join([ctx["defs"], CURA_DEFS, CURA_EXTRUDERS]))
    r, err = run_probe(cmd, gcode, ctx["timeout"], env)
    return finish(r, err, gcode, True)


def finish(r, err, gcode, cura):
    if r["status"] == "ok":
        try:
            r.update(gcode_facts(gcode))
        except (OSError, ValueError) as e:
            r["status"] = "error"
            r["error"] = "G-code read: %s" % e
    if r["status"] == "oom":
        r["error"] = "out of memory at %d GB: %s" % (
            MEMORY_CAP // 1024 ** 3, last_error(err, cura)[:200])
    elif r["status"] != "ok":
        r["error"] = last_error(err, cura) or r["status"]
    elif not cura:
        r["error"] = ""
    else:
        r["error"] = ""
    if os.path.exists(gcode):
        os.unlink(gcode)
    return r


def slice_both(ctx, item):
    digest, path, size = item
    row = {"sha1": digest, "path": path, "bytes": size}
    try:
        row["triangles"] = stl_triangles(path, size)
    except OSError:
        row["triangles"] = ""
    work = tempfile.mkdtemp(prefix="cmp-", dir=ctx["work"])
    try:
        for key, fn in (("z", slice_zslice), ("c", slice_cura)):
            try:
                r = fn(ctx, path, work)
            except Exception as e:  # the probe itself failed
                r = {"status": "crash", "error": "probe: %r" % e}
            for k, v in r.items():
                row["%s_%s" % (key, k)] = v
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return row


def prepare(ctx, out):
    """Copy the TAZ definitions to one folder. The printdeck folder also has
    an older fdmprinter.def.json, so it cannot go on the search path."""
    defs = os.path.join(out, "cura-defs")
    os.makedirs(defs, exist_ok=True)
    for name in (TAZ_MACHINE, TAZ_MACHINE + "_extruder"):
        shutil.copy(os.path.join(TAZ_DEFS, name + ".def.json"), defs)
    ctx["defs"] = defs
    prof = os.path.join(out, "zslice-profiles")
    machine = os.path.join(prof, "machine", "lulzbot-taz-workhorse-se.toml")
    if not os.path.exists(machine):
        subprocess.run([ctx["zslice"], "import", "cura", TAZ_STACK, "-o", prof],
                       check=True, capture_output=True)
    ctx["machine"] = machine


def cmd_run(args):
    zslice, out = os.path.abspath(args[0]), os.path.abspath(args[1])
    opts = {"--root": os.path.expanduser("~/Projects"),
            "--jobs": "2",
            "--timeout": "120", "--limit": "0"}
    rescan = "--rescan" in args
    rest = [a for a in args[2:] if a != "--rescan"]
    for i in range(0, len(rest), 2):
        opts[rest[i]] = rest[i + 1]
    os.makedirs(out, exist_ok=True)
    ctx = {"zslice": zslice, "timeout": float(opts["--timeout"]),
           "work": os.path.join(out, "work")}
    os.makedirs(ctx["work"], exist_ok=True)
    prepare(ctx, out)
    total, corpus = load_corpus(out, os.path.abspath(opts["--root"]), rescan)
    results = os.path.join(out, "results.csv")
    done = set()
    if os.path.exists(results):
        with open(results, newline="") as f:
            done = {r["sha1"] for r in csv.DictReader(f)}
    todo = [c for c in corpus if c[0] not in done]
    # Small files first, so that the results grow fast.
    todo.sort(key=lambda c: c[2])
    if int(opts["--limit"]):
        todo = todo[:int(opts["--limit"])]
    print("files %d, unique %d, done %d, to do %d" % (total, len(corpus), len(done), len(todo)),
          flush=True)
    new = not os.path.exists(results)
    with open(results, "a", newline="") as f:
        w = csv.DictWriter(f, COLUMNS, extrasaction="ignore")
        if new:
            w.writeheader()
        t0 = time.time()
        with concurrent.futures.ThreadPoolExecutor(int(opts["--jobs"])) as ex:
            futures = [ex.submit(slice_both, ctx, c) for c in todo]
            for i, fut in enumerate(concurrent.futures.as_completed(futures), 1):
                row = fut.result()
                w.writerow(row)
                f.flush()
                if i % 50 == 0 or i == len(todo):
                    print("%d/%d  %.0f s" % (i, len(todo), time.time() - t0), flush=True)
    write_summary(out, total, len(corpus))


# ---------------------------------------------------------------- summary

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def ratio(row, key):
    z, c = num(row["z_" + key]), num(row["c_" + key])
    if z is None or c is None or z <= 0 or c <= 0:
        return None
    return z / c


def short(path):
    home = os.path.expanduser("~/Projects/")
    return path[len(home):] if path.startswith(home) else path


def md_table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for r in rows:
        out.append("| " + " | ".join(str(x).replace("|", "/") for x in r) + " |")
    return "\n".join(out)


def write_summary(out, total=None, unique=None):
    with open(os.path.join(out, "results.csv"), newline="") as f:
        rows = list(csv.DictReader(f))
    if total is None:
        corpus = os.path.join(out, "corpus.tsv")
        with open(corpus) as f:
            total = int(f.readline().split("\t")[1])
            unique = sum(1 for _ in f) - 1
    md = ["# zslice and CuraEngine on the STL corpus", ""]
    md.append("Files: %d. Unique files: %d. Sliced: %d." % (total, unique, len(rows)))
    md.append("")
    names = {"z": "zslice", "c": "CuraEngine"}
    head = ["", "ok", "error", "crash", "timeout", "oom", "wall s (sum)", "wall s (median)",
            "CPU s (sum)", "peak MB (median)", "peak MB (max)"]
    table = []
    for s in SLICERS:
        st = [r[s + "_status"] for r in rows]
        ok = [r for r in rows if r[s + "_status"] == "ok"]
        wall = [num(r[s + "_wall_s"]) or 0 for r in rows]
        cpu = [num(r[s + "_cpu_s"]) or 0 for r in rows]
        mem = [num(r[s + "_peak_mb"]) or 0 for r in ok] or [0]
        table.append([names[s]] + [st.count(k) for k in ("ok", "error", "crash", "timeout", "oom")]
                     + ["%.0f" % sum(wall), "%.3f" % statistics.median(wall or [0]),
                        "%.0f" % sum(cpu), "%.1f" % statistics.median(mem), "%.0f" % max(mem)])
    md += [md_table(head, table), ""]
    both = [r for r in rows if r["z_status"] == "ok" and r["c_status"] == "ok"]
    md.append("Both ok: %d files." % len(both))
    if both:
        zw = sum(num(r["z_wall_s"]) for r in both)
        cw = sum(num(r["c_wall_s"]) for r in both)
        md.append("On these files, zslice wall time is %.0f s and CuraEngine wall time "
                  "is %.0f s (ratio %.2f)." % (zw, cw, zw / cw if cw else 0))
        for key, label in (("layers", "layer count"), ("filament_m", "filament"),
                           ("time_s", "time estimate")):
            rs = [x for x in (ratio(r, key) for r in both) if x]
            if rs:
                md.append("Median zslice / Cura ratio of the %s: %.3f." % (label, statistics.median(rs)))
        tz = {t: sum(num(r["z_fil_" + t.lower().replace("-", "_")]) or 0 for r in both) for t in TYPES}
        tc = {t: sum(num(r["c_fil_" + t.lower().replace("-", "_")]) or 0 for r in both) for t in TYPES}
        md += ["", "Filament of each feature type, sum over the files where both are ok (m):", ""]
        md.append(md_table(["type", "zslice", "CuraEngine", "ratio"],
                           [[t, "%.1f" % tz[t], "%.1f" % tc[t],
                             "%.3f" % (tz[t] / tc[t]) if tc[t] else "-"] for t in TYPES]))
    md.append("")

    for s in SLICERS:
        bad = [r for r in rows if r[s + "_status"] != "ok"]
        md += ["## %s failures (%d)" % (names[s], len(bad)), ""]
        groups = {}
        for r in bad:
            key = (r[s + "_status"], re.sub(r"\d+(\.\d+)?", "N", r[s + "_error"] or "")[:120])
            groups.setdefault(key, []).append(r)
        for (status, msg), rs in sorted(groups.items(), key=lambda g: -len(g[1])):
            md.append("- %s, %d files: `%s`. Example: `%s` (%s triangles)." % (
                status, len(rs), (rs[0][s + "_error"] or "")[:200].replace("`", "'"),
                short(rs[0]["path"]), rs[0]["triangles"]))
        md.append("")

    for s in SLICERS:
        ok = [r for r in rows if r[s + "_status"] == "ok"]
        md += ["## %s: slowest" % names[s], ""]
        top = sorted(ok, key=lambda r: -num(r[s + "_wall_s"]))[:15]
        md.append(md_table(["file", "triangles", "wall s", "other wall s", "peak MB"],
                           [[short(r["path"]), r["triangles"], r[s + "_wall_s"],
                             r[("c" if s == "z" else "z") + "_wall_s"], r[s + "_peak_mb"]] for r in top]))
        md += ["", "## %s: most memory" % names[s], ""]
        top = sorted(ok, key=lambda r: -num(r[s + "_peak_mb"]))[:15]
        md.append(md_table(["file", "triangles", "peak MB", "other peak MB", "wall s"],
                           [[short(r["path"]), r["triangles"], r[s + "_peak_mb"],
                             r[("c" if s == "z" else "z") + "_peak_mb"], r[s + "_wall_s"]] for r in top]))
        md.append("")

    md += ["## zslice much slower than CuraEngine", ""]
    slow = [r for r in both if num(r["c_wall_s"]) > 0 and num(r["z_wall_s"]) > 1]
    slow.sort(key=lambda r: -num(r["z_wall_s"]) / num(r["c_wall_s"]))
    md.append(md_table(["file", "triangles", "zslice s", "Cura s", "ratio"],
                       [[short(r["path"]), r["triangles"], r["z_wall_s"], r["c_wall_s"],
                         "%.1f" % (num(r["z_wall_s"]) / num(r["c_wall_s"]))] for r in slow[:15]]))
    md.append("")

    for key, label in (("layers", "layer count"), ("filament_m", "filament"),
                       ("time_s", "time estimate")):
        md += ["## Largest differences: %s" % label, ""]
        rs = [(ratio(r, key), r) for r in both]
        rs = [x for x in rs if x[0]]
        rs.sort(key=lambda x: -abs(math.log(x[0])))
        md.append(md_table(["file", "triangles", "zslice", "Cura", "ratio"],
                           [[short(r["path"]), r["triangles"], r["z_" + key], r["c_" + key],
                             "%.3f" % x] for x, r in rs[:15]]))
        md.append("")
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write("\n".join(md))
    print("wrote", os.path.join(out, "summary.md"))


# ---------------------------------------------------------------- check

def read_stl(path):
    data = open(path, "rb").read()
    if len(data) >= 84:
        n = struct.unpack("<I", data[80:84])[0]
        if 84 + 50 * n == len(data):
            tris = []
            for i in range(n):
                v = struct.unpack_from("<9f", data, 84 + 50 * i + 12)
                tris.append((v[0:3], v[3:6], v[6:9]))
            return tris
    nums = re.findall(rb"vertex\s+(\S+)\s+(\S+)\s+(\S+)", data)
    pts = [tuple(float(x) for x in p) for p in nums]
    return [tuple(pts[i:i + 3]) for i in range(0, len(pts) - 2, 3)]


def check(path):
    tris = read_stl(path)
    ids, edges = {}, {}
    degenerate = 0
    lo = [math.inf] * 3
    hi = [-math.inf] * 3
    faces = []
    for t in tris:
        f = []
        for p in t:
            for k in range(3):
                lo[k] = min(lo[k], p[k])
                hi[k] = max(hi[k], p[k])
            f.append(ids.setdefault(p, len(ids)))
        if len(set(f)) < 3:
            degenerate += 1
            continue
        faces.append(f)
        for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
            edges.setdefault((min(a, b), max(a, b)), []).append((a, b, len(faces) - 1))
    open_e = sum(1 for e in edges.values() if len(e) == 1)
    nonman = sum(1 for e in edges.values() if len(e) > 2)
    flipped = sum(1 for e in edges.values() if len(e) == 2 and e[0][0] == e[1][0])
    parent = list(range(len(faces)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for e in edges.values():
        for _, _, fi in e[1:]:
            a, b = find(e[0][2]), find(fi)
            if a != b:
                parent[a] = b
    parts = len({find(i) for i in range(len(faces))})
    size = [hi[k] - lo[k] for k in range(3)] if tris else [0, 0, 0]
    print("%s\n  triangles %d, vertices %d, size %.2f x %.2f x %.2f mm, min z %.2f\n"
          "  degenerate %d, open edges %d, non-manifold edges %d, flipped edges %d, parts %d"
          % (path, len(tris), len(ids), size[0], size[1], size[2], lo[2] if tris else 0,
             degenerate, open_e, nonman, flipped, parts))


# The Arachne settings of zslice that match the Cura settings above.
ZSLICE_ARACHNE = [
    "project.wall_generator=arachne",
    "project.line_width=0.5",
    "project.min_wall_line_width=0.425",
    "project.min_feature_size=0.125",
    "project.min_bead_width=0.425",
    "project.wall_transition_length=0.5",
]

NUM_RE = re.compile(r"([XYZE])(-?\d+\.?\d*)")


def wall_moves(path, cura):
    """The wall paths of each layer of a G-code file: for each layer, a list
    of paths, each a list of (length, width, volume) moves."""
    area_f = math.pi * (2.85 / 2) ** 2
    layers = {}
    kind, layer, cur = None, -1, None
    x = y = 0.0
    e_last, relative = 0.0, False
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith(";LAYER:"):
                layer = int(line[7:])
                layers[layer] = []
                cur = None
            elif line.startswith(";TYPE:"):
                kind = line[6:].strip()
                cur = None
            if line[0] == ";":
                continue
            s = line.split(";")[0]
            if s.startswith("M83"):
                relative = True
            elif s.startswith("M82"):
                relative = False
            elif s.startswith("G92"):
                m = E_RE.search(s)
                if m:
                    e_last = float(m.group(1))
            if not (s.startswith("G0") or s.startswith("G1")):
                continue
            v = dict((k, float(n)) for k, n in NUM_RE.findall(s))
            nx, ny = v.get("X", x), v.get("Y", y)
            de = 0.0
            if "E" in v:
                de = v["E"] if relative else v["E"] - e_last
                if not relative:
                    e_last = v["E"]
            d = math.hypot(nx - x, ny - y)
            if de > 0 and d > 1e-4 and layer >= 0 and kind in ("WALL-OUTER", "WALL-INNER"):
                h = 0.3 if layer == 0 else 0.2
                area = de * area_f / d
                if cura:
                    w = area / h
                else:
                    rnd = math.pi * h * h / 4
                    w = 2 * math.sqrt(area / math.pi) if area <= rnd else (area - rnd) / h + h
                if cur is None:
                    cur = []
                    layers[layer].append(cur)
                cur.append((d, w, area * d))
            else:
                cur = None
            x, y = nx, ny
    return layers


def cmd_walls(argv):
    zslice, stl, out = os.path.abspath(argv[0]), os.path.abspath(argv[1]), os.path.abspath(argv[2])
    os.makedirs(out, exist_ok=True)
    ctx = {"zslice": zslice, "timeout": 600}
    prepare(ctx, out)
    runs = {}
    for name, extra in (("zslice classic", ["project.line_width=0.5"]), ("zslice arachne", ZSLICE_ARACHNE)):
        gcode = os.path.join(out, name.replace(" ", "-") + ".gcode")
        cmd = [zslice, "slice", stl, "-m", ctx["machine"]]
        for kv in ZSLICE_SETTINGS + extra:
            cmd += ["-s", kv]
        subprocess.run(cmd + ["-o", gcode], check=True, capture_output=True)
        runs[name] = wall_moves(gcode, False)
    gcode = os.path.join(out, "cura.gcode")
    args = []
    for kv in CURA_SETTINGS:
        args += ["-s", kv]
    cmd = [CURA_LOADER, CURA_ENGINE, "slice", "-m1", "-j",
           os.path.join(ctx["defs"], TAZ_MACHINE + ".def.json")]
    cmd += args + ["-e0"] + args + ["-l", stl, "-o", gcode]
    env = dict(os.environ, LD_LIBRARY_PATH=CURA_DIR,
               CURA_ENGINE_SEARCH_PATH=":".join([ctx["defs"], CURA_DEFS, CURA_EXTRUDERS]))
    subprocess.run(cmd, check=True, capture_output=True, env=env)
    runs["CuraEngine"] = wall_moves(gcode, True)

    print("| slicer | wall paths | wall volume (mm3) | wall length (mm) |")
    print("|---|---|---|---|")
    hists = {}
    for name, layers in runs.items():
        moves = [m for paths in layers.values() for p in paths for m in p]
        paths = sum(len(v) for v in layers.values())
        length = sum(m[0] for m in moves)
        hist = {}
        for d, w, _ in moves:
            b = min(int(w / 0.05), 30)
            hist[b] = hist.get(b, 0) + d
        hists[name] = (hist, length)
        print("| %s | %d | %.1f | %.0f |" % (name, paths, sum(m[2] for m in moves), length))
    print()
    print("| width (mm) | " + " | ".join(runs) + " |")
    print("|---|" + "---|" * len(runs))
    for b in range(31):
        row = [h.get(b, 0) / max(length, 1e-9) * 100 for h, length in hists.values()]
        if max(row) >= 0.5:
            print("| %.2f to %.2f | %s |" % (b * 0.05, (b + 1) * 0.05, " | ".join("%.1f %%" % r for r in row)))
    za, cu = runs["zslice arachne"], runs["CuraEngine"]
    same = sum(1 for i in cu if len(za.get(i, [])) == len(cu[i]))
    print()
    print("Layers with the same number of wall paths in zslice arachne and CuraEngine: %d of %d" % (same, len(cu)))


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "walls":
        cmd_walls(sys.argv[2:])
    elif len(sys.argv) >= 4 and sys.argv[1] == "run":
        cmd_run(sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == "summary":
        write_summary(os.path.abspath(sys.argv[2]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "check":
        for p in sys.argv[2:]:
            check(p)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
