# Two local servers for the redirect test of the API key of the macOS app
# (KeyRedirect in macos/Sources/ZSlice/Core/PrinterLink.swift). A, the
# printer on port PA, sends 302 for /api/printer and for its camera snapshot
# to B on port PB (another origin), and for /api/job to /api/job2 on A
# itself. Each server logs each request, and whether the X-Api-Key header
# came with it. B must never get the key; /api/job2 on A must get it.
#
#   python3 -I macos/tools/key_redirect.py 18601 18602 log.txt
#
# The app reads the printer from a fleet file with a key:
#
#   {"printers": [{"name": "Redirector", "kind": "octoprint",
#                  "url": "http://127.0.0.1:18601", "key": "SECRETKEY"}]}
#
#   ZSLICE_FRESH=1 ZSLICE_FLEET=fleet.json ZSLICE_PAGE=printers zslice
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import http.server, json, sys, threading
PA, PB, logf = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
log = open(logf, "a", buffering=1)
def handler(name):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def j(self, o):
            b = json.dumps(o).encode(); self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        def go(self, url):
            self.send_response(302); self.send_header("Location", url); self.send_header("Content-Length", "0"); self.end_headers()
        def do_GET(self):
            key = self.headers.get("X-Api-Key")
            log.write("%s %s key %s\n" % (name, self.path, key or "-"))
            p = self.path
            if name == "A":
                if p.startswith("/api/printer") and not p.startswith("/api/printerprofiles"): return self.go("http://127.0.0.1:%d/api/printer" % PB)
                if p.startswith("/api/job2"): return self.j({"job": {"file": {"name": "x.gcode"}}, "progress": {"completion": 10}, "state": "Printing"})
                if p.startswith("/api/job"): return self.go("/api/job2")
                if p.startswith("/api/settings"): return self.j({"webcam": {"webcamEnabled": True, "streamUrl": "", "snapshotUrl": "/snap"}})
                if p.startswith("/snap"): return self.go("http://127.0.0.1:%d/snap" % PB)
                return self.j({})
            return self.j({"state": {"text": "Operational"}})
    return H
for n, port in (("B", PB),):
    threading.Thread(target=http.server.ThreadingHTTPServer(("127.0.0.1", port), handler(n)).serve_forever, daemon=True).start()
http.server.ThreadingHTTPServer(("127.0.0.1", PA), handler("A")).serve_forever()
