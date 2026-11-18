#!/usr/bin/env python3
# farm_sim.py: a simulated print farm, for the tests of the zslice apps.
#
# It runs N printers in one process, each an HTTP server on its own port of
# 127.0.0.1, that answer as the real printers do:
#
# - printdeck (most of the farm): the OctoPrint API that printdeck serves
#   (/api/version, /api/printer, /api/job, /api/files/local) and its own
#   /api/plugin/printdeck (the roll, the limits, and the job);
# - OctoPrint: /api/printer, /api/printerprofiles, /api/job, the upload;
# - Moonraker (Klipper): /server/info, /printer/objects/query,
#   /server/files/upload;
# - resin printers: printdeck with the material "Resin" and no roll.
#
# Each printer has a model (a brand, a bed, a speed), and a state machine:
# Operational, Heating, Printing, then Finished: the print waits on the bed
# until a person clears it. A print can fail (a clog, a spaghetti, a lost
# layer), and can pause (the filament ran out) until it resumes. The clock
# runs fast: --speed 60 prints an hour in a minute.
#
# A printdeck never starts a print by itself (a firm rule of printdeck): an
# upload goes into its queue (GET /api/plugin/printdeck/queue, DELETE and
# move of an item), and a person at the deck presses Print. OctoPrint and
# Moonraker start a print of an upload with print=true, as the real ones
# do; the app asks the user first if the bed is clear.
#
# The operator (on by default, --no-operator): the people of the farm. 5 to
# 45 minutes after a print ends or fails, they take it off the bed; 5 to 45
# minutes after a printdeck has a queue and a clear bed, they press Print.
#
# The control API (--control, 127.0.0.1:8800):
#   GET  /farm               all printers and their states (JSON)
#   GET  /orders             the orders that came in
#   POST /farm/<id>/clear    a person takes the print off the bed
#   POST /farm/<id>/press    a person presses Print on the deck (printdeck)
#   POST /farm/<id>/fail     fail the print now
#   POST /farm/<id>/pause    pause the print (filament out); /resume
#   POST /farm/speed?x=120   the speed of the clock
# It also writes fleet.json: the printers, for an app to add them (the
# macOS app reads it with ZSLICE_FLEET=path).
#
# Orders come in at random (--order-every seconds of the farm clock): a
# model from ../printdeck and a count, for the apps to plan.
#
# Usage: python3 -I tools/farm_sim/farm_sim.py --printers 50 --speed 60
#
# See REFERENCES.md: the OctoPrint, Moonraker, and printdeck APIs.
#
# SPDX-License-Identifier: AGPL-3.0-or-later

import argparse
import json
import os
import random
import re
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The models of the farm: brand and name, the kind of API, the bed (mm),
# the nozzle, the speed of the printer against the plan (1.0: as planned),
# and the share of the farm.
MODELS = [
    ("Prusa", "MK4", "printdeck", (250, 210, 220), 0.4, 1.10, 8),
    ("Prusa", "CORE One", "printdeck", (250, 220, 270), 0.4, 1.25, 6),
    ("Prusa", "MINI", "printdeck", (180, 180, 180), 0.4, 0.95, 4),
    ("LulzBot", "TAZ Workhorse", "printdeck", (280, 280, 285), 0.5, 0.85, 6),
    ("Creality", "K1", "moonraker", (220, 220, 250), 0.4, 1.40, 5),
    ("Creality", "Ender-3 V3", "moonraker", (220, 220, 250), 0.4, 1.20, 5),
    ("Voron", "2.4 350", "moonraker", (350, 350, 340), 0.4, 1.50, 3),
    ("Elegoo", "Neptune 4", "moonraker", (225, 225, 265), 0.4, 1.15, 3),
    ("Sovol", "SV06", "octoprint", (220, 220, 250), 0.4, 0.90, 3),
    ("Anycubic", "Kobra 3", "octoprint", (250, 250, 260), 0.4, 1.00, 2),
    ("Elegoo", "Saturn 4 Ultra", "resin", (218, 123, 220), 0.0, 1.00, 3),
    ("Anycubic", "Photon Mono M7", "resin", (223, 126, 230), 0.0, 1.00, 2),
]
MATERIALS = [("PLA", "Galaxy Black", "#1b1b1b"), ("PLA", "Signal White", "#f2f2f2"), ("PETG", "Ocean Blue", "#1d4ea8"),
             ("PETG", "Clear", "#d8e8f0"), ("ASA", "Racing Red", "#c8102e"), ("TPU", "Matte Green", "#3d8b3d")]
