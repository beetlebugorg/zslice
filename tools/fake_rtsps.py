# A fake RTSPS camera of a Bambu Lab X1, H2, P2S, or X2D, for the tests of
# the RTSP client of the apps (src/rtsp.zig, macos/Sources/ZSlice/Core/
# Camera.swift, linux/src/ui/camera-view.c): TLS with a self-signed
# certificate, a Digest login (the user bblp and the access code 12345678),
# DESCRIBE, SETUP (RTP over the TCP connection), and PLAY. Then it sends the
# H.264 frames of a file at 10 frames a second, again and again: the SPS and
# the PPS in one STAP-A, a small NAL unit alone, and a large one in FU-A
# fragments of 1400 bytes (RFC 6184). It answers GET_PARAMETER, and ends at
# TEARDOWN. Each request, each login, and a count of the frames go to the
# log, so a test can check the session.
#
# The frames: a .aus file of macos/tools/enc.swift (for each frame, a u32
# big endian length and the Annex B bytes), or an Annex B .h264 file with
# one slice in each frame, as ffmpeg writes it:
#
#   ffmpeg -f lavfi -i testsrc=size=640x480:rate=10 -t 4 -c:v libx264 \
#       -profile:v baseline -g 10 out.h264
#
# The certificate: as for macos/tools/fake_bambu.py.
#
#   openssl req -x509 -newkey rsa:2048 -nodes -keyout DIR/key.pem \
#       -out DIR/cert.pem -days 30 -subj /CN=01P00A123456789
#   python3 -I tools/fake_rtsps.py 18322 DIR out.h264 DIR/rtsp.log
#
# The Mac app connects to it with ZSLICE_BAMBU_RTSP_PORT=18322 and a printer
# of the model bambu-lab-x2d (docs/internals/macos.md).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import socket, ssl, sys, struct, hashlib, base64, select, time, threading, os
port, certdir, ausf, logf = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
log = open(logf, "a", buffering=1)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(certdir, "cert.pem"), os.path.join(certdir, "key.pem"))
def nals(au):
    # Split at 00 00 01 (a 4-byte start code has one more zero in front).
    out = []
    for p in au.split(b"\x00\x00\x01"):
        p = p.rstrip(b"\x00")
        if p: out.append(p)
    return out
raw = open(ausf, "rb").read(); aus = []
if ausf.endswith(".aus"):
    i = 0
    while i < len(raw):
        n = struct.unpack(">I", raw[i:i+4])[0]; aus.append(raw[i+4:i+4+n]); i += 4 + n
else:
    # Annex B: a frame starts at a delimiter (9), an SPS (7), or a slice
    # whose first macroblock is 0 (its first bit after the header is 1),
    # unless a delimiter, a parameter set, or an SEI came just before it.
    cur = []; pending = False
    for n in nals(raw):
        t = n[0] & 31
        first = t in (1, 5) and len(n) > 1 and n[1] & 0x80
        starts = (t in (7, 9) or first) and not pending
        if starts and cur: aus.append(b"".join(b"\x00\x00\x00\x01" + x for x in cur)); cur = []
        cur.append(n); pending = t in (6, 7, 8, 9)
    if cur: aus.append(b"".join(b"\x00\x00\x00\x01" + x for x in cur))
