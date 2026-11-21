#!/usr/bin/env python3
"""Makes the bed models of the printer library (src/printers/beds/).

tools/printer_library.py loads this file as a module. For each printer
model with a bed model or a bed texture in a source, it calls `Beds.add`.
The class converts the files of the source into the compact files of
zslice, writes each file once (the same bytes: the same file), and gives
the names for the library record.

The sources and their files:

- Cura: the `platform` mesh in resources/meshes (STL, OBJ, or 3MF), with
  `platform_offset`, and the `platform_texture` image in resources/images.
  The texture uses the UV coordinates of the mesh, so only an OBJ mesh
  with UV coordinates gets a texture.
- PrusaSlicer: the `bed_model` STL and the `bed_texture` SVG or PNG in the
  folder of the vendor bundle.
- OrcaSlicer: the `bed_model` STL and the `bed_texture` SVG or PNG of the
  `machine_model` preset, in the folder of the vendor.

Each source places its bed model with its own rule (see `place_*`). The
tool turns each rule into one form: the mesh in printer axes (x right, y to
the back, z up, in mm), and an offset from the center of the bed. The
texture of PrusaSlicer and OrcaSlicer covers the bed rectangle of the
printer; the record has this rectangle, from the center of the bed.

The files that zslice writes:

- `<name>.mesh`: a triangle mesh with 16-bit coordinates. The format is in
  the header comment of src/bed.zig. A mesh of more than `MAX_TRIANGLES`
  triangles gets fewer by vertex clustering: the vertices in one cell of a
  grid become one vertex, and the triangles that collapse go away. The
  cell size is the smallest that gives few enough triangles.
- `<name>.png`: the texture, at most `MAX_TEXTURE` pixels on its long
  side, with a palette of at most 64 colors and alpha (an 8-bit PNG of
  color type 3). An SVG texture is drawn with rsvg-convert.

The files of the sources are untrusted data. The tool parses them as data
and runs no code from them. rsvg-convert reads each SVG with a time limit.

References (see docs/references/): the bed placement code of Cura (Uranium
Platform.py and the mesh readers), PrusaSlicer (3DBed.cpp), and OrcaSlicer
(3DBed.cpp and PartPlate.cpp). zslice copies no code from them.
"""

import hashlib
import io
import os
import re
import struct
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image

MAX_TRIANGLES = 5000
MAX_TEXTURE = 1024
TEXTURE_COLORS = 64

# Files that the library leaves out: the source, a pattern of the path, and
# the reason.
LEFT_OUT = [
    # "The graphics for the bed (SVG) was created by PwnCNC and published on
    # Thingiverse under the Creative Commons Attribution license" (the header
    # of RatRig.ini). The version of the license is not known: the
    # Thingiverse page does not open. The STL files of the bundle have no
    # such note.
    ("p", r"/resources/profiles/RatRig/[^/]+\.svg$", "CC BY of an unknown version (PwnCNC, Thingiverse thing 4861532)"),
]


def warn(*a):
    print(*a, file=sys.stderr)


# ---- readers ----