FAILURES = ["Nozzle clog: no plastic for 30 s", "Spaghetti: the print came off the bed",
            "Layer shift on X", "Thermal runaway on the hotend", "The part came off the bed"]

LOCK = threading.Lock()


class Server(ThreadingHTTPServer):
    """An HTTP server with no reverse DNS lookup at bind time (getfqdn can
    wait seconds on mDNS for each of the 50 servers)."""

    daemon_threads = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


class Clock:
    """The farm clock: real seconds times the speed."""

    def __init__(self, speed):
        self.speed = speed
        self.t0 = time.time()
        self.base = 0.0

    def now(self):
        return self.base + (time.time() - self.t0) * self.speed

    def set_speed(self, speed):
        self.base = self.now()
        self.t0 = time.time()
        self.speed = speed


class Printer:
    def __init__(self, i, model, port, rng):
        brand, name, kind, bed, nozzle, pace, _ = model
        self.id = i
        self.brand, self.model, self.kind = brand, name, kind
        self.name = f"{name} {i + 1:02d}"
        self.port = port
        self.bed, self.nozzle, self.pace = bed, nozzle, pace
        self.resin = kind == "resin"
        mat = ("Resin", "Standard Grey", "#808080") if self.resin else rng.choice(MATERIALS)
        self.material, self.roll, self.color = mat
        self.roll_left = 0 if self.resin else rng.uniform(80, 1000)
        self.state = "Operational"
        self.job = None  # {name, total, start, heat, fail_at, fail, paused_at, paused_for}
        self.done_job = None
        self.reason = ""
        self.offline = rng.random() < 0.04  # a few never answer, as in a real farm
        self.prints = 0
        # printdeck: the files that wait for a press on the deck.
        self.queue = []
        self.next_id = 1
        # The farm time when the operator acts on this printer next.
        self.operator_at = None

    @property
    def deck(self):
        return self.kind in ("printdeck", "resin")

    # ---- the state machine ----

    def start(self, name, plan_s, clock, rng, fail_rate):
        heat = 30 if self.resin else rng.uniform(90, 240)
        total = max(60.0, plan_s / self.pace)
        fail_at = rng.uniform(0.02, 0.9) if rng.random() < fail_rate else None
        self.job = {"name": name, "total": total, "start": clock.now(), "heat": heat, "fail_at": fail_at,
                    "paused_at": None, "paused_for": 0.0}
        self.done_job = None
        self.reason = ""
        self.state = "Heating"

    def progress(self, clock):
        j = self.job
        if not j:
            return 1.0 if self.state == "Finished" else 0.0
        t = (j["paused_at"] if j["paused_at"] is not None else clock.now()) - j["start"] - j["heat"] - j["paused_for"]
        return min(max(t / j["total"], 0.0), 1.0)

    def time_left(self, clock):
        j = self.job
        if not j:
            return 0
        return max(0.0, j["total"] * (1 - self.progress(clock)))

    def tick(self, clock, rng, pause_rate):
        j = self.job
        if not j or j["paused_at"] is not None:
            return None
        if self.state == "Heating" and clock.now() - j["start"] >= j["heat"]:
            self.state = "Printing"
            return "printing"
        if self.state != "Printing":
            return None
        p = self.progress(clock)
        if j["fail_at"] is not None and p >= j["fail_at"]:
            self.state = "Error"
            self.reason = rng.choice(FAILURES)
            self.done_job = dict(j, progress=p)
            self.job = None
            return "failed"
        # A rare runout pause (not resin).
        if not self.resin and rng.random() < pause_rate:
            j["paused_at"] = clock.now()
            self.state = "Paused"
            self.reason = "Filament runout: load a new roll and resume"
            return "paused"
        if p >= 1.0:
            self.state = "Finished"
            self.done_job = dict(j, progress=1.0)
            self.job = None
            self.prints += 1
            return "finished"
        return None

    def resume(self, clock):
        j = self.job
        if j and j["paused_at"] is not None:
            j["paused_for"] += clock.now() - j["paused_at"]
            j["paused_at"] = None
            self.state = "Printing"
            self.reason = ""
            if not self.resin:
                self.roll_left = 1000.0

    def press(self, clock, rng, fail_rate):
        """A press of Print on the deck: the first file of the queue."""
        if self.state != "Operational" or not self.queue:
            return None
        q = self.queue.pop(0)
        self.start(q["name"], q["seconds"], clock, rng, fail_rate)
        return q["name"]

    def clear(self):
        if self.state in ("Finished", "Error"):
            self.state = "Operational"
            self.done_job = None
            self.reason = ""
            return True
        return False

    def fail(self, rng):
        if self.job:
            self.state = "Error"
            self.reason = rng.choice(FAILURES)
            self.done_job = dict(self.job, progress=0)
            self.job = None
            return True
        return False

    # ---- the answers ----

    def job_title(self):
        j = self.job or self.done_job
        return j["name"] if j else ""

    def octo_job(self, clock):
        j = self.job or self.done_job
        if not j:
            return {"job": {"file": {"name": None}}, "progress": {"completion": None, "printTimeLeft": None}, "state": self.state}
        return {"job": {"file": {"name": j["name"], "display": j["name"]}, "estimatedPrintTime": j["total"]},
                "progress": {"completion": round(self.progress(clock) * 100, 2), "printTimeLeft": int(self.time_left(clock))},
                "state": self.state}

    def printdeck_plugin(self, clock):
        out = {"queue": len(self.queue), "material": self.material, "diameter": 0 if self.resin else 1.75,
               "limits": {"max_velocity": int(300 * self.pace), "max_accel": int(4000 * self.pace),
                          "square_corner_velocity": 5}}
        if not self.resin:
            out["spool"] = {"name": self.roll, "id": f"roll-{self.id}", "color": self.color, "left": round(self.roll_left, 1),
                            "price": 25, "full": 1000}
        t = self.job_title()
        if t:
            j = self.job or self.done_job
            layers = 200
            p = self.progress(clock)
            out["job"] = {"title": t, "state": self.state, "progress": round(p, 4), "left": int(self.time_left(clock)),
                          "layer": int(p * layers), "layers": layers}
            if self.reason:
                out["job"]["error"] = self.reason
            del j
        return out

    def moonraker_query(self, clock):
        state = {"Operational": "standby", "Heating": "printing", "Printing": "printing", "Paused": "paused",
                 "Finished": "complete", "Error": "error"}[self.state]
        p = self.progress(clock)
        return {"result": {"status": {
            "print_stats": {"state": state, "filename": self.job_title(), "message": self.reason,
                            "print_duration": 0, "info": {"current_layer": int(p * 200), "total_layer": 200}},
            "virtual_sdcard": {"progress": p},
            "toolhead": {"axis_maximum": [self.bed[0], self.bed[1], self.bed[2], 0],
                         "max_velocity": int(300 * self.pace), "max_accel": int(4000 * self.pace)},
            "configfile": {"settings": {"extruder": {"nozzle_diameter": self.nozzle, "filament_diameter": 1.75}}},
        }}}

    def summary(self, clock):
        return {"id": self.id, "name": self.name, "brand": self.brand, "model": self.model, "kind": self.kind,
                "url": f"http://127.0.0.1:{self.port}", "state": self.state, "job": self.job_title(),
                "progress": round(self.progress(clock), 3), "left_s": int(self.time_left(clock)),
                "reason": self.reason, "material": self.material, "roll": self.roll, "bed": self.bed,
                "nozzle": self.nozzle, "offline": self.offline, "prints": self.prints,
                "queue": [q["name"] for q in self.queue]}


