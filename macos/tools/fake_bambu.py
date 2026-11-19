# A fake Bambu Lab printer, for the tests of the Bambu link of the macOS
# app (macos/Sources/ZSlice/Core/Bambu.swift, docs/internals/macos.md) and
# of the Linux app (linux/src/net/bambu-link.c, linux/src/ui/camera-view.c):
# implicit FTPS (FTP_PORT, 990 by default), MQTT 3.1.1 over TLS
# (MQTT_PORT, 8883 by default), and the JPEG camera of the P1 and A1
# printers over TLS (CAM_PORT, 6000 by default), with a self-signed
# certificate, as a real printer has.
#
# After a SUBSCRIBE, the fake sends a report each second by itself (a
# print that goes on, with its temperatures), so a client that never
# publishes still gets the status. The camera checks the 80 bytes of the
# login, then sends a frame of a test pattern of ffmpeg 5 times a second: a
# 16-byte header with the JPEG size, then the JPEG. Each PUBLISH of a
# client goes to fake.log, so a test can check that a client sent none. The data TLS of
# FTPS starts after the 150 reply of STOR, as vsftpd does. The access code
# is 12345678 and the serial 01P00A123456789. It writes fake.log and the
# uploaded files to the folder of its certificate:
#
#   openssl req -x509 -newkey rsa:2048 -nodes -keyout DIR/key.pem \
#       -out DIR/cert.pem -days 30 -subj /CN=01P00A123456789
#   FTP_PORT=2990 python3 -I macos/tools/fake_bambu.py DIR
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import socket, ssl, threading, sys, json, os, shutil, struct, subprocess, time
HERE = sys.argv[1]
CODE, SERIAL = "12345678", "01P00A123456789"
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(HERE, "cert.pem"), os.path.join(HERE, "key.pem"))
log = open(os.path.join(HERE, "fake.log"), "a", buffering=1)