def read_stl(path):
    """Triangles (n, 3, 3) of a binary or ASCII STL file."""
    data = open(path, "rb").read()
    if len(data) >= 84:
        n = struct.unpack_from("<I", data, 80)[0]
        if 84 + 50 * n == len(data):
            rec = np.frombuffer(data, dtype=np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")]), count=n, offset=84)
            return rec["v"].astype(np.float64), None
    text = data.decode("latin-1")
    vs = [tuple(float(x) for x in m.groups()) for m in re.finditer(r"vertex\s+(\S+)\s+(\S+)\s+(\S+)", text)]
    n = len(vs) // 3
    return np.array(vs[: 3 * n], dtype=np.float64).reshape(n, 3, 3), None


def read_obj(path):
    """Triangles and UV coordinates (n, 3, 2), or None if the file has no
    UV coordinates. The axes are those of the file."""
    vs, vts, tris, uvs = [], [], [], []
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            p = line.split()
            if not p:
                continue
            if p[0] == "v":
                vs.append([float(x) for x in p[1:4]])
            elif p[0] == "vt":
                vts.append([float(x) for x in p[1:3]])
            elif p[0] == "f":
                ids = []
                for q in p[1:]:
                    a = q.split("/")
                    vi = int(a[0])
                    ti = int(a[1]) if len(a) > 1 and a[1] else 0
                    ids.append((vi - 1 if vi > 0 else len(vs) + vi, ti - 1 if ti > 0 else (len(vts) + ti if ti < 0 else -1)))
                for k in range(1, len(ids) - 1):
                    tri = (ids[0], ids[k], ids[k + 1])
                    tris.append([vs[i] for i, _ in tri])
                    uvs.append([vts[t] if 0 <= t < len(vts) else [0.0, 0.0] for _, t in tri])
    t = np.array(tris, dtype=np.float64).reshape(-1, 3, 3)
    if not vts:
        return t, None
    return t, np.array(uvs, dtype=np.float64).reshape(-1, 3, 2)


def read_3mf(path):
    """The triangles of the mesh object with the most triangles, in the
    coordinates of the file. Cura uses only the mesh data of this object
    (not the transform of its node)."""
    z = zipfile.ZipFile(path)
    name = next(n for n in z.namelist() if n.lower().endswith("3dmodel.model"))
    root = ET.fromstring(z.read(name))
    ns = root.tag[: root.tag.index("}") + 1] if root.tag.startswith("{") else ""
    best = None
    for o in root.iter(ns + "object"):
        m = o.find(ns + "mesh")
        if m is None:
            continue
        vs = np.array([(float(v.get("x")), float(v.get("y")), float(v.get("z"))) for v in m.find(ns + "vertices")], dtype=np.float64)
        ids = np.array([(int(t.get("v1")), int(t.get("v2")), int(t.get("v3"))) for t in m.find(ns + "triangles")], dtype=np.int64)
        if len(ids) and (best is None or len(ids) > len(best)):
            best = vs[ids]
    if best is None:
        raise ValueError("no mesh")
    return best, None


# ---- placement ----
#
# Each function gives the triangles in printer axes, and the offset of the
# mesh from the center of the bed (x, y, z in mm).


def place_cura(path, offset):
    """Cura (Uranium): the scene has y up, and its origin is the center of
    the bed. The STL and OBJ readers turn (x, y, z) of the file into (x, z,
    -y) of the scene, so the file has printer axes. The 3MF reader keeps
    the coordinates of the file as scene coordinates, so a 3MF platform is
    (x, -z, y) in printer axes. `platform_offset` is the position of the
    node in the scene: (x, up, -y)."""
    ext = path.lower().rsplit(".", 1)[-1]
    if ext == "stl":
        tris, uv = read_stl(path)
    elif ext == "obj":
        tris, uv = read_obj(path)
    elif ext == "3mf":
        tris, uv = read_3mf(path)
        tris = np.stack([tris[..., 0], -tris[..., 2], tris[..., 1]], axis=-1)
    else:
        raise ValueError("format " + ext)
    if uv is not None:
        # Uranium mirrors the image when it loads it, so v = 0 is the
        # bottom row. zslice counts v from the top row.
        uv = uv.copy()
        uv[..., 1] = 1.0 - uv[..., 1]
    o = offset or [0, 0, 0]
    if isinstance(o, str):
        o = [float(x) for x in o.split(",")]
    if len(o) != 3:
        o = [0, 0, 0]
    return tris, uv, (float(o[0]), -float(o[2]), float(o[1]))


def place_prusa(path):
    """PrusaSlicer (Bed3D::init_internal_model_from_file): the origin of the
    model goes to the center of the bed shape, 0.03 mm down."""
    tris, _ = read_stl(path)
    return tris, None, (0.0, 0.0, -0.03)


def place_orca(path, shape_max):
    """OrcaSlicer (Bed3D::update_model_offset): the origin of the model goes
    to the center of the printable area, 0.45 mm down (-0.41 and the ground
    of -0.04). A model of Bambu Lab ("bbl-3dp-" in the name) has printer
    coordinates: the offset is less half of the far corner of the area."""
    tris, _ = read_stl(path)
    dx = dy = 0.0
    if "bbl-3dp-" in os.path.basename(path):
        dx, dy = -shape_max[0] / 2.0, -shape_max[1] / 2.0
    return tris, None, (dx, dy, -0.45)


# ---- mesh ----


def weld(tris, uv):
    """Shared vertices: (positions, uvs or None, triangle indices)."""
    pts = tris.reshape(-1, 3)
    if uv is not None:
        key = np.concatenate([np.round(pts, 4), np.round(uv.reshape(-1, 2), 5)], axis=1)
    else:
        key = np.round(pts, 4)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    pos = np.zeros((len(uniq), 3))
    np.add.at(pos, inv, pts)
    cnt = np.bincount(inv, minlength=len(uniq))[:, None]
    pos /= cnt
    uvs = None
    if uv is not None:
        uvs = np.zeros((len(uniq), 2))
        np.add.at(uvs, inv, uv.reshape(-1, 2))
        uvs /= cnt
    return pos, uvs, inv.reshape(-1, 3)


def clean(idx):
    """Drops the triangles with two equal corners, and repeated triangles."""
    ok = (idx[:, 0] != idx[:, 1]) & (idx[:, 1] != idx[:, 2]) & (idx[:, 0] != idx[:, 2])
    idx = idx[ok]
    if len(idx) == 0:
        return idx
    key = np.sort(idx, axis=1)
    _, first = np.unique(key, axis=0, return_index=True)
    return idx[np.sort(first)]


def cluster(pos, uvs, idx, cell):
    """Vertex clustering: one vertex for each cell of the grid (and each
    UV cell, so that the seams of a texture stay)."""
    lo = pos.min(axis=0)
    key = np.floor((pos - lo) / cell).astype(np.int64)
    if uvs is not None:
        key = np.concatenate([key, np.floor(uvs * 64).astype(np.int64)], axis=1)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    npos = np.zeros((len(uniq), 3))
    np.add.at(npos, inv, pos)
    cnt = np.bincount(inv, minlength=len(uniq))[:, None]
    npos /= cnt
    nuv = None
    if uvs is not None:
        nuv = np.zeros((len(uniq), 2))
        np.add.at(nuv, inv, uvs)
        nuv /= cnt
    nidx = clean(inv[idx])
    # Only the vertices that a triangle uses.
    used = np.unique(nidx)
    remap = np.full(len(npos), -1, dtype=np.int64)
    remap[used] = np.arange(len(used))
    return npos[used], (nuv[used] if nuv is not None else None), remap[nidx]


def decimate(pos, uvs, idx, target):
    if len(idx) <= target:
        return pos, uvs, idx
    size = float((pos.max(axis=0) - pos.min(axis=0)).max())
    lo, hi = 0.0, size / 4.0
    best = cluster(pos, uvs, idx, hi)
    for _ in range(18):
        mid = (lo + hi) / 2.0
        r = cluster(pos, uvs, idx, mid)
        if len(r[2]) <= target:
            best, hi = r, mid
        else:
            lo = mid
    return best


def encode_mesh(pos, uvs, idx):
    """The bytes of a .mesh file (see src/bed.zig)."""
    c = (pos.max(axis=0) + pos.min(axis=0)) / 2.0
    ext = float(np.abs(pos - c).max()) or 1.0
    scale = ext / 32767.0
    q = np.clip(np.round((pos - c) / scale), -32767, 32767).astype("<i2")
    flags = 0
    if uvs is not None:
        flags |= 1
    wide = len(pos) > 65535
    if wide:
        flags |= 2
    out = io.BytesIO()
    out.write(b"ZSBM")
    out.write(struct.pack("<HHII4f", 1, flags, len(pos), len(idx), scale, c[0], c[1], c[2]))
    out.write(q.tobytes())
    if len(pos) % 2:
        out.write(b"\0\0")
    if uvs is not None:
        # UV in 1/8192, with v from the top row of the image down.
        u = np.clip(np.round(uvs * 8192), -32767, 32767).astype("<i2")
        out.write(u.tobytes())
    out.write(idx.astype("<u4" if wide else "<u2").tobytes())
    if out.tell() % 4:
        out.write(b"\0" * (4 - out.tell() % 4))
    return out.getvalue()


# ---- texture ----


def load_texture(path):
    """An RGBA image of an SVG, PNG, or JPEG file, at most MAX_TEXTURE
    pixels on its long side."""
    if path.lower().endswith(".svg"):
        # The size of the SVG, to keep its aspect.
        png = subprocess.run(["rsvg-convert", "-w", str(MAX_TEXTURE), "-a", path], capture_output=True, timeout=60, check=True).stdout
        im = Image.open(io.BytesIO(png))
        im.load()
        if im.width < im.height:
            png = subprocess.run(["rsvg-convert", "-h", str(MAX_TEXTURE), "-a", path], capture_output=True, timeout=60, check=True).stdout
            im = Image.open(io.BytesIO(png))
            im.load()
    else:
        im = Image.open(path)
        im.load()
    im = im.convert("RGBA")
    s = MAX_TEXTURE / max(im.width, im.height)
    if s < 1:
        im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    return im


def encode_texture(im):
    """An 8-bit palette PNG with alpha (color type 3, tRNS)."""
    p = im.quantize(colors=TEXTURE_COLORS, method=Image.Quantize.FASTOCTREE)
    out = io.BytesIO()
    p.save(out, format="PNG", optimize=True, bits=8)
    data = out.getvalue()
    # IHDR: bit depth 8, color type 3, no interlace (src/bed.zig reads this form and 8-bit gray, RGB, and RGBA).
    depth, ctype, interlace = data[24], data[25], data[28]
    if depth != 8 or interlace != 0:
        raise ValueError("png form %d %d %d" % (depth, ctype, interlace))
    return data


# ---- the set of files ----


def slug(text):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-") or "bed"


class Beds:
    def __init__(self, out_dir):
        self.out_dir = out_dir
        os.makedirs(out_dir, exist_ok=True)
        self.by_hash = {}  # content hash: file name
        self.names = set()
        self.cache = {}  # (kind, key): file name or None
        self.left_out = {}  # path: reason
        self.sizes = {}

    def _write(self, stem, ext, data):
        h = hashlib.sha1(data).hexdigest()
        if h in self.by_hash:
            return self.by_hash[h]
        name = slug(stem) + ext
        k = 2
        while name in self.names:
            name = "%s-%d%s" % (slug(stem), k, ext)
            k += 1
        self.names.add(name)
        self.by_hash[h] = name
        with open(os.path.join(self.out_dir, name), "wb") as fh:
            fh.write(data)
        self.sizes[name] = len(data)
        return name

    def blocked(self, src, path):
        for s, pattern, why in LEFT_OUT:
            if s == src and re.search(pattern, path.replace(os.sep, "/")):
                self.left_out[path] = why
                return True
        return False

    def mesh(self, key, stem, loader):
        """The file name of a mesh, or None. `loader` gives (tris, uv,
        offset); the offset goes to the record, so one file serves
        printers with other offsets."""
        if key in self.cache:
            return self.cache[key]
        try:
            tris, uv, off = loader()
            tris = tris[np.isfinite(tris).all(axis=(1, 2))]
            pos, uvs, idx = weld(tris, uv)
            idx = clean(idx)
            pos, uvs, idx = decimate(pos, uvs, idx, MAX_TRIANGLES)
            if len(idx) == 0:
                raise ValueError("empty")
            name = self._write(stem, ".mesh", encode_mesh(pos, uvs, idx))
            res = (name, off, uvs is not None)
        except Exception as e:  # untrusted files: skip a bad one
            warn("beds: skip mesh", key, e)
            res = None
        self.cache[key] = res
        return res

    def texture(self, src, path):
        if self.blocked(src, path):
            return None
        key = ("t", path)
        if key in self.cache:
            return self.cache[key]
        try:
            name = self._write(os.path.splitext(os.path.basename(path))[0], ".png", encode_texture(load_texture(path)))
        except Exception as e:
            warn("beds: skip texture", path, e)
            name = None
        self.cache[key] = name
        return name

    def add(self, bed):
        """The fields of a D line for a bed of a source, or None. `bed` has
        the source ("c", "p", "o", "l"), the mesh path, the texture path, and
        what the placement needs."""
        src = bed["src"]
        mesh_name, off, has_uv = None, (0.0, 0.0, 0.0), False
        mp = bed.get("mesh")
        if mp and os.path.isfile(mp) and not self.blocked(src, mp):
            stem = os.path.splitext(os.path.basename(mp))[0]
            if src in ("c", "l"):
                r = self.mesh(("c", mp), stem, lambda: place_cura(mp, None))
                if r:
                    o = bed.get("offset") or [0, 0, 0]
                    if isinstance(o, str):
                        o = [float(x) for x in o.split(",")]
                    off = (float(o[0]), -float(o[2]), float(o[1])) if len(o) == 3 else (0.0, 0.0, 0.0)
            elif src == "p":
                r = self.mesh(("p", mp), stem, lambda: place_prusa(mp))
                if r:
                    off = r[1]
            else:
                sm = bed.get("shape_max", (0, 0))
                r = self.mesh(("o", mp, sm if "bbl-3dp-" in mp else None), stem, lambda: place_orca(mp, sm))
                if r:
                    off = r[1]
            if r:
                mesh_name, has_uv = r[0], r[2]
        tex_name, rect = None, None
        tp = bed.get("texture")
        if tp and os.path.isfile(tp):
            if src in ("c", "l"):
                # Cura maps the texture with the UV coordinates of the mesh.
                if mesh_name and has_uv:
                    tex_name = self.texture(src, tp)
            else:
                tex_name = self.texture(src, tp)
                if tex_name:
                    rect = bed["rect"]
        if not mesh_name and not tex_name:
            return None
        return {"mesh": mesh_name or "", "texture": tex_name or "", "offset": off, "rect": rect, "src": src}