# ---- the G-code: its planned time ----

TIME_RE = [re.compile(rb";Estimated time:\s*(\d+)s"), re.compile(rb";TIME:(\d+)"), re.compile(rb";\s*estimated printing time[^=]*=\s*([^\r\n]+)", re.I),
           re.compile(rb";PRINT\.TIME:(\d+)"), re.compile(rb";\s*total estimated time:\s*([^\r\n]+)", re.I)]


def planned_seconds(gcode):
    head = gcode[:20000] + gcode[-20000:]
    for r in TIME_RE:
        m = r.search(head)
        if not m:
            continue
        v = m.group(1).decode(errors="replace").strip()
        if v.isdigit():
            return float(v)
        s = 0
        for n, u in re.findall(r"(\d+)\s*([dhms])", v):
            s += int(n) * {"d": 86400, "h": 3600, "m": 60, "s": 1}[u]
        if s:
            return float(s)
    # No time in the file: a guess from its size.
    return max(600.0, len(gcode) / 40)


def multipart_file(body, ctype):
    """The file name, its bytes, and the other fields of a multipart form."""
    m = re.search(r"boundary=([^;]+)", ctype or "")
    if not m:
        return None, body, {}
    boundary = b"--" + m.group(1).strip('"').encode()
    name, data, fields = None, b"", {}
    for part in body.split(boundary):
        if b"\r\n\r\n" not in part:
            continue
        head, content = part.split(b"\r\n\r\n", 1)
        content = content.rstrip(b"\r\n-")
        h = head.decode(errors="replace")
        fm = re.search(r'name="([^"]+)"', h)
        fn = re.search(r'filename="([^"]*)"', h)
        if fn:
            name, data = fn.group(1), content
        elif fm:
            fields[fm.group(1)] = content.decode(errors="replace").strip()
    return name, data, fields


