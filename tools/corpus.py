#!/usr/bin/env python3
"""Slice each STL file in a folder tree and report the failures.

In a git repo, the script uses only the files that git tracks.

Usage: python3 -I tools/corpus.py <zslice binary> <folder> <report.tsv> [jobs] [group.name=value ...]

The settings after the job count go to each slice, for example
project.support=everywhere.

Each file is sliced in its own process with a time limit. The report has one
line for each file: status, seconds, peak memory (MB), triangles, layers, the
file, and the error text.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import concurrent.futures
import os
import resource
import subprocess
import sys
import time

TIMEOUT_S = 120


EXTRA = []


def slice_one(binary, path):
    triangles = max(0, (os.path.getsize(path) - 84) // 50)
    # The child measures its own peak memory, because RUSAGE_CHILDREN in a
    # thread pool adds up the children of all threads.
    probe = (
        "import resource,subprocess,sys\n"
        "p=subprocess.run(sys.argv[1:],capture_output=True,text=True,timeout=%d)\n"
        "sys.stdout.write('%%d\\n' %% p.returncode)\n"
        "sys.stdout.write('%%d\\n' %% resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)\n"
        "sys.stdout.write(p.stderr.replace('\\n',' ').strip())\n" % TIMEOUT_S
    )
    cmd = [
        sys.executable, "-I", "-c", probe, binary, "slice", path, "-o", os.devnull,
        "-s", "machine.max_height=2000", "-s", "machine.bed_size_x=2000",
        "-s", "machine.bed_size_y=2000", "-s", "engine.threads=2",
    ]
    for kv in EXTRA:
        cmd += ["-s", kv]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S + 10)
        lines = p.stdout.split("\n", 2)
        code = int(lines[0])
        rss_mb = int(lines[1]) / 1024
        msg = lines[2] if len(lines) > 2 else ""
    except subprocess.TimeoutExpired:
        return ("timeout", time.time() - t0, 0, triangles, 0, path, "")
    except (ValueError, IndexError):
        return ("crash", time.time() - t0, 0, triangles, 0, path, p.stderr.strip()[:300])
    dt = time.time() - t0
    layers = 0
    if code == 0 and " layers," in msg:
        layers = int(msg.split(" layers,")[0])
    if code == 0:
        status = "ok"
    elif code < 0 or code >= 128:
        status = "crash"
    else:
        status = "error"
    return (status, dt, rss_mb, triangles, layers, path, msg[:300])


def list_files(folder):
    """The STL files in folder. In a git repo, only the files that git
    tracks: build output and work trees are not part of the corpus."""
    p = subprocess.run(["git", "-C", folder, "ls-files", "-z", "*.stl", "*.STL"],
                       capture_output=True)
    if p.returncode == 0:
        return sorted(os.path.join(folder, f) for f in p.stdout.decode().split("\0") if f)
    files = []
    for root, dirs, names in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", ".zig-cache")]
        files += [os.path.join(root, n) for n in names if n.lower().endswith(".stl")]
    return sorted(files)


def main():
    binary, folder, report = sys.argv[1], sys.argv[2], sys.argv[3]
    jobs = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    EXTRA.extend(sys.argv[5:])
    files = list_files(folder)
    results = []
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for r in ex.map(lambda f: slice_one(binary, f), files):
            results.append(r)
    with open(report, "w") as out:
        out.write("status\tseconds\tpeak_mb\ttriangles\tlayers\tfile\tmessage\n")
        for r in results:
            out.write("%s\t%.2f\t%.1f\t%d\t%d\t%s\t%s\n" % r)
    counts = {}
    for r in results:
        counts[r[0]] = counts.get(r[0], 0) + 1
    print("files:", len(results), counts)
    ok = [r for r in results if r[0] == "ok"]
    if ok:
        print("slowest: %.2f s (%s)" % max((r[1], r[5]) for r in ok))
        print("largest memory: %.1f MB (%s)" % max((r[2], r[5]) for r in ok))


if __name__ == "__main__":
    main()
