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
# A printdeck has the setting "Start prints from the slicer" (on by
# default, "remote_start" in /api/plugin/printdeck): on, an upload with
# print=true starts at once, as OctoPrint and Moonraker do; off (--deck-ask,
# a farm), the upload goes into its queue (GET /api/plugin/printdeck/queue,
# DELETE and move of an item) until a person at the deck presses Print, and
# the reply has "effectivePrint": false. The app asks the user first if the
# bed is clear.
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
# The cameras: most printers have a webcam, as the real ones give it.
# printdeck: /webcam/stream (MJPEG, multipart/x-mixed-replace) and
# /webcam/snapshot, with the API key in the query, named in /api/settings.
# OctoPrint: the paths of mjpg-streamer (/webcam/?action=stream and
# ?action=snapshot), named in /api/settings. Moonraker: /server/webcams/list,
# with an "mjpegstreamer" camera or a "webrtc-camerastreamer" camera (the app
# polls its snapshot). A few cameras answer 503, for the error message of
# the apps. The frames are a test pattern of ffmpeg, made once at the start;
# with no ffmpeg, the printers have no camera.
#
# App Keys (OctoPrint and printdeck): POST /plugin/appkeys/request gives a
# token, and GET /plugin/appkeys/request/<token> answers 202 until a person
# at the printer allows the app (POST /farm/<id>/allow of the control API,
# or --appkeys-allow-after seconds), then 200 with the key (--key). POST
# /farm/<id>/deny, or 2 minutes, end it with 404.
#
# A deck with many printers (--deck-printers N): the first printer is a
# printdeck that drives the first N printers. /slicer/printer.json lists
# them, and the paths under /printers/p<i>/ go to printer i, as on a
# printdeck with many printers.
#
# CORS: a web page on this computer (an Origin of 127.0.0.1 or localhost,
# any port; --allow-origin adds others) can read the printers, as a printer
# that allows the page does (printdeck WEB_ORIGINS, OctoPrint "Allow Cross
# Origin Requests", Moonraker cors_domains). The control API stays closed
# to web pages.
#
# Usage: python3 -I tools/farm_sim/farm_sim.py --printers 50 --speed 60
#
# See docs/references/formats-and-protocols.md: the OctoPrint, Moonraker, and printdeck APIs.
#
# SPDX-License-Identifier: AGPL-3.0-or-later

import argparse
import json
import os
import random
import re
import shutil
import socketserver
import subprocess
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
FARM_ARGS = None
# The App Keys requests: token -> {printer, at, state}.
APPKEYS = {}
# The JPEG frames of the cameras (make_frames), shared by all printers.
FRAMES = []
LOCAL_ORIGIN = re.compile(r"^https?://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$")