class Farm:
    def __init__(self, args):
        self.rng = random.Random(args.seed)
        self.clock = Clock(args.speed)
        self.args = args
        pool = [m for m in MODELS for _ in range(m[6])]
        self.printers = [Printer(i, self.rng.choice(pool), args.port + i, self.rng) for i in range(args.printers)]
        self.orders = []
        self.events = []
        here = os.path.dirname(os.path.abspath(__file__))
        root = os.path.normpath(os.path.join(here, "..", "..", "..", "printdeck"))
        # The models of the projects of printdeck: <project>/stl/**.
        self.models = []
        for proj in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            stl = os.path.join(root, proj, "stl")
            for d, _, fs in os.walk(stl):
                self.models += [os.path.relpath(os.path.join(d, f), root) for f in fs if f.lower().endswith((".stl", ".3mf"))]
        self.models = sorted(self.models)[:400]
        self.next_order = self.clock.now() + args.order_every
        # A farm in the middle of its day: some print, some wait on the bed.
        for p in self.printers:
            r = self.rng.random()
            if p.offline or r >= args.busy:
                continue
            model = os.path.splitext(os.path.basename(self.rng.choice(self.models)))[0] if self.models else "part"
            p.start(model, self.rng.uniform(1800, 8 * 3600), self.clock, self.rng, args.fail_rate)
            if r < args.busy * 0.15:
                p.state, p.done_job, p.job = "Finished", dict(p.job, progress=1.0), None
            elif r < args.busy * 0.2:
                p.state, p.reason = "Error", self.rng.choice(FAILURES)
                p.done_job, p.job = dict(p.job, progress=0.3), None
            else:
                # Started a while ago: move its start back.
                p.state = "Printing"
                p.job["start"] -= p.job["heat"] + p.job["total"] * self.rng.uniform(0.05, 0.9)

    def event(self, p, what):
        line = {"t": round(self.clock.now()), "printer": p.name if p else "", "event": what}
        self.events.append(line)
        del self.events[:-500]
        print(f"[{time.strftime('%H:%M:%S')}] {line['printer']}: {what}", flush=True)

    def tick(self):
        with LOCK:
            now = self.clock.now()
            for p in self.printers:
                e = p.tick(self.clock, self.rng, self.args.pause_rate)
                if e:
                    self.event(p, e + (f" ({p.reason})" if p.reason else "") + (f": {p.job_title()}" if e == "finished" else ""))
                if not self.args.operator or p.offline:
                    continue
                # The people of the farm: a bed to clear, a print to press.
                waits = p.state in ("Finished", "Error") or (p.deck and p.state == "Operational" and p.queue)
                if not waits:
                    p.operator_at = None
                elif p.operator_at is None:
                    p.operator_at = now + self.rng.uniform(300, 2700)
                elif now >= p.operator_at:
                    p.operator_at = None
                    if p.state in ("Finished", "Error") and p.clear():
                        self.event(p, "operator: bed cleared")
                    else:
                        name = p.press(self.clock, self.rng, self.args.fail_rate)
                        if name:
                            self.event(p, f"operator: pressed Print for {name}")
            if self.models and self.clock.now() >= self.next_order:
                self.next_order = self.clock.now() + self.rng.expovariate(1 / self.args.order_every)
                o = {"id": len(self.orders) + 1, "model": self.rng.choice(self.models), "count": self.rng.choice([1, 1, 2, 4, 10, 25]),
                     "material": self.rng.choice(MATERIALS)[0], "due_s": round(self.clock.now() + self.rng.uniform(3600, 86400 * 3))}
                self.orders.append(o)
                self.event(None, f"order {o['id']}: {o['count']} × {o['model']} in {o['material']}")

    def write_fleet(self, path):
        fleet = [{"name": p.name, "kind": "printdeck" if p.kind == "resin" else p.kind, "url": f"http://127.0.0.1:{p.port}",
                  "key": self.args.key, "brand": p.brand, "model": p.model, "bed": p.bed, "nozzle": p.nozzle,
                  "resin": p.resin} for p in self.printers]
        with open(path, "w") as f:
            json.dump({"printers": fleet, "control": f"http://127.0.0.1:{self.args.control}"}, f, indent=1)


