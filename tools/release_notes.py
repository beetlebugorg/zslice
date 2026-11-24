#!/usr/bin/env python3
# Writes the release notes of a tag in Markdown: a short header, and the
# subject of each commit since the tag before it, in groups.
#
# Usage: python3 -I tools/release_notes.py <tag> [<previous tag>]
#
# The group of a commit comes from the paths that it changes:
#   - src/, include/, build.zig, vendor/: "Slicer core".
#   - else one app folder (web/, linux/, macos/, windows/): that app.
#   - else only docs and Markdown files: "Documentation".
#   - else: "Build and tools".
# A merge commit is not listed, and a commit that changes only prompt/ or
# the built doc pages (docs/**/*.html) is not listed. The release workflow
# runs this script.
# SPDX-License-Identifier: AGPL-3.0-or-later
import subprocess
import sys

GROUPS = [
    ("core", "Slicer core"),
    ("web", "Web app"),
    ("macos", "Mac app"),
    ("linux", "Linux app"),
    ("windows", "Windows app"),
    ("docs", "Documentation"),
    ("build", "Build and tools"),
]
APPS = {"web/": "web", "linux/": "linux", "macos/": "macos", "windows/": "windows"}
CORE = ("src/", "include/", "build.zig", "vendor/")
FOLD = 40


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def previous_tag(tag):
    r = subprocess.run(["git", "describe", "--tags", "--abbrev=0", "--match", "v*", f"{tag}^"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def housekeeping(paths):
    """True for a commit with no change that a reader of the notes needs."""
    return bool(paths) and all(p.startswith("prompt/") or (p.startswith("docs/") and p.endswith(".html")) for p in paths)


def group_of(paths):
    if any(p.startswith(CORE) for p in paths):
        return "core"
    apps = {a for p in paths for prefix, a in APPS.items() if p.startswith(prefix)}
    if len(apps) == 1:
        return apps.pop()
    if apps:
        return "core"
    if paths and all(p.startswith("docs/") or p.endswith(".md") for p in paths):
        return "docs"
    return "build"


def main():
    tag = sys.argv[1]
    prev = sys.argv[2] if len(sys.argv) > 2 else previous_tag(tag)
    span = f"{prev}..{tag}" if prev else tag
    # One record for each commit: the hash and the subject on one line,
    # then the changed paths. \x1e starts a record.
    log = git("log", "--no-merges", "--reverse", "--name-only", "--format=%x1e%h %s", span)
    groups = {key: [] for key, _ in GROUPS}
    for record in log.split("\x1e")[1:]:
        lines = [x for x in record.splitlines() if x.strip()]
        head, paths = lines[0], lines[1:]
        if housekeeping(paths):
            continue
        short, subject = head.split(" ", 1)
        groups[group_of(paths)].append(f"- {subject} ({short})")

    version = tag.removeprefix("v")
    count = sum(len(v) for v in groups.values())
    out = [f"zslice {version}.", ""]
    if "-" in version:
        out += ["zslice is experimental. Check each print in the view before you send it to a printer.", ""]
    out += ["Install with Homebrew:", "", "```sh", "brew tap beetlebugorg/tap",
            "brew install --cask zslice   # the Mac app", "brew install zslice          # the command line tool",
            "```", "",
            "Or download a file below. SHA256SUMS has the SHA-256 of each file.", ""]
    if prev:
        out += [f"{count} changes since {prev}.", ""]
    for key, title in GROUPS:
        items = groups[key]
        if not items:
            continue
        out += [f"## {title}", ""]
        # A long group is folded, so the page stays short.
        if len(items) > FOLD:
            out += [f"<details><summary>{len(items)} changes</summary>", ""] + items + ["", "</details>", ""]
        else:
            out += items + [""]
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
