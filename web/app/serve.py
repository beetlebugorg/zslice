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
        # workers, so the slice has threads (zslice-mt.wasm). With
        # "credentialless", the camera of a printer on another origin (an
        # <img> with no CORS) loads with no cookies; "require-corp" blocks
        # it unless the printer sends Cross-Origin-Resource-Policy.
        if not self.server.no_isolation:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", self.server.coep)
        # --csp: the security headers that the host of the app sends (see
        # README.md), to test the app against them.
        if self.server.csp:
            for k, v in SECURITY_HEADERS.items():
                self.send_header(k, v)
        super().end_headers()


# The security headers of the hosted app. The policy lets the page load
# its own files and wasm (wasm-unsafe-eval), and reach printers on any
# http or https address (fetch and camera pictures). No other site can
# frame the page, and no address goes out in a Referer.
CSP = "; ".join([
    "default-src 'self'",
    "script-src 'self' 'wasm-unsafe-eval'",
    "worker-src 'self'",
    "style-src 'self'",
    "img-src 'self' data: blob: http: https:",
    "media-src 'self' blob:",
    "connect-src 'self' http: https:",
    "font-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
])
SECURITY_HEADERS = {
    "Content-Security-Policy": CSP,
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
}


def main():
    p = argparse.ArgumentParser(description="Serve the zslice web app.")
    p.add_argument("folder", nargs="?", default="zig-out/web/app")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--no-isolation", action="store_true", help="send no COOP and COEP headers: the slice has no threads")
    p.add_argument("--cache", action="store_true", help="let the browser keep the files for a day (and its optimized wasm code)")
    p.add_argument("--coep", default="credentialless", choices=["credentialless", "require-corp"],
                   help="the Cross-Origin-Embedder-Policy (credentialless lets the cameras of printers load)")
    p.add_argument("--csp", action="store_true", help="send the security headers of the host (Content-Security-Policy and others)")
    a = p.parse_args()
    folder = os.path.abspath(a.folder)
    handler = functools.partial(Handler, directory=folder)
    with http.server.ThreadingHTTPServer((a.bind, a.port), handler) as httpd:
        httpd.no_isolation = a.no_isolation
        httpd.cache = a.cache
        httpd.coep = a.coep
        httpd.csp = a.csp
        print(f"zslice: serving {folder} at http://{a.bind}:{a.port}/", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