def printer_handler(farm, p):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, obj=None, ctype="application/json"):
            body = b"" if obj is None else (obj if isinstance(obj, bytes) else json.dumps(obj).encode())
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authed(self):
            key = self.headers.get("X-Api-Key") or ""
            if "apikey=" in self.path:
                key = self.path.split("apikey=")[1].split("&")[0]
            if farm.args.key and key != farm.args.key:
                self.send(403, {"error": "Invalid API key"})
                return False
            return True

        def do_GET(self):
            if p.offline:
                self.close_connection = True
                return
            path = self.path.split("?")[0]
            if path == "/api/version":
                return self.send(200, {"api": "0.1", "server": "1.9.0", "text": f"printdeck sim ({p.brand} {p.model})"})
            if path == "/server/info" and p.kind == "moonraker":
                return self.send(200, {"result": {"klippy_state": "ready", "moonraker_version": "v0.9-sim"}})
            if not self.authed():
                return
            with LOCK:
                c = farm.clock
                if path == "/api/printer":
                    return self.send(200, {"state": {"text": p.state, "error": p.reason},
                                           "temperature": {"tool0": {"actual": 215 if p.state in ("Printing", "Heating") else 26},
                                                           "bed": {"actual": 60 if p.state == "Printing" else 25}}})
                if path == "/api/printerprofiles":
                    return self.send(200, {"profiles": {"_default": {"current": True, "name": p.model,
                                                                     "volume": {"width": p.bed[0], "depth": p.bed[1], "height": p.bed[2]},
                                                                     "extruder": {"nozzleDiameter": p.nozzle}}}})
                if path == "/api/job":
                    return self.send(200, p.octo_job(c))
                if path == "/api/plugin/printdeck/queue" and p.deck:
                    return self.send(200, {"items": [dict(q, seconds=int(q["seconds"])) for q in p.queue],
                                           "seconds": int(sum(q["seconds"] for q in p.queue))})
                if path == "/api/plugin/printdeck" and p.deck:
                    return self.send(200, p.printdeck_plugin(c))
                if path.startswith("/printer/objects/query") and p.kind == "moonraker":
                    return self.send(200, p.moonraker_query(c))
            self.send(404, {"error": "Not found"})

        def do_POST(self):
            if p.offline:
                self.close_connection = True
                return
            if not self.authed():
                return
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else b""
            path = self.path.split("?")[0]
            if path in ("/api/files/local", "/server/files/upload"):
                name, data, fields = multipart_file(body, self.headers.get("Content-Type"))
                start = fields.get("print", "false").lower() == "true"
                with LOCK:
                    if p.deck:
                        # printdeck: into the queue; a person at the deck starts it.
                        plan = planned_seconds(data)
                        p.queue.append({"id": p.next_id, "path": name, "name": os.path.splitext(name or "job")[0],
                                        "seconds": plan, "from": "zslice"})
                        p.next_id += 1
                        farm.event(p, f"queued {name} ({len(p.queue)} in the queue): it waits for Print on the deck")
                        return self.send(201, {"done": True, "files": {"local": {"name": name, "origin": "local"}}, "effectivePrint": False})
                    if start and p.state != "Operational":
                        what = "a print waits on the bed: clear it first" if p.state in ("Finished", "Error") else f"the printer is {p.state.lower()}"
                        farm.event(p, f"refused {name}: {what}")
                        return self.send(409, {"error": f"Cannot print now: {what}."})
                    if start:
                        plan = planned_seconds(data)
                        p.start(os.path.splitext(name or "job")[0], plan, farm.clock, farm.rng, farm.args.fail_rate)
                        farm.event(p, f"started {name} ({plan / 60:.0f} min planned, {p.job['total'] / 60:.0f} min here)")
                    else:
                        farm.event(p, f"uploaded {name}")
                return self.send(201, {"done": True, "files": {"local": {"name": name, "origin": "local"}}, "effectivePrint": start})
            m = re.match(r"/api/plugin/printdeck/queue/(\d+)/move", path)
            if m and p.deck:
                by = int(json.loads(body or b"{}").get("by") or 0)
                with LOCK:
                    i = next((k for k, q in enumerate(p.queue) if q["id"] == int(m.group(1))), None)
                    if i is None:
                        return self.send(404, {"error": "Not in the queue"})
                    q = p.queue.pop(i)
                    p.queue.insert(min(max(i + by, 0), len(p.queue)), q)
                return self.send(204)
            if path == "/api/job":
                cmd = (json.loads(body or b"{}").get("command") or "")
                with LOCK:
                    if cmd == "cancel" and p.fail(farm.rng):
                        p.reason = "Canceled"
                        farm.event(p, "canceled")
                    elif cmd == "pause":
                        p.resume(farm.clock) if p.state == "Paused" else None
                return self.send(204)
            self.send(404, {"error": "Not found"})

        def do_DELETE(self):
            if p.offline or not self.authed():
                return
            m = re.match(r"/api/plugin/printdeck/queue/(\d+)$", self.path.split("?")[0])
            if m and p.deck:
                with LOCK:
                    n = len(p.queue)
                    p.queue = [q for q in p.queue if q["id"] != int(m.group(1))]
                    return self.send(204 if len(p.queue) < n else 404)
            self.send(404, {"error": "Not found"})

    return H


