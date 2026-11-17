#!/usr/bin/env python3
# A small dev server for the web app. It serves a folder (by default
# zig-out/web/app) with the right MIME types: application/wasm for .wasm
# and text/javascript for .js, so the browser compiles the module while it
# loads. It tells the browser to keep no file, so a reload gets the new
# build. With --cache, the browser keeps each file for a day, as a host for
# users does: Chromium then also keeps its optimized code of the wasm
# module, and the first slice of a later visit is fast (see README.md).
#
# Run: python3 web/app/serve.py [folder] [--port 8000] [--cache]
#
# SPDX-License-Identifier: AGPL-3.0-or-later

import argparse
import functools
import http.server
import os


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".css": "text/css",
        ".html": "text/html",
        ".stl": "model/stl",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "public, max-age=86400" if self.server.cache else "no-store")
        # Cross-origin isolation: the page can share wasm memory with its
        # workers, so the slice has threads (zslice-mt.wasm).
        if not self.server.no_isolation:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


def main():
    p = argparse.ArgumentParser(description="Serve the zslice web app.")
    p.add_argument("folder", nargs="?", default="zig-out/web/app")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--no-isolation", action="store_true", help="send no COOP and COEP headers: the slice has no threads")
    p.add_argument("--cache", action="store_true", help="let the browser keep the files for a day (and its optimized wasm code)")
    a = p.parse_args()
    folder = os.path.abspath(a.folder)
    handler = functools.partial(Handler, directory=folder)
    with http.server.ThreadingHTTPServer((a.bind, a.port), handler) as httpd:
        httpd.no_isolation = a.no_isolation
        httpd.cache = a.cache
        print(f"zslice: serving {folder} at http://{a.bind}:{a.port}/", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