def make_frames(n=48, size="480x270"):
    """A moving test pattern as JPEG frames, from ffmpeg. [] with no
    ffmpeg."""
    ff = shutil.which("ffmpeg")
    if not ff:
        return []
    try:
        out = subprocess.run([ff, "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={size}:rate=12", "-frames:v", str(n),
                              "-q:v", "6", "-f", "image2pipe", "-c:v", "mjpeg", "-"], capture_output=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    frames = []
    i = 0
    while True:
        a = out.find(b"\xff\xd8", i)
        b = out.find(b"\xff\xd9", a + 2)
        if a < 0 or b < 0:
            break
        frames.append(out[a:b + 2])
        i = b + 2
    return frames


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
        # The camera: "mjpeg" (a stream and snapshots), "snapshot" (only
        # snapshots: a WebRTC camera of Moonraker), "broken" (503), or None.
        # The camera follows the number of the printer, so the farm of each
        # seed stays as it was.
        if self.resin and i % 2:
            self.camera = None
        elif kind == "moonraker" and i % 3 == 2:
            self.camera = "snapshot"
        elif i % 9 == 4:
            self.camera = "broken"
        else:
            self.camera = "mjpeg"

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
        out = {"job": {"file": {"name": j["name"], "display": j["name"]}, "estimatedPrintTime": j["total"]},
               "progress": {"completion": round(self.progress(clock) * 100, 2), "printTimeLeft": int(self.time_left(clock))},
               "state": self.state}
        # OctoPrint gives the error of a failed job at the top.
        if self.reason and self.state == "Error":
            out["error"] = self.reason
        return out

    def printdeck_plugin(self, clock):
        out = {"remote_start": not FARM_ARGS.deck_ask, "queue": len(self.queue), "material": self.material, "diameter": 0 if self.resin else 1.75,
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
            del j
        return out

    def heat(self):
        """The temperatures: (nozzle, nozzle target, bed, bed target)."""
        if self.resin:
            return (0, 0, 0, 0)
        hot = self.state in ("Heating", "Printing", "Paused")
        tn = {"PLA": 215, "PETG": 240, "ASA": 255, "TPU": 225}.get(self.material, 215) if hot else 0
        tb = {"PLA": 60, "PETG": 80, "ASA": 100, "TPU": 50}.get(self.material, 60) if hot else 0
        if self.state == "Heating":
            return (round(tn * 0.7, 1), tn, round(tb * 0.8, 1), tb)
        return (round(tn + 0.4, 1) if hot else 26.0, tn, round(tb - 0.2, 1) if hot else 25.0, tb)

    def octo_webcam(self, key):
        """The webcam of /api/settings: printdeck has the key in the
        address; OctoPrint has the paths of mjpg-streamer."""
        if not self.camera or not FRAMES:
            return {"webcamEnabled": False, "streamUrl": "", "snapshotUrl": ""}
        if self.deck:
            q = f"?apikey={key}" if key else ""
            return {"webcamEnabled": True, "streamUrl": f"/webcam/stream{q}", "snapshotUrl": f"/webcam/snapshot{q}",
                    "flipH": False, "flipV": False, "rotate90": False}
        return {"webcamEnabled": True, "streamUrl": "/webcam/?action=stream", "snapshotUrl": "/webcam/?action=snapshot",
                "flipH": False, "flipV": False, "rotate90": False}

    def moonraker_webcams(self):
        if not self.camera or not FRAMES:
            return {"result": {"webcams": []}}
        service = "webrtc-camerastreamer" if self.camera == "snapshot" else "mjpegstreamer"
        stream = "/webcam/webrtc" if self.camera == "snapshot" else "/webcam/?action=stream"
        return {"result": {"webcams": [{"name": "cam", "location": "printer", "service": service, "enabled": True,
                                        "target_fps": 15, "stream_url": stream, "snapshot_url": "/webcam/?action=snapshot",
                                        "flip_horizontal": False, "flip_vertical": False, "rotation": 0}]}}

    def moonraker_query(self, clock):
        state = {"Operational": "standby", "Heating": "printing", "Printing": "printing", "Paused": "paused",
                 "Finished": "complete", "Error": "error"}[self.state]
        p = self.progress(clock)
        n, nt, b, bt = self.heat()
        return {"result": {"status": {
            "extruder": {"temperature": n, "target": nt},
            "heater_bed": {"temperature": b, "target": bt},
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

        def cors(self):
            """The CORS headers for a page on this computer, or for an
            origin of --allow-origin. Other pages get none, and the browser
            blocks them."""
            o = self.headers.get("Origin")
            if o and (LOCAL_ORIGIN.match(o) or o in (farm.args.allow_origin or [])):
                self.send_header("Access-Control-Allow-Origin", o)
                self.send_header("Vary", "Origin")

        def send(self, code, obj=None, ctype="application/json"):
            body = b"" if obj is None else (obj if isinstance(obj, bytes) else json.dumps(obj).encode())
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.cors()
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):
            if p.offline:
                self.close_connection = True
                return
            self.send_response(204)
            self.cors()
            self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "X-Api-Key, Content-Type")
            self.send_header("Access-Control-Max-Age", "600")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def webcam(self, stream):
            """A snapshot, or an MJPEG stream at fps (5 by default) until the
            client goes."""
            if not p.camera or not FRAMES:
                return self.send(404, {"error": "No camera"})
            if p.camera == "broken":
                return self.send(503, {"error": "The camera is off"})
            if stream and p.camera == "snapshot":
                return self.send(404, {"error": "Not found"})
            if not stream:
                return self.send(200, FRAMES[int(time.time() * 12) % len(FRAMES)], "image/jpeg")
            m = re.search(r"[?&]fps=([\d.]+)", self.path)
            wait = 1 / min(max(float(m.group(1)) if m else 5.0, 0.1), 15)
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store")
            self.cors()
            self.end_headers()
            k = p.id
            try:
                while True:
                    f = FRAMES[k % len(FRAMES)]
                    k += 1
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(f) + f + b"\r\n")
                    self.wfile.flush()
                    time.sleep(wait)
            except (BrokenPipeError, ConnectionResetError, OSError):
                self.close_connection = True

        def authed(self):
            key = self.headers.get("X-Api-Key") or ""
            if "apikey=" in self.path:
                key = self.path.split("apikey=")[1].split("&")[0]
            if farm.args.key and key != farm.args.key:
                self.send(403, {"error": "Invalid API key"})
                return False
            return True

        def other(self):
            """The handler of printer i for /printers/p<i>/... of a deck
            with many printers, with self.path cut; or None."""
            m = re.match(r"/printers/p(\d+)(/.*)$", self.path)
            n = farm.args.deck_printers
            if not m or p.id != 0 or n < 2 or int(m.group(1)) >= min(n, len(farm.printers)):
                return None
            self.path = m.group(2)
            return printer_handler(farm, farm.printers[int(m.group(1))])

        def appkeys(self, path):
            """The App Keys flow, or False for another path."""
            if self.command == "POST" and path == "/plugin/appkeys/request":
                tok = "%016x" % random.getrandbits(64)
                with LOCK:
                    APPKEYS[tok] = {"printer": p.id, "at": time.time(), "state": "wait"}
                    farm.event(p, "App Keys: an app asks for a key; allow it at the printer (POST /farm/%d/allow)" % p.id)
                self.send(201, {"app_token": tok, "auth_dialog": ""})
                return True
            m = re.match(r"/plugin/appkeys/request/([0-9a-f]+)$", path)
            if self.command == "GET" and m:
                with LOCK:
                    r = APPKEYS.get(m.group(1))
                    if r and r["state"] == "wait" and farm.args.appkeys_allow_after >= 0 and time.time() - r["at"] >= farm.args.appkeys_allow_after:
                        r["state"] = "allowed"
                    if not r or r["printer"] != p.id or r["state"] == "denied" or time.time() - r["at"] > 120:
                        self.send(404, {"error": "No such request"})
                    elif r["state"] == "allowed":
                        self.send(200, {"api_key": farm.args.key})
                    else:
                        self.send(202)
                return True
            return False

        def do_GET(self):
            if p.offline:
                self.close_connection = True
                return
            h = self.other()
            if h:
                # The handler of that printer serves this request.
                self.__class__ = h
                return self.do_GET()
            path = self.path.split("?")[0]
            if self.appkeys(path):
                return
            if path == "/slicer/printer.json" and p.deck:
                if not self.authed():
                    return
                n = min(farm.args.deck_printers, len(farm.printers)) if p.id == 0 else 0
                out = {"name": p.name, "kind": "printdeck", "url": "", "https": ""}
                if n >= 2:
                    out["printers"] = [{"id": "p%d" % q.id, "name": q.name, "label": q.model, "color": "#%06x" % (0x3366cc + 0x1f2f3f * q.id & 0xffffff),
                                        "kind": "resin" if q.resin else "fdm", "url": "" if q.id == 0 else "/printers/p%d" % q.id}
                                       for q in farm.printers[:n]]
                return self.send(200, out)
            if path == "/api/version":
                return self.send(200, {"api": "0.1", "server": "1.9.0", "text": f"printdeck sim ({p.brand} {p.model})"})
            if path == "/server/info" and p.kind == "moonraker":
                return self.send(200, {"result": {"klippy_state": "ready", "moonraker_version": "v0.9-sim"}})
            # mjpg-streamer of OctoPrint and Moonraker: no API key.
            if path == "/webcam/" and not p.deck:
                return self.webcam("action=stream" in self.path)
            if path in ("/webcam/stream", "/webcam/snapshot") and p.deck:
                return self.authed() and self.webcam(path.endswith("stream"))
            if not self.authed():
                return
            with LOCK:
                c = farm.clock
                if path == "/api/printer":
                    n, nt, b, bt = p.heat()
                    return self.send(200, {"state": {"text": p.state, "error": p.reason},
                                           "temperature": {"tool0": {"actual": n, "target": nt},
                                                           "bed": {"actual": b, "target": bt}}})
                if path == "/api/settings" and p.kind != "moonraker":
                    return self.send(200, {"api": {"allowCrossOrigin": True}, "webcam": p.octo_webcam(farm.args.key)})
                if path == "/server/webcams/list" and p.kind == "moonraker":
                    return self.send(200, p.moonraker_webcams())
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
            h = self.other()
            if h:
                self.__class__ = h
                return self.do_POST()
            if self.appkeys(self.path.split("?")[0]):
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
                    if p.deck and (farm.args.deck_ask or not start or p.state != "Operational"):
                        # printdeck set to ask (or busy): into the queue; a
                        # person at the deck starts it.
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

        def local(self):
            """Only a client on this computer: the Host header must name
            127.0.0.1 or localhost, and a request from a web page (with an
            Origin header) is refused. A page on another site in a browser
            on this computer can then not use the control API, even with
            DNS rebinding."""
            host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
            if host not in ("127.0.0.1", "localhost", "::1") or self.headers.get("Origin"):
                self.send(403, {"error": "The control API is for clients on this computer"})
                return False
            return True

        def do_GET(self):
            if not self.local():
                return
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
            if not self.local():
                return
            m = re.match(r"/farm/(\d+)/(allow|deny)", self.path)
            if m:
                with LOCK:
                    n = 0
                    for r in APPKEYS.values():
                        if r["printer"] == int(m.group(1)) and r["state"] == "wait":
                            r["state"] = "allowed" if m.group(2) == "allow" else "denied"
                            n += 1
                return self.send(200, {"requests": n})
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
    ap.add_argument("--deck-ask", action="store_true",
                    help="each printdeck asks on the deck for a print (a farm); by default it starts a print from the slicer")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--no-operator", dest="operator", action="store_false",
                    help="no people: beds stay full, and printdeck queues wait, until the control API acts")
    ap.add_argument("--fleet", default="fleet.json", help="where to write the list of the printers")
    ap.add_argument("--allow-origin", action="append", metavar="ORIGIN",
                    help="a web page origin that may read the printers (CORS); pages on 127.0.0.1 and localhost always may")
    ap.add_argument("--deck-printers", type=int, default=0, help="the first printer is a printdeck that drives the first N printers")
    ap.add_argument("--appkeys-allow-after", type=float, default=-1,
                    help="a person allows each App Keys request after this many seconds (-1: only POST /farm/<id>/allow)")
    ap.add_argument("--no-cameras", dest="cameras", action="store_false", help="no webcams (no ffmpeg run at the start)")
    args = ap.parse_args()

    global FARM_ARGS
    FARM_ARGS = args
    if args.cameras:
        FRAMES.extend(make_frames())
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
          f"{sum(p.offline for p in farm.printers)} offline; {sum(bool(p.camera) for p in farm.printers) if FRAMES else 0} cameras; control on :{args.control}; "
          f"clock ×{args.speed:g}; key '{args.key}'; fleet in {args.fleet}; {len(farm.models)} models for orders", flush=True)
    try:
        while True:
            farm.tick()
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
