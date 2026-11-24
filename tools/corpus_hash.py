#!/usr/bin/env python3
"""Write the hash of the G-code of each STL file of a folder tree.

Usage: python3 -I tools/corpus_hash.py <zslice binary> <folder> <out.tsv> [jobs] [group.name=value ...]

A change that must keep the G-code compares the table of the build before
it with the table of the build after it. `diff` of the two tables must
print nothing.

Each file is sliced as tools/corpus.py slices it: the same bed size and
height, and engine.threads=2. The settings after the job count go to each
slice. The table has one line for each file, sorted by path: the path from
the folder, the status ("ok", "timeout", or the exit code), and the first
16 hex digits of the SHA-256 of the G-code.

The hash covers all bytes of the G-code. Two runs of one binary give the
same G-code: the header has no clock time and no version line.

In a git repo, the script uses only the files that git tracks. The
function `list_files` is a copy of the one of tools/corpus.py: `python3 -I`
does not put the folder of this script on the import path.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import concurrent.futures
import hashlib
import os
import subprocess
import sys
import tempfile

TIMEOUT_S = 120

EXTRA = []


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


def hash_one(binary, folder, path, tmp):
    out = os.path.join(tmp, hashlib.sha256(path.encode()).hexdigest()[:20] + ".gcode")
    cmd = [
        binary, "slice", path, "-o", out,
        "-s", "machine.max_height=2000", "-s", "machine.bed_size_x=2000",
        "-s", "machine.bed_size_y=2000", "-s", "engine.threads=2",
    ]
    for kv in EXTRA:
        cmd += ["-s", kv]
    rel = os.path.relpath(path, folder)
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return (rel, "timeout", "")
    if p.returncode != 0:
        return (rel, "exit %d" % p.returncode, "")
    h = hashlib.sha256()
    with open(out, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    os.remove(out)
    return (rel, "ok", h.hexdigest()[:16])


def main():
    binary, folder, report = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
    jobs = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    EXTRA.extend(sys.argv[5:])
    files = list_files(folder)
    with tempfile.TemporaryDirectory() as tmp:
        with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
            results = list(ex.map(lambda f: hash_one(binary, folder, f, tmp), files))
    results.sort()
    with open(report, "w") as out:
        for r in results:
            out.write("%s\t%s\t%s\n" % r)
    ok = sum(1 for r in results if r[1] == "ok")
    print("files: %d, ok: %d" % (len(results), ok))


if __name__ == "__main__":
    main()