def control_handler(farm):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, obj):
            body = json.dumps(obj, indent=1).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            with LOCK:
                if self.path.startswith("/farm"):
                    ps = [p.summary(farm.clock) for p in farm.printers]
                    counts = {}
                    for s in ps:
                        counts[s["state"]] = counts.get(s["state"], 0) + 1
                    return self.send(200, {"clock_s": round(farm.clock.now()), "speed": farm.clock.speed, "states": counts, "printers": ps})
                if self.path.startswith("/orders"):
                    return self.send(200, {"orders": farm.orders})
                if self.path.startswith("/events"):
                    return self.send(200, {"events": farm.events[-100:]})
            self.send(404, {"error": "Not found"})

        def do_POST(self):
            m = re.match(r"/farm/(\d+)/(clear|fail|pause|resume|press)", self.path)
            with LOCK:
                if m:
                    i, what = int(m.group(1)), m.group(2)
                    if i >= len(farm.printers):
                        return self.send(404, {"error": "No such printer"})
                    p = farm.printers[i]
                    ok = {"clear": p.clear, "fail": lambda: p.fail(farm.rng),
                          "pause": lambda: bool(p.job) and p.job.update(paused_at=farm.clock.now()) is None and setattr(p, "state", "Paused") is None,
                          "resume": lambda: p.resume(farm.clock) is None,
                          "press": lambda: p.press(farm.clock, farm.rng, farm.args.fail_rate)}[what]()
                    farm.event(p, f"control: {what}")
                    return self.send(200, {"ok": bool(ok), "printer": p.summary(farm.clock)})
                m = re.match(r"/farm/speed\?x=([\d.]+)", self.path)
                if m:
                    farm.clock.set_speed(float(m.group(1)))
                    return self.send(200, {"speed": farm.clock.speed})
            self.send(404, {"error": "Not found"})

    return H


