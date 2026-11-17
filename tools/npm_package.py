"""Builds the npm package @beetlebugorg/zslice in zig-out/npm.

Run after `zig build web`:

    python3 -I tools/npm_package.py [version]

The version defaults to the version of web/npm/package.json. The package
is the web app (zig-out/web/app, without the test files), the JavaScript
API (web/zslice.mjs), the Node command (web/npm/bin), the README, and the
license. Publish it with `npm publish zig-out/npm` (the registry is GitHub
Packages: publishConfig in package.json).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "zig-out" / "web" / "app"
OUT = ROOT / "zig-out" / "npm"
# Files of the app folder that are for tests or local use only.
SKIP = {"serve.py", "test-node.mjs", "README.md"}


def main():
    if not (APP / "zslice.wasm").exists():
        sys.exit("npm_package: run zig build web first")
    pkg = json.loads((ROOT / "web" / "npm" / "package.json").read_text())
    if len(sys.argv) > 1:
        pkg["version"] = sys.argv[1].removeprefix("v")
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "app").mkdir(parents=True)
    for f in APP.iterdir():
        if f.name in SKIP or f.suffix.lower() in (".stl", ".3mf"):
            continue
        if f.is_dir():
            shutil.copytree(f, OUT / "app" / f.name)
        else:
            shutil.copy2(f, OUT / "app" / f.name)
    shutil.copytree(ROOT / "web" / "npm" / "bin", OUT / "bin")
    shutil.copy2(ROOT / "web" / "zslice.mjs", OUT / "zslice.mjs")
    shutil.copy2(ROOT / "web" / "npm" / "README.md", OUT / "README.md")
    shutil.copy2(ROOT / "LICENSE", OUT / "LICENSE")
    (OUT / "package.json").write_text(json.dumps(pkg, indent=2) + "\n")
    size = sum(p.stat().st_size for p in OUT.rglob("*") if p.is_file())
    print(f"npm_package: {pkg['name']}@{pkg['version']} in {OUT} ({size / 1e6:.1f} MB)")


main()