sps = next(n for n in nals(aus[0]) if n[0] & 31 == 7); pps = next(n for n in nals(aus[0]) if n[0] & 31 == 8)
REALM, NONCE, USER, CODE = "LIVE555 Streaming Media", "f00dcafe", "bblp", "12345678"
def md5(s): return hashlib.md5(s.encode()).hexdigest()
def client(c):
    f = c.makefile("rb"); session = "4F2A1B"; seq = 0
    def read_req():
        lines = []
        while True:
            l = f.readline()
            if not l: return None
            l = l.decode().rstrip("\r\n")
            if l == "": break
            lines.append(l)
        hdr = {}
        for l in lines[1:]:
            k, _, v = l.partition(":"); hdr[k.strip().lower()] = v.strip()
        return lines[0], hdr
    def reply(code, text, cseq, extra="", body=""):
        m = "RTSP/1.0 %d %s\r\nCSeq: %s\r\n%s" % (code, text, cseq, extra)
        if body: m += "Content-Length: %d\r\n" % len(body)
        c.sendall((m + "\r\n" + body).encode())
    def authed(method, uri, hdr):
        a = hdr.get("authorization", "")
        if not a.startswith("Digest "): return False
        kv = {}
        for part in a[7:].split(","):
            k, _, v = part.strip().partition("="); kv[k] = v.strip('"')
        ha1 = md5("%s:%s:%s" % (USER, REALM, CODE)); ha2 = md5("%s:%s" % (method, kv.get("uri", "")))
        want = md5("%s:%s:%s" % (ha1, NONCE, ha2))
        ok = kv.get("username") == USER and kv.get("response") == want
        log.write("RTSP %s login %s\n" % (method, "ok" if ok else "bad"))
        return ok
    while True:
        r = read_req()
        if not r: return
        line, hdr = r; method, uri, _ = line.split(" "); cseq = hdr.get("cseq", "0")
        log.write("RTSP %s %s\n" % (method, uri))
        if not authed(method, uri, hdr):
            reply(401, "Unauthorized", cseq, 'WWW-Authenticate: Digest realm="%s", nonce="%s"\r\n' % (REALM, NONCE)); continue
        if method == "DESCRIBE":
            sdp = ("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Bambu\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\n"
                   "a=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1;sprop-parameter-sets=%s,%s\r\na=control:track1\r\n"
                   % (base64.b64encode(sps).decode(), base64.b64encode(pps).decode()))
            reply(200, "OK", cseq, "Content-Base: %s/\r\nContent-Type: application/sdp\r\n" % uri, sdp)
        elif method == "SETUP":
            reply(200, "OK", cseq, "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nSession: %s;timeout=65\r\n" % session)
        elif method == "PLAY":
            reply(200, "OK", cseq, "Session: %s\r\n" % session); break
        else:
            reply(200, "OK", cseq)
    # Stream, and answer the requests that come between frames.
    k = 0; sent = 0
    def pkt(payload, marker, ts):
        nonlocal seq
        seq = (seq + 1) & 0xFFFF
        h = struct.pack(">BBHII", 0x80, 96 | (0x80 if marker else 0), seq, ts, 0xBA5E)
        p = h + payload
        c.sendall(b"$" + bytes([0]) + struct.pack(">H", len(p)) + p)
    try:
        while True:
            au = aus[k % len(aus)]; ts = (k * 9000) & 0xFFFFFFFF; units = nals(au)
            sets = [u for u in units if u[0] & 31 in (7, 8)]; rest = [u for u in units if u[0] & 31 not in (7, 8)]
            if sets:
                stap = b"\x78" + b"".join(struct.pack(">H", len(u)) + u for u in sets)
                pkt(stap, False, ts)
            for j, u in enumerate(rest):
                last = j == len(rest) - 1
                if len(u) <= 1400:
                    pkt(u, last, ts)
                else:
                    ind = (u[0] & 0xE0) | 28; body = u[1:]; off = 0
                    while off < len(body):
                        chunk = body[off:off + 1400]; s = off == 0; e = off + 1400 >= len(body)
                        pkt(bytes([ind, (0x80 if s else 0) | (0x40 if e else 0) | (u[0] & 31)]) + chunk, last and e, ts)
                        off += 1400
            k += 1; sent += 1
            if sent % 50 == 0: log.write("RTSP sent %d frames\n" % sent)
            end = time.time() + 0.1
            while time.time() < end:
                rl, _, _ = select.select([c], [], [], max(0, end - time.time()))
                if rl or c.pending():
                    r = read_req()
                    if not r: log.write("RTSP closed after %d frames\n" % sent); return
                    line, hdr = r; method = line.split(" ")[0]; log.write("RTSP %s\n" % method)
                    reply(200, "OK", hdr.get("cseq", "0"), "Session: %s\r\n" % session)
                    if method == "TEARDOWN": log.write("RTSP teardown after %d frames\n" % sent); return
    except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError):
        log.write("RTSP closed after %d frames\n" % sent)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(5)
while True:
    rawc, _ = s.accept()
    try: c = ctx.wrap_socket(rawc, server_side=True)
    except Exception as e: log.write("TLS fail %s\n" % e); continue
    threading.Thread(target=client, args=(c,), daemon=True).start()