def ftp_client(c):
    f = c.makefile("rwb", buffering=0)
    def say(s): c.sendall((s + "\r\n").encode())
    say("220 fake bambu")
    user = None; data_srv = None
    while True:
        line = f.readline()
        if not line: return
        cmd = line.decode().strip(); log.write("FTP " + (cmd if not cmd.startswith("PASS") else "PASS ***") + "\n")
        verb = cmd.split(" ")[0].upper(); arg = cmd[len(verb):].strip()
        if verb == "USER": user = arg; say("331 password")
        elif verb == "PASS": say("230 ok" if user == "bblp" and arg == CODE else "530 bad")
        elif verb in ("TYPE", "PBSZ", "PROT"): say("200 ok")
        elif verb == "PASV":
            data_srv = socket.socket(); data_srv.bind(("127.0.0.1", 0)); data_srv.listen(1)
            p = data_srv.getsockname()[1]
            say("227 Entering Passive Mode (127,0,0,1,%d,%d)" % (p // 256, p % 256))
        elif verb == "STOR":
            raw, _ = data_srv.accept()
            say("150 ok")
            d = ctx.wrap_socket(raw, server_side=True)  # TLS after 150, as vsftpd
            got = b""
            while True:
                b = d.recv(65536)
                if not b: break
                got += b
            open(os.path.join(HERE, "uploaded_" + arg), "wb").write(got)
            log.write("FTP stored %s %d bytes\n" % (arg, len(got)))
            say("226 done")
        elif verb == "QUIT": say("221 bye"); return
        else: say("502 no")

def rl(c):
    n, m = 0, 1
    while True:
        b = c.recv(1)[0]; n += (b & 127) * m; m *= 128
        if b < 128: return n

def read_exact(c, n):
    out = b""
    while len(out) < n:
        b = c.recv(n - len(out))
        if not b: raise EOFError
        out += b
    return out

def mstr(s): b = s.encode(); return bytes([len(b) >> 8, len(b) & 255]) + b
def pkt(t, body):
    out = bytes([t]); n = len(body)
    while True:
        b = n % 128; n //= 128
        out += bytes([b | (128 if n else 0)])
        if not n: break
    return out + body

def mqtt_client(c):
    while True:
        h = c.recv(1)
        if not h: return
        n = rl(c); body = read_exact(c, n) if n else b""
        t = h[0] & 0xF0
        if t == 0x10:
            i = 10  # after "MQTT", the level, the flags, and the keep-alive
            def s(i): l = body[i] << 8 | body[i+1]; return body[i+2:i+2+l].decode(), i + 2 + l
            cid, i = s(i); u, i = s(i); p, i = s(i)
            ok = u == "bblp" and p == CODE
            log.write("MQTT connect %s %s\n" % (u, "ok" if ok else "bad code"))
            c.sendall(pkt(0x20, bytes([0, 0 if ok else 5])))
            if not ok: return
        elif t == 0x80:
            l = body[2] << 8 | body[3]; topic = body[4:4+l].decode()
            log.write("MQTT subscribe %s\n" % topic)
            c.sendall(pkt(0x90, body[:2] + b"\x00"))
            threading.Thread(target=reports, args=(c,), daemon=True).start()
        elif t == 0x30:
            l = body[0] << 8 | body[1]; topic = body[2:2+l].decode(); payload = body[2+l:]
            log.write("MQTT publish %s %s\n" % (topic, payload.decode()))
            if b"pushall" in payload:
                rep = {"print": {"gcode_state": "RUNNING", "subtask_name": "clip_tape", "mc_percent": 42, "mc_remaining_time": 17, "layer_num": 12, "total_layer_num": 40, "nozzle_diameter": "0.4"}}
                c.sendall(pkt(0x30, mstr("device/%s/report" % SERIAL) + json.dumps(rep).encode()))
        elif t == 0xC0:
            c.sendall(pkt(0xD0, b""))
        elif t == 0xE0: return

def reports(c):
    # A report each second, as a printer in LAN mode sends them: the first
    # one full, then the changes.
    t0 = time.time()
    first = True
    while True:
        k = time.time() - t0
        p = {"mc_percent": min(99, 42 + int(k / 10)), "mc_remaining_time": max(1, 17 - int(k / 60)), "layer_num": 12 + int(k / 10),
             "nozzle_temper": round(219.6 + (k % 3) / 10, 1), "bed_temper": 65.0, "chamber_temper": 31}
        if first:
            p.update({"gcode_state": "RUNNING", "subtask_name": "clip_tape", "total_layer_num": 40, "nozzle_diameter": "0.4",
                      "nozzle_target_temper": 220, "bed_target_temper": 65})
            first = False
        try:
            c.sendall(pkt(0x30, mstr("device/%s/report" % SERIAL) + json.dumps({"print": p}).encode()))
        except OSError:
            return
        time.sleep(1)

def frames():
    ff = shutil.which("ffmpeg")
    if not ff: return []
    out = subprocess.run([ff, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=10", "-frames:v", "30",
                          "-q:v", "5", "-f", "image2pipe", "-c:v", "mjpeg", "-"], capture_output=True).stdout
    fs, i = [], 0
    while True:
        a = out.find(b"\xff\xd8", i); b = out.find(b"\xff\xd9", a + 2)
        if a < 0 or b < 0: return fs
        fs.append(out[a:b + 2]); i = b + 2

FRAMES = frames()

def camera_client(c):
    auth = read_exact(c, 80)
    u = auth[16:48].rstrip(b"\0").decode(); code = auth[48:80].rstrip(b"\0").decode()
    ok = struct.unpack("<II", auth[:8]) == (0x40, 0x3000) and u == "bblp" and code == CODE
    log.write("CAM login %s %s\n" % (u, "ok" if ok else "bad code"))
    if not ok or not FRAMES: return
    k = 0
    while True:
        f = FRAMES[k % len(FRAMES)]; k += 1
        try:
            c.sendall(struct.pack("<IIII", len(f), 0, 1, 0) + f)
        except OSError:
            return
        time.sleep(0.2)

def serve(port, handler):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(5)
    while True:
        raw, _ = s.accept()
        try:
            c = ctx.wrap_socket(raw, server_side=True)
        except Exception as e:
            log.write("TLS fail %d %s\n" % (port, e)); continue
        threading.Thread(target=lambda: (handler(c)), daemon=True).start()

threading.Thread(target=serve, args=(int(os.environ.get("FTP_PORT", "990")), ftp_client), daemon=True).start()
threading.Thread(target=serve, args=(int(os.environ.get("CAM_PORT", "6000")), camera_client), daemon=True).start()
serve(int(os.environ.get("MQTT_PORT", "8883")), mqtt_client)