def main():
    ap = argparse.ArgumentParser(description="A simulated print farm for the zslice apps.")
    ap.add_argument("--printers", type=int, default=50)
    ap.add_argument("--port", type=int, default=8100, help="the port of the first printer; the others follow")
    ap.add_argument("--control", type=int, default=8800)
    ap.add_argument("--speed", type=float, default=60, help="farm seconds for each real second")
    ap.add_argument("--fail-rate", type=float, default=0.12, help="the share of the prints that fail")
    ap.add_argument("--pause-rate", type=float, default=0.0005, help="the chance of a runout pause on each tick")
    ap.add_argument("--order-every", type=float, default=1800, help="farm seconds between orders, on average")
    ap.add_argument("--key", default="farm", help="the API key of each printer ('' for none)")
    ap.add_argument("--busy", type=float, default=0.6, help="the share of the printers that print, or wait on the bed, at the start")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--no-operator", dest="operator", action="store_false",
                    help="no people: beds stay full, and printdeck queues wait, until the control API acts")
    ap.add_argument("--fleet", default="fleet.json", help="where to write the list of the printers")
    args = ap.parse_args()

    farm = Farm(args)
    servers = []
    for p in farm.printers:
        s = Server(("127.0.0.1", p.port), printer_handler(farm, p))
        threading.Thread(target=s.serve_forever, daemon=True).start()
        servers.append(s)
    ctl = Server(("127.0.0.1", args.control), control_handler(farm))
    threading.Thread(target=ctl.serve_forever, daemon=True).start()
    farm.write_fleet(args.fleet)
    kinds = {}
    for p in farm.printers:
        kinds[p.kind] = kinds.get(p.kind, 0) + 1
    print(f"farm: {len(farm.printers)} printers on 127.0.0.1:{args.port}-{args.port + len(farm.printers) - 1} "
          f"({', '.join(f'{n} {k}' for k, n in sorted(kinds.items()))}), "
          f"{sum(p.offline for p in farm.printers)} offline; control on :{args.control}; "
          f"clock ×{args.speed:g}; key '{args.key}'; fleet in {args.fleet}; {len(farm.models)} models for orders", flush=True)
    try:
        while True:
            farm.tick()
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
