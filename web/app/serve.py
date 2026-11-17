#!/usr/bin/env python3
# A small dev server for the web app. It serves a folder (by default
# zig-out/web/app) with the right MIME types: application/wasm for .wasm
# and text/javascript for .js, so the browser compiles the module while it
# loads. It sends no cache headers, so a reload gets the new build.
#
# Run: python3 web/app/serve.py [folder] [--port 8000]
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
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main():
    p = argparse.ArgumentParser(description="Serve the zslice web app.")
    p.add_argument("folder", nargs="?", default="zig-out/web/app")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--bind", default="127.0.0.1")
    a = p.parse_args()
    folder = os.path.abspath(a.folder)
    handler = functools.partial(Handler, directory=folder)
    with http.server.ThreadingHTTPServer((a.bind, a.port), handler) as httpd:
        print(f"zslice: serving {folder} at http://{a.bind}:{a.port}/", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
