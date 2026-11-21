#!/usr/bin/env python3
"""Makes the printer library of zslice (src/printers/library.txt).

The tool reads the printer definitions of three slicers and writes one
machine record for each printer model:

- Cura (https://github.com/Ultimaker/Cura, LGPL-3.0-or-later):
  resources/definitions/*.def.json and resources/extruders/*.def.json.
- PrusaSlicer (https://github.com/prusa3d/PrusaSlicer, AGPL-3.0): the vendor
  bundles in resources/profiles/*.ini.
- OrcaSlicer (https://github.com/SoftFever/OrcaSlicer, AGPL-3.0): the vendor
  profiles in resources/profiles/<vendor>.json and <vendor>/machine/*.json.
- Cura LulzBot Edition (https://github.com/lulzbot3d/CuraLE_Resources,
  LGPL-3.0): the LulzBot printers (TAZ Workhorse, TAZ Pro, Mini, ...), in
  the Cura format, with their bed plates. Optional (--curale). Its folders
  are definitions/, extruders/<printer>/, and meshes/: the tool reads them
  as a Cura tree.

Each source is a folder of untrusted data: the tool only reads JSON and INI
text from it, and runs no code from it. Run it with `python3 -I`:

    python3 -I tools/printer_library.py --cura <Cura> --prusa <PrusaSlicer> \
        --orca <OrcaSlicer> --beds src/printers/beds > src/printers/library.txt

Steps:

1. Read each source into records with the same fields (bed, nozzle, motion,
   firmware, G-code). Each source has its own inheritance: Cura `inherits`
   with `overrides`, PrusaSlicer `inherits = *a*; *b*` sections, and
   OrcaSlicer `inherits` by preset name.
2. Give each brand one name (for example "Creality3D" and "Creality" are
   the same brand), and find the same model in more than one source by a
   key of its brand and its name in lower case letters and digits.
3. Merge the records of one model. The order of the sources is OrcaSlicer,
   PrusaSlicer, Cura for each field. The vendor bundle of a brand comes
   first for its own printers (PrusaSlicer for Prusa, Cura for UltiMaker).
4. Read the retraction of the travels of each record (the z hop and its
   kind, the wipe, a retraction at each layer change, and the shortest
   travel that retracts), from the keys of the printer itself: not the
   defaults of the slicer (Cura fdmprinter, OrcaSlicer
   fdm_machine_common). A field that no record of a model has stays
   empty, and the model keeps the default of zslice.
5. Translate the simple G-code variables to the names of zslice, and put
   the values of the printer that zslice does not have (its model, its
   notes, its machine limits for Z and E) in place of their variables.
   The core runs the rest: the variables of each slicer and the scripts
   (`{if ...}`, expressions, see src/gcode_vars.zig). A record with no
   G-code gets the generic start G-code of zslice.
6. Write the library: the sources with their licenses, the G-code texts
   once each, the beds once each, and one line for each model, by brand.

With --beds <folder>, the tool also writes the bed models and the bed
textures of the printers into the folder (see tools/printer_beds.py), and
the library links them. The bed of a model comes from the first of its
records (in the order of step 3) that has one.

The format of the library is in the header comment of src/printers.zig.

References (see docs/references/printer-data.md): the Cura definition format, the
PrusaSlicer vendor bundle format, and the OrcaSlicer profile format.
"""

import argparse
import glob
import importlib.util
import json
import os
import re
import sys

# ---- brands ----

# Other spellings of a brand, in lower case, to the one name.
BRAND_ALIASES = {
    "creality3d": "Creality",
    "creality": "Creality",
    "lulzbot": "LulzBot",
    "prusaresearch": "Prusa",
    "prusa research": "Prusa",
    "prusa": "Prusa",
    "original prusa": "Prusa",
    "bbl": "Bambu Lab",
    "bambulab": "Bambu Lab",
    "bambu lab": "Bambu Lab",
    "ultimaker b.v.": "UltiMaker",
    "ultimaker": "UltiMaker",
    "ultimaker bv": "UltiMaker",
    "anycubic": "Anycubic",
    "flsun": "FLSun",
    "qidi": "QIDI",
    "qiditechnology": "QIDI",
    "qidi tech": "QIDI",
    "qidi technology": "QIDI",
    "voron": "Voron",
    "voron design": "Voron",
    "ratrig": "RatRig",
    "rat rig": "RatRig",
    "biqu": "BIQU",
    "elegoo": "Elegoo",
    "artillery": "Artillery",
    "flashforge": "Flashforge",
    "flying bear": "FlyingBear",
    "flyingbear": "FlyingBear",
    "two trees": "Two Trees",
    "twotrees": "Two Trees",
    "sovol": "Sovol",
    "kingroon": "Kingroon",
    "tronxy": "Tronxy",
    "snapmaker": "Snapmaker",
    "geeetech": "Geeetech",
    "anker": "Anker",
    "ankermake": "Anker",
    "infimech": "InfiMech",
    "wanhao": "Wanhao",
    "folgertech": "Folger Tech",
    "folger tech": "Folger Tech",
    "felix printers": "FELIXprinters",
    "felixprinters": "FELIXprinters",
    "makergear": "MakerGear",
    "jgaurora": "JGAurora",
    "co print": "Co Print",
    "trimaker": "Trimaker",
    "xyzprinting": "XYZprinting",
    "imade3d": "IMADE3D",
    "hartsmartproducts": "Hart Smart Products",
    "gcreate": "gCreate",
    "longer": "LONGER",
    "longer3d": "LONGER",
    "construct3d": "CONSTRUCT3D",
    "deltamaker": "DeltaMaker",
    "magicmaker": "MagicMaker",
    "ginger additive": "Ginger Additive",
    "ideaformer": "IdeaFormer",
    "iq": "iQ",
    "lh": "LH",
    "volumic": "Volumic",
    "vzbot": "Vzbot",
    "sovol 3d": "Sovol",
    "vorondesign": "Voron",
    "prusa3d": "Prusa",
    "z-bolt co.": "Z-Bolt",
    "z-bolt co": "Z-Bolt",
    "inat": "INAT",
    "felix": "FELIXprinters",
    "hartsmart products": "Hart Smart Products",
    "weedo": "WEEDO",
    "goofoo": "Goofoo",
    # The maker of LulzBot printers since 2019.
    "fargo additive manufacturing equipment 3d": "LulzBot",
}

# Brands of no real maker, and test printers, that the library leaves out.
SKIP_BRANDS = {"orca arena printer", "custom", "generic", "other", "unknown", "orcafilamentlibrary", "templates", "?", ""}

# The flavors of firmware that zslice writes G-code for. Others (x3g files,
# volumetric extrusion, CNC dialects) are left out.
FLAVOR_OK = {
    # Cura
    "RepRap (Marlin/Sprinter)": ("marlin", "Marlin"),
    "Marlin": ("marlin", "Marlin"),
    "RepRap (RepRap)": ("marlin", "RepRapFirmware"),
    "Repetier": ("marlin", "Repetier"),
    "Cheetah": ("marlin", "Cheetah"),
    # PrusaSlicer and OrcaSlicer
    "marlin": ("marlin", "Marlin"),
    "marlin2": ("marlin", "Marlin 2"),
    "marlinlegacy": ("marlin", "Marlin"),
    "marlinfirmware": ("marlin", "Marlin"),
    "reprap": ("marlin", "RepRapFirmware"),
    "reprapfirmware": ("marlin", "RepRapFirmware"),
    "repetier": ("marlin", "Repetier"),
    "smoothie": ("marlin", "Smoothieware"),
    "sprinter": ("marlin", "Sprinter"),
    "teacup": ("marlin", "Teacup"),
    "klipper": ("klipper", "Klipper"),
}

SOURCES = {
    "c": ("Cura", "LGPL-3.0-or-later", "https://github.com/Ultimaker/Cura"),
    "p": ("PrusaSlicer", "AGPL-3.0", "https://github.com/prusa3d/PrusaSlicer"),
    "o": ("OrcaSlicer", "AGPL-3.0", "https://github.com/SoftFever/OrcaSlicer"),
    "l": ("Cura LulzBot Edition", "LGPL-3.0", "https://github.com/lulzbot3d/CuraLE_Resources"),
}


def warn(*a):
    print(*a, file=sys.stderr)


# Company suffixes that a brand name drops.
COMPANY = re.compile(r"[\s,]+(co\.?,?\s*ltd\.?|ltd\.?|llc\.?|inc\.?|gmbh|s\.r\.o\.|n\.v\.|b\.v\.|bv|sp\. z o\.o\.|3dp design|3d printers)$", re.I)


def brand_name(raw):
    raw = (raw or "").strip()
    key = raw.lower()
    if key in BRAND_ALIASES:
        return BRAND_ALIASES[key]
    while True:
        cut = COMPANY.sub("", raw).strip(" ,")
        if cut == raw:
            break
        raw = cut
    key = raw.lower()
    if key in BRAND_ALIASES:
        return BRAND_ALIASES[key]
    return raw


def norm(text):
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def model_name(brand, name):
    """The model name without the brand at its start."""
    # PrusaSlicer writes "&&" for "&" (a menu escape).
    name = name.strip().replace("&&", "&")
    full = re.sub(r"\s+", " ", name)
    for prefix in sorted({brand, brand.replace(" ", ""), "Original Prusa", "Prusa", "Creality3D", "Bambu Lab", "UltiMaker", "Ultimaker", "Lulzbot", "LulzBot", "QIDI Tech", "Qidi", "QIDI", "FLSun", "Flsun", "Anker", "AnkerMake", "Voron Design", "RatRig", "Rat Rig"}, key=len, reverse=True):
        if prefix and name.lower().startswith(prefix.lower() + " "):
            if norm(prefix) == norm(brand) or norm(brand) in (norm(prefix), "prusa", "bambulab", "ultimaker", "qidi", "flsun", "anker", "voron", "ratrig"):
                name = name[len(prefix):].strip()
                break
    name = re.sub(r"\s+", " ", name).strip(" -_") or name
    # A name that starts with a digit keeps the brand: "Voron 2.4 350".
    if name[:1].isdigit():
        return full
    return name



def series_of(model, family=""):
    """A short series name for grouping: the family of the vendor bundle,
    or the leading word of the model."""
    if family and norm(family) not in ("", "fff", "printer", "printers") and "legacy" not in family.lower():
        return family.strip()
    m = re.match(r"([A-Za-z]+)[\s\-]?", model)
    if m and len(m.group(1)) >= 2:
        return m.group(1)
    return model.split(" ")[0]


def num(v, default=None):
    if v is None:
        return default
    if isinstance(v, (list, tuple)):
        v = v[0] if v else None
        if v is None:
            return default
    if isinstance(v, bool):
        return default
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().split(";")[0].split(",")[0].strip()
    if s.endswith("%"):
        return default
    try:
        return float(s)
    except ValueError:
        return default


def boolean(v, default=None):
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if s in ("true", "1", "yes"):
        return True
    if s in ("false", "0", "no"):
        return False
    return default


# The fields of the retraction of the travels of a record (see
# src/printers.zig, Travel): the z hop (mm), "c" if it lifts only for a
# travel that crosses an edge or "a" for each retraction, the wipe, the
# wipe length (mm), a retraction at each layer change, and the shortest
# travel that retracts (mm). None: the source does not tell it.
TRAVEL = ("z_hop", "hop", "wipe", "wipe_distance", "layer_change", "min_travel")


def travel_orca(v, own):
    """The retraction of the travels of an OrcaSlicer (or Bambu Studio)
    preset `v`, from the keys in `own` only. z_hop_types "Auto Lift"
    lifts the travels that leave the part; the other types lift each
    retraction."""
    def get(key):
        return v.get(key) if key in own else None

    t = {
        "z_hop": num(get("z_hop")),
        "hop": None,
        "wipe": boolean(first_value(get("wipe"))),
        "wipe_distance": num(get("wipe_distance")),
        "layer_change": boolean(first_value(get("retract_when_changing_layer"))),
        "min_travel": num(get("retraction_minimum_travel")),
    }
    kind = first_value(get("z_hop_types"))
    if kind:
        t["hop"] = "c" if str(kind) == "Auto Lift" else "a"
    return t


def travel_prusa(v):
    """The retraction of the travels of a PrusaSlicer printer preset. A
    PrusaSlicer lift (retract_lift) goes with each retraction."""
    lift = num(v.get("retract_lift"))
    return {
        "z_hop": lift,
        "hop": "a" if lift else None,
        "wipe": boolean(first_value(v.get("wipe"))),
        "wipe_distance": None,
        "layer_change": boolean(first_value(v.get("retract_layer_change"))),
        "min_travel": num(v.get("retract_before_travel")),
    }


def travel_cura(vals, own):
    """The retraction of the travels of a Cura definition, from the keys
    of the definition only (`own`). Cura has no wipe at a retraction."""
    def get(key):
        return vals.get(key) if key in own else None

    t = dict.fromkeys(TRAVEL)
    enabled = boolean(get("retraction_hop_enabled"))
    hop = num(get("retraction_hop"))
    if enabled is False:
        t["z_hop"] = 0.0
    elif enabled and hop is not None:
        t["z_hop"] = hop
    elif enabled:
        t["z_hop"] = num(vals.get("retraction_hop"))
    only = boolean(get("retraction_hop_only_when_collides"))
    if only is not None:
        t["hop"] = "c" if only else "a"
    t["layer_change"] = boolean(get("retract_at_layer_change"))
    t["min_travel"] = num(get("retraction_min_travel"))
    return t


def first_value(v):
    """The first value of a list (a value for each extruder), or v."""
    if isinstance(v, (list, tuple)):
        return v[0] if v else None
    if isinstance(v, str) and "," in v:
        return v.split(",")[0]
    return v


def travel_fields(m):
    t = m.get("travel") or {}

    def flag(v):
        return "" if v is None else "1" if v else "0"

    return [fmt(t.get("z_hop")), t.get("hop") or "", flag(t.get("wipe")), fmt(t.get("wipe_distance")), flag(t.get("layer_change")), fmt(t.get("min_travel"))]


def bed_from_polygon(points):
    """Bed size, origin, and shape from a list of "XxY" points."""
    xs, ys = [], []
    for p in points:
        p = p.strip()
        if not p:
            continue
        a = p.split("x")
        if len(a) != 2:
            return None
        try:
            xs.append(float(a[0]))
            ys.append(float(a[1]))
        except ValueError:
            return None
    if len(xs) < 3:
        return None
    w = max(xs) - min(xs)
    d = max(ys) - min(ys)
    shape = "round" if len(xs) > 8 else "rectangle"
    return {"bed_x": w, "bed_y": d, "origin_x": min(xs), "origin_y": min(ys), "shape": shape}


# ---- G-code ----

# Variables of the sources and their zslice names.
VARS = {
    # zslice
    "nozzle_temp": "nozzle_temp",
    "first_layer_nozzle_temp": "first_layer_nozzle_temp",
    "bed_temp": "bed_temp",
    "standby_temp": "standby_temp",
    "layer_height": "layer_height",
    "first_layer_height": "first_layer_height",
    "first_layer_speed": "first_layer_speed",
    "nozzle_diameter": "nozzle_diameter",
    "filament_diameter": "filament_diameter",
    "filament_name": "filament_name",
    "machine_name": "machine_name",
    "job_name": "job_name",
    # Cura
    "material_print_temperature": "nozzle_temp",
    "material_print_temperature_layer_0": "first_layer_nozzle_temp",
    "material_initial_print_temperature": "first_layer_nozzle_temp",
    "material_bed_temperature": "bed_temp",
    "material_bed_temperature_layer_0": "bed_temp",
    "material_standby_temperature": "standby_temp",
    "layer_height_0": "first_layer_height",
    "speed_layer_0": "first_layer_speed",
    "machine_nozzle_size": "nozzle_diameter",
    "material_diameter": "filament_diameter",
    "material_name": "filament_name",
    "jobname": "job_name",
    "print_temperature": "nozzle_temp",
    "print_bed_temperature": "bed_temp",
    # PrusaSlicer and OrcaSlicer
    "temperature": "nozzle_temp",
    "first_layer_temperature": "first_layer_nozzle_temp",
    "nozzle_temperature": "nozzle_temp",
    "nozzle_temperature_initial_layer": "first_layer_nozzle_temp",
    "bed_temperature": "bed_temp",
    "first_layer_bed_temperature": "bed_temp",
    "bed_temperature_initial_layer": "bed_temp",
    "bed_temperature_initial_layer_single": "bed_temp",
    "hot_plate_temp": "bed_temp",
    "hot_plate_temp_initial_layer": "bed_temp",
    "initial_layer_print_height": "first_layer_height",
    "filament_settings_id": "filament_name",
    "printer_preset": "machine_name",
    "printer_settings_id": "machine_name",
    "input_filename_base": "job_name",
}

INDEX = r"(?:\[(?:\d+|initial_extruder|initial_tool|current_extruder|initial_extruder_nr|initial_no_support_extruder|0)\])?"


def translate_gcode(text, consts):
    """The text with the simple variables in the names of zslice, and the
    values of `consts` in place of their variables. The core (see
    src/gcode_vars.zig) fills in the other variables and runs the scripts
    (`{if ...}`, expressions). `consts` has the values of the printer that
    zslice does not have (the printer model, the bed size of Cura), as a
    list of texts or numbers for each name."""
    if isinstance(text, list):
        text = text[0] if text else None
    if not isinstance(text, str) or not text.strip():
        return None
    out = text.replace("\r\n", "\n").replace("\r", "\n")

    def var(name):
        if name in VARS:
            return "{" + VARS[name] + "}"
        return None

    def brace(m):
        name = m.group(1)
        v = var(name)
        return v if v is not None else m.group(0)

    # Cura: {name}, {name, 0}, {name, initial_extruder_nr}.
    out = re.sub(r"\{([a-z_0-9]+)(?:\s*,\s*[a-z_0-9]+)?\}", brace, out)
    # PrusaSlicer and OrcaSlicer: {name[0]}, [name], [name_0].
    out = re.sub(r"\{([a-z_0-9]+)" + INDEX + r"\}", brace, out)
    out = re.sub(r"\[([a-z_][a-z_0-9]*)" + INDEX + r"\]", brace, out)
    out = re.sub(r"\[([a-z_][a-z_0-9]*?)_0\]", brace, out)
    if consts:
        out = put_consts(out, consts)
    return out.strip("\n")


def put_consts(text, consts):
    """Puts the values of `consts` in place of their variables: in a
    [name] or a {name}, as the value; in an expression, as a number or a
    text in quotes. An index of a number picks the value of a list; other
    indexes pick the first."""
    def value(name, index):
        vs = consts[name]
        if not isinstance(vs, list):
            vs = [vs]
        if not vs:
            return None
        i = int(index) if index is not None and index.isdigit() else 0
        return vs[i] if i < len(vs) else vs[0]

    def plain(v):
        return fmt(v) if isinstance(v, (int, float)) else str(v)

    def lit(v):
        if isinstance(v, (int, float)):
            return fmt(v)
        try:
            return fmt(float(v))
        except ValueError:
            return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'

    names = "|".join(sorted((re.escape(n) for n in consts), key=len, reverse=True))
    whole = re.compile(r"([\[{])(" + names + r")(?:\[([^\]\[]*)\])?([\]}])")

    def sub_whole(m):
        if (m.group(1) == "[") != (m.group(4) == "]"):
            return m.group(0)
        v = value(m.group(2), m.group(3))
        return m.group(0) if v is None else plain(v)

    text = whole.sub(sub_whole, text)
    inner = re.compile(r"(?<![\w.])(" + names + r")(?:\[([^\]\[]*)\])?(?![\w(])")

    def sub_block(m):
        body = m.group(0)
        return inner.sub(lambda k: lit(value(k.group(1), k.group(2))) if value(k.group(1), k.group(2)) is not None else k.group(0), body)

    return re.sub(r"\{[^{}]*\}", sub_block, text)


# The values of a printer that the core does not have, by the names of
# PrusaSlicer and OrcaSlicer. A printer checks its model (M862.3 P "MK4").
PRINTER_CONSTS = [
    "printer_model", "printer_notes", "printer_variant",
    "retract_length_toolchange", "parking_pos_retraction", "extra_loading_move",
    "machine_max_acceleration_retracting", "machine_max_acceleration_z",
    "machine_max_acceleration_e", "machine_max_speed_e", "machine_max_feedrate_e",
    "machine_max_jerk_z", "machine_max_jerk_e",
]


def printer_consts(v, ini=False):
    """The PRINTER_CONSTS of a printer preset `v` (an INI section of
    PrusaSlicer, or a JSON machine of OrcaSlicer)."""
    out = {}
    for k in PRINTER_CONSTS:
        x = v.get(k)
        if x is None:
            continue
        if ini:
            x = ini_text(x)
            vals = [t for t in x.split(",")] if k != "printer_notes" and k != "printer_model" and k != "printer_variant" else [x]
        else:
            vals = x if isinstance(x, list) else [x]
        vals = [num(t) if num(t) is not None else str(t) for t in vals]
        if vals and vals != [""]:
            out[k] = vals
    return out


def fmt(v):
    if v is None:
        return ""
    if abs(v - round(v)) < 1e-9:
        return str(int(round(v)))
    return ("%.4f" % v).rstrip("0").rstrip(".")


def heats(text):
    """True if a start G-code sets the temperatures itself."""
    return bool(re.search(r"\{(nozzle_temp|first_layer_nozzle_temp)\}", text)) or bool(re.search(r"^\s*M10[49]\b", text, re.M))


def bed_heats(text):
    return "{bed_temp}" in text or bool(re.search(r"^\s*M1[49]0\b", text, re.M))


# ---- Cura ----


def cura_defaults(tree, out):
    for key, node in tree.items():
        if not isinstance(node, dict):
            continue
        if "default_value" in node:
            out[key] = node["default_value"]
        if "children" in node:
            cura_defaults(node["children"], out)


def nozzle_of(src, title, evals, vals):
    """The nozzle of a Cura record. The tool heads of Cura LulzBot Edition
    inherit a generic extruder of 0.4 mm; the size is in the name ("SE 0.5
    mm"), and the name wins."""
    n = num(evals.get("machine_nozzle_size"), num(vals.get("machine_nozzle_size"), 0.4))
    if src == "l":
        m = re.search(r"(\d+(?:\.\d+)?) mm", title)
        if m and 0.1 <= float(m.group(1)) <= 2:
            n = float(m.group(1))
    return n


def read_cura(root, src="c", flat=False):
    """The records of a Cura tree: resources/definitions, resources/extruders
    and resources/meshes, or with `flat` (Cura LulzBot Edition) definitions,
    extruders/<printer>/ and meshes at the top."""
    res = root if flat else os.path.join(root, "resources")
    defs_dir = os.path.join(res, "definitions")
    ext_dir = os.path.join(res, "extruders")
    defs = {}
    for f in glob.glob(os.path.join(defs_dir, "*.def.json")):
        with open(f, encoding="utf-8") as fh:
            defs[os.path.basename(f)[: -len(".def.json")]] = json.load(fh)
    exts = {}
    for f in glob.glob(os.path.join(ext_dir, "*.def.json")) + glob.glob(os.path.join(ext_dir, "*", "*.def.json")):
        with open(f, encoding="utf-8") as fh:
            exts[os.path.basename(f)[: -len(".def.json")]] = json.load(fh)
    base = {}
    cura_defaults(defs["fdmprinter"].get("settings", {}), base)
    ext_base = {}
    if "fdmextruder" in defs:
        cura_defaults(defs["fdmextruder"].get("settings", {}), ext_base)

    def chain(table, name):
        out = []
        seen = set()
        while name and name in table and name not in seen:
            seen.add(name)
            out.append(table[name])
            name = table[name].get("inherits")
        return out

    def value(node):
        if not isinstance(node, dict):
            return None
        if "default_value" in node:
            return node["default_value"]
        v = node.get("value")
        if isinstance(v, (int, float, bool)):
            return v
        if isinstance(v, str):
            s = v.strip()
            if re.fullmatch(r"-?\d+(\.\d+)?", s):
                return float(s)
            if s in ("True", "False"):
                return s == "True"
            if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"" and s[0] not in s[1:-1]:
                return s[1:-1]
        return None

    records = []
    for name, d in defs.items():
        ch = chain(defs, name)
        meta = {}
        for c in reversed(ch):
            meta.update(c.get("metadata", {}))
        if not meta.get("visible", True) or name in ("fdmprinter", "fdmextruder"):
            continue
        if not d.get("inherits"):
            continue
        vals = dict(base)
        for c in reversed(ch):
            for k, node in c.get("overrides", {}).items():
                v = value(node)
                if v is not None:
                    vals[k] = v
        # The first extruder.
        trains = meta.get("machine_extruder_trains", {})
        ext = trains.get("0") or trains.get(0)
        evals = dict(ext_base)
        if ext:
            for c in reversed(chain(exts, ext)):
                for k, node in c.get("overrides", {}).items():
                    v = value(node)
                    if v is not None:
                        evals[k] = v
        brand = brand_name(meta.get("manufacturer", ""))
        if brand.lower() in SKIP_BRANDS:
            continue
        flavor = str(vals.get("machine_gcode_flavor", "RepRap (Marlin/Sprinter)")).strip()
        if flavor not in FLAVOR_OK:
            warn("cura: skip", name, "flavor", flavor)
            continue
        w = num(vals.get("machine_width"), 0)
        dd = num(vals.get("machine_depth"), 0)
        h = num(vals.get("machine_height"), 0)
        if not (w > 0 and dd > 0 and h > 0):
            continue
        shape = "round" if str(vals.get("machine_shape", "rectangular")) == "elliptic" else "rectangle"
        center = boolean(vals.get("machine_center_is_zero"), False) or shape == "round"
        consts = {"machine_width": w, "machine_depth": dd, "machine_height": h}
        start = translate_gcode(vals.get("machine_start_gcode"), consts)
        if start is not None:
            # CuraEngine heats the bed and the nozzle before a start G-code
            # that does not.
            pre = []
            heated = boolean(vals.get("machine_heated_bed"), False)
            if heated and not bed_heats(start):
                pre.append("M190 S{bed_temp}")
            if not heats(start):
                pre.append("M109 S{first_layer_nozzle_temp}")
            if pre:
                start = "\n".join(pre) + "\n" + start
        end = translate_gcode(vals.get("machine_end_gcode"), consts)
        bed = None
        if meta.get("platform") or meta.get("platform_texture"):
            bed = {
                "src": src,
                "mesh": os.path.join(res, "meshes", meta["platform"]) if meta.get("platform") else None,
                "offset": meta.get("platform_offset"),
                "texture": os.path.join(res, "images", meta["platform_texture"]) if meta.get("platform_texture") else None,
            }
        display = str(vals.get("machine_name") or d.get("name") or name)
        if display.lower() in ("unknown", ""):
            display = d.get("name", name)
        title = d.get("name", display)
        if src == "l":
            # Cura LulzBot Edition: "Workhorse | SE | 0.50 mm" is the TAZ
            # Workhorse SE 0.5 mm, as LulzBot names it.
            title = re.sub(r"\s*\|\s*", " ", title).strip()
            title = re.sub(r"(\d+\.\d*?)0+ mm", lambda mm: mm.group(1).rstrip(".") + " mm", title)
            if title.startswith("Workhorse"):
                title = "TAZ " + title
        rec = {
            "src": src,
            "id": name,
            "brand": brand,
            "name": model_name(brand, title),
            "family": "",
            "bed_x": w,
            "bed_y": dd,
            "height": h,
            "origin_x": -w / 2 if center else 0,
            "origin_y": -dd / 2 if center else 0,
            "shape": shape,
            "nozzle": nozzle_of(src, title, evals, vals),
            "nozzles": [],
            "filament": num(evals.get("material_diameter"), num(vals.get("material_diameter"), 2.85)),
            "heated_bed": boolean(vals.get("machine_heated_bed"), False),
            "heated_chamber": boolean(vals.get("machine_heated_build_volume"), False),
            "max_speed": min(num(vals.get("machine_max_feedrate_x"), 0) or 0, num(vals.get("machine_max_feedrate_y"), 0) or 0) or None,
            "max_z_speed": num(vals.get("machine_max_feedrate_z")),
            "max_accel": num(vals.get("machine_acceleration")) if "machine_acceleration" in vals else None,
            "corner": num(vals.get("machine_max_jerk_xy")),
            "flavor": FLAVOR_OK[flavor],
            "kinematics": "delta" if shape == "round" else "",
            "retract": num(vals.get("retraction_amount")),
            "retract_speed": num(vals.get("retraction_speed")),
            "start": start,
            "end": end,
            "extruders": int(num(vals.get("machine_extruder_count"), 1) or 1),
            "bed": bed,
        }
        # Cura's own default motion values (fdmprinter) say nothing of a
        # printer: keep only the values of a definition.
        own = set()
        for c in ch:
            if c is defs.get("fdmprinter"):
                continue
            own.update(c.get("overrides", {}).keys())
        if "machine_start_gcode" not in own:
            rec["start"] = None
        if "machine_end_gcode" not in own:
            rec["end"] = None
        for key, ck in (("max_speed", "machine_max_feedrate_x"), ("max_z_speed", "machine_max_feedrate_z"), ("max_accel", "machine_acceleration"), ("corner", "machine_max_jerk_xy"), ("retract", "retraction_amount"), ("retract_speed", "retraction_speed")):
            if ck not in own:
                rec[key] = None
        rec["travel"] = travel_cura(vals, own)
        records.append(rec)
    return records


# ---- PrusaSlicer ----


def read_ini(path):
    sections = []
    cur = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("[") and line.rstrip().endswith("]"):
                cur = (line.strip()[1:-1], {})
                sections.append(cur)
            elif cur is not None and "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                cur[1][k.strip()] = v.strip()
            elif cur is None and "=" in line:
                k, v = line.split("=", 1)
                sections.append(("vendor", {k.strip(): v.strip()}))
    return sections


def ini_text(v):
    if v is None:
        return None
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    return v.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")


def read_prusa(root):
    records = []
    for path in sorted(glob.glob(os.path.join(root, "resources", "profiles", "*.ini"))):
        vendor_key = os.path.basename(path)[:-4]
        secs = read_ini(path)
        vendor = {}
        for name, kv in secs:
            if name == "vendor":
                vendor.update(kv)
        printers = {}
        models = {}
        filaments = {}
        for name, kv in secs:
            if name.startswith("printer:"):
                printers[name[len("printer:"):]] = kv
            elif name.startswith("printer_model:"):
                models[name[len("printer_model:"):]] = kv
            elif name.startswith("filament:"):
                filaments[name[len("filament:"):]] = kv
        vendor_name = vendor.get("full_name") or vendor.get("name") or vendor_key
        brand = brand_name(vendor.get("name") or vendor_key)

        def resolve(table, name, depth=0):
            kv = table.get(name)
            if kv is None or depth > 20:
                return {}
            out = {}
            parents = [p.strip() for p in kv.get("inherits", "").split(";") if p.strip()]
            for p in parents:
                out.update(resolve(table, p, depth + 1))
            out.update(kv)
            return out

        by_model = {}
        for pname in printers:
            if pname.startswith("*"):
                continue
            v = resolve(printers, pname)
            model = v.get("printer_model", "")
            if not model or v.get("printer_technology", "FFF") != "FFF":
                continue
            by_model.setdefault(model, []).append((pname, v))
        for model, presets in by_model.items():
            meta = models.get(model, {})
            if meta.get("technology", "FFF") != "FFF":
                continue
            variants = [x.strip() for x in meta.get("variants", "").split(";") if x.strip()]

            def rank(item):
                v = item[1]
                var = v.get("printer_variant", "")
                return (0 if var == "0.4" else 1 if var == (variants[0] if variants else "") else 2, len(item[0]))

            pname, v = sorted(presets, key=rank)[0]
            flavor = v.get("gcode_flavor", "marlin")
            if flavor not in FLAVOR_OK:
                warn("prusa: skip", pname, "flavor", flavor)
                continue
            bed = bed_from_polygon(v.get("bed_shape", "").split(","))
            h = num(v.get("max_print_height"), 0)
            if not bed or not h:
                continue
            consts = printer_consts(v, ini=True)
            start = translate_gcode(ini_text(v.get("start_gcode")), consts)
            end = translate_gcode(ini_text(v.get("end_gcode")), consts)
            fil = None
            dfp = ini_text(v.get("default_filament_profile", "")) or ""
            if dfp:
                fv = resolve(filaments, dfp.split(";")[0].strip())
                fil = num(fv.get("filament_diameter"))
            name = meta.get("name") or pname
            bed_files = None
            if meta.get("bed_model") or meta.get("bed_texture"):
                vdir = os.path.join(root, "resources", "profiles", vendor_key)
                hw, hd = bed["bed_x"] / 2, bed["bed_y"] / 2
                bed_files = {
                    "src": "p",
                    "mesh": os.path.join(vdir, meta["bed_model"]) if meta.get("bed_model") else None,
                    "texture": os.path.join(vdir, meta["bed_texture"]) if meta.get("bed_texture") else None,
                    # PrusaSlicer stretches the texture over the box of the bed shape.
                    "rect": (-hw, -hd, hw, hd),
                }
            acc = num(v.get("machine_max_acceleration_extruding")) or num(v.get("machine_max_acceleration_x"))
            if v.get("machine_limits_usage") in ("ignore",):
                acc = None
            records.append({
                "src": "p",
                "id": vendor_key + "/" + model,
                "brand": brand,
                "name": model_name(brand, name),
                "family": meta.get("family", ""),
                "bed_x": bed["bed_x"],
                "bed_y": bed["bed_y"],
                "height": h,
                "origin_x": bed["origin_x"],
                "origin_y": bed["origin_y"],
                "shape": bed["shape"],
                "nozzle": num(v.get("nozzle_diameter"), 0.4),
                "nozzles": [num(x) for x in variants if num(x)],
                "filament": fil,
                "heated_bed": True,
                "heated_chamber": False,
                "max_speed": min(num(v.get("machine_max_feedrate_x"), 0) or 0, num(v.get("machine_max_feedrate_y"), 0) or 0) or None,
                "max_z_speed": num(v.get("machine_max_feedrate_z")),
                "max_accel": acc,
                "corner": num(v.get("machine_max_jerk_x")),
                "flavor": FLAVOR_OK[flavor],
                "kinematics": "delta" if bed["shape"] == "round" else "",
                "retract": num(v.get("retract_length")),
                "retract_speed": num(v.get("retract_speed")),
                "travel": travel_prusa(v),
                "start": start,
                "end": end,
                "extruders": len((v.get("nozzle_diameter") or "0.4").split(",")),
                "bed": bed_files,
            })
    return records


# ---- OrcaSlicer ----


def read_orca(root):
    records = []
    prof = os.path.join(root, "resources", "profiles")
    for vpath in sorted(glob.glob(os.path.join(prof, "*.json"))):
        vendor_key = os.path.basename(vpath)[:-5]
        vdir = os.path.join(prof, vendor_key)
        if not os.path.isdir(os.path.join(vdir, "machine")):
            continue
        if vendor_key.lower() in SKIP_BRANDS:
            continue
        with open(vpath, encoding="utf-8") as fh:
            try:
                vendor = json.load(fh)
            except ValueError:
                continue
        by_name = {}
        for f in glob.glob(os.path.join(vdir, "machine", "**", "*.json"), recursive=True):
            try:
                with open(f, encoding="utf-8") as fh:
                    d = json.load(fh)
            except ValueError:
                continue
            if isinstance(d, dict) and "name" in d:
                by_name[d["name"]] = d
        fil_by_name = {}
        for f in glob.glob(os.path.join(vdir, "filament", "**", "*.json"), recursive=True):
            try:
                with open(f, encoding="utf-8") as fh:
                    d = json.load(fh)
            except ValueError:
                continue
            if isinstance(d, dict) and "name" in d:
                fil_by_name[d["name"]] = d

        def resolve(table, name, depth=0):
            d = table.get(name)
            if d is None or depth > 20:
                return {}
            out = resolve(table, d.get("inherits", ""), depth + 1) if d.get("inherits") else {}
            for k, v in d.items():
                # The G-code of fdm_machine_common is a placeholder of
                # OrcaSlicer, with fixed temperatures: no printer uses it.
                if d["name"] == "fdm_machine_common" and k in ("machine_start_gcode", "machine_end_gcode"):
                    continue
                out[k] = v
            return out

        def own_keys(table, name, depth=0):
            """The keys that a preset and its parents set, without the
            defaults of OrcaSlicer (fdm_machine_common)."""
            d = table.get(name)
            if d is None or depth > 20:
                return set()
            out = own_keys(table, d.get("inherits", ""), depth + 1) if d.get("inherits") else set()
            if d["name"] != "fdm_machine_common":
                out.update(d.keys())
            return out

        models = {d["name"]: d for d in by_name.values() if d.get("type") == "machine_model"}
        presets = {}
        for d in by_name.values():
            if d.get("type") != "machine" or str(d.get("instantiation", "")).lower() != "true":
                continue
            v = resolve(by_name, d["name"])
            v["__own"] = own_keys(by_name, d["name"])
            # Newer OrcaSlicer profiles keep a G-code in its own preset:
            # "<preset name> template machine_start_gcode".
            for k in ("machine_start_gcode", "machine_end_gcode"):
                t = by_name.get("%s template %s" % (d["name"], k))
                if t and t.get(k):
                    v[k] = t[k]
            pm = v.get("printer_model", "")
            if pm:
                presets.setdefault(pm, []).append(v)
        for mname, model in models.items():
            if model.get("machine_tech", "FFF") != "FFF" or mname not in presets:
                continue
            vs = presets[mname]
            vs.sort(key=lambda v: (0 if str(v.get("printer_variant", "")) == "0.4" else 1, v.get("name", "")))
            v = vs[0]
            flavor = str(v.get("gcode_flavor", "marlin"))
            if flavor not in FLAVOR_OK:
                warn("orca: skip", mname, "flavor", flavor)
                continue
            area = v.get("printable_area")
            bed = bed_from_polygon(area if isinstance(area, list) else str(area or "").split(","))
            h = num(v.get("printable_height"), 0)
            if not bed or not h:
                continue
            consts = printer_consts(v)
            start = translate_gcode(v.get("machine_start_gcode"), consts)
            end = translate_gcode(v.get("machine_end_gcode"), consts)
            fil = None
            mats = [m.strip() for m in str(model.get("default_materials", "")).split(";") if m.strip()]
            if mats:
                fv = resolve(fil_by_name, mats[0])
                fil = num(fv.get("filament_diameter"))
            brand = brand_name(vendor.get("name") or vendor_key)
            nozzles = [num(x) for x in str(model.get("nozzle_diameter", "")).split(";") if num(x)]
            structure = str(v.get("printer_structure", "") or "")
            bed_files = None
            if model.get("bed_model") or model.get("bed_texture"):
                hw, hd = bed["bed_x"] / 2, bed["bed_y"] / 2
                pts = area if isinstance(area, list) else str(area or "").split(",")
                try:
                    far = tuple(float(x) for x in str(pts[2]).split("x"))
                except (IndexError, ValueError):
                    far = (bed["bed_x"], bed["bed_y"])
                bed_files = {
                    "src": "o",
                    "mesh": os.path.join(vdir, model["bed_model"]) if model.get("bed_model") else None,
                    "texture": os.path.join(vdir, model["bed_texture"]) if model.get("bed_texture") else None,
                    # OrcaSlicer stretches the texture over the box of the
                    # printable area; for Bambu Lab printers the box goes
                    # 12 mm more to the front (PartPlate::generate_logo_polygon).
                    "rect": (-hw, -hd - (12 if vendor_key == "BBL" else 0), hw, hd),
                    "shape_max": far,
                }
            records.append({
                "src": "o",
                "id": vendor_key + "/" + mname,
                "brand": brand,
                "name": model_name(brand, mname),
                "family": "",
                "bed_x": bed["bed_x"],
                "bed_y": bed["bed_y"],
                "height": h,
                "origin_x": bed["origin_x"],
                "origin_y": bed["origin_y"],
                "shape": bed["shape"],
                "nozzle": num(v.get("nozzle_diameter"), 0.4),
                "nozzles": nozzles,
                "filament": fil,
                "heated_bed": True,
                "heated_chamber": boolean(v.get("support_chamber_temp_control"), False) or False,
                "max_speed": min(num(v.get("machine_max_speed_x"), 0) or 0, num(v.get("machine_max_speed_y"), 0) or 0) or None,
                "max_z_speed": num(v.get("machine_max_speed_z")),
                "max_accel": num(v.get("machine_max_acceleration_extruding")) or num(v.get("machine_max_acceleration_x")),
                "corner": num(v.get("machine_max_jerk_x")),
                "flavor": FLAVOR_OK[flavor],
                "kinematics": structure if structure not in ("undefine", "") else ("delta" if bed["shape"] == "round" else ""),
                "retract": num(v.get("retraction_length")),
                "retract_speed": num(v.get("retraction_speed")),
                "travel": travel_orca(v, v["__own"]),
                "start": start,
                "end": end,
                "extruders": len(v.get("nozzle_diameter") or [0.4]) if isinstance(v.get("nozzle_diameter"), list) else 1,
                "bed": bed_files,
            })
    return records


# ---- merge ----

ORDER = ["o", "p", "c", "l"]


def first_party(brand, src):
    """The vendor bundle of a brand comes first for its own printers."""
    return (brand == "Prusa" and src == "p") or (brand == "UltiMaker" and src == "c") or (brand == "Bambu Lab" and src == "o") or (brand == "LulzBot" and src == "l")


def merge(records):
    groups = {}
    for r in records:
        if not r["name"] or r["brand"].lower() in SKIP_BRANDS:
            continue
        # The limits of the machine settings of zslice (src/settings.zig).
        # A nozzle of more than 2 mm is a clay or paste printer.
        if r["bed_x"] < 20 or r["bed_y"] < 20 or r["height"] < 20 or r["bed_x"] > 2000 or r["bed_y"] > 2000 or r["height"] > 2000:
            continue
        if not (0.1 <= (r["nozzle"] or 0.4) <= 2):
            continue
        key = (norm(r["brand"]), norm(r["name"]))
        groups.setdefault(key, []).append(r)
    # One spelling for each brand: the most common one.
    spellings = {}
    for rs in groups.values():
        for r in rs:
            spellings.setdefault(norm(r["brand"]), {}).setdefault(r["brand"], 0)
            spellings[norm(r["brand"])][r["brand"]] += 1
    for rs in groups.values():
        for r in rs:
            sp = spellings[norm(r["brand"])]
            r["brand"] = max(sp, key=lambda b: (sp[b], b != b.upper(), b))
    out = []
    for key, rs in groups.items():
        rs.sort(key=lambda r: (0 if first_party(r["brand"], r["src"]) else 1, ORDER.index(r["src"])))
        top = rs[0]
        m = dict(top)
        m["srcs"] = "".join(sorted({r["src"] for r in rs}, key=ORDER.index))
        # The bed: the first record (sources can disagree by a few mm).
        for f in ("max_speed", "max_z_speed", "max_accel", "corner", "retract", "retract_speed", "filament", "family", "kinematics"):
            if not m.get(f):
                for r in rs[1:]:
                    if r.get(f):
                        m[f] = r[f]
                        break
        # The retraction of the travels: each field from the first record
        # that tells it (a 0 or a "no" too).
        m["travel"] = {f: next((r["travel"][f] for r in rs if (r.get("travel") or {}).get(f) is not None), None) for f in TRAVEL}
        nozzles = set()
        for r in rs:
            nozzles.update(x for x in r["nozzles"] if x)
        m["nozzles"] = sorted(nozzles)
        m["heated_bed"] = any(r["heated_bed"] for r in rs)
        m["heated_chamber"] = any(r["heated_chamber"] for r in rs)
        m["beds_all"] = [r["bed"] for r in rs if r.get("bed")]
        m["start"] = next((r["start"] for r in rs if r["start"]), None)
        m["end"] = next((r["end"] for r in rs if r["end"]), None)
        if not m.get("filament"):
            m["filament"] = 2.85 if m["brand"] in ("LulzBot", "UltiMaker") else 1.75
        if m["filament"] not in (1.75, 2.85, 3.0):
            m["filament"] = 2.85 if m["filament"] > 2.2 else 1.75
        m["series"] = series_of(m["name"], m.get("family", ""))
        out.append(m)
    # One spelling for each series of a brand: the spelling in a model
    # name, else the most common one.
    for brand in {m["brand"] for m in out}:
        ms = [m for m in out if m["brand"] == brand]
        spell = {}
        for m in ms:
            spell.setdefault(norm(m["series"]), {}).setdefault(m["series"], 0)
            spell[norm(m["series"])][m["series"]] += 1 + (2 if m["series"] in m["name"] else 0)
        for m in ms:
            sp = spell[norm(m["series"])]
            m["series"] = max(sp, key=lambda x: (sp[x], x != x.upper()))
    return out


# ---- output ----


def esc(text):
    return text.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def natural(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def slug(text):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")


def write(models, versions, out, beds=None):
    gcodes = {}
    bed_lines = {}

    def bid(m):
        """The number of the D line of the bed of a model, or "". A bed of
        a source that does not convert (a missing file, a license that
        does not allow it) goes to the next record of the model."""
        if beds is None:
            return ""
        for b in m.get("beds_all") or []:
            d = beds.add(b)
            if d is None:
                continue
            rect = ";".join(fmt(round(x, 3)) for x in d["rect"]) if d["rect"] else ""
            line = "\t".join([d["mesh"], d["texture"], ";".join(fmt(round(x, 3)) for x in d["offset"]), rect, d["src"]])
            if line not in bed_lines:
                bed_lines[line] = len(bed_lines)
            m["bed_used"] = d
            return str(bed_lines[line])
        return ""

    def gid(text):
        if not text:
            return ""
        if text not in gcodes:
            gcodes[text] = len(gcodes)
        return str(gcodes[text])

    models.sort(key=lambda m: (m["brand"].lower(), natural(m["series"]), natural(m["name"])))
    lines = []
    brand = None
    ids = set()
    for m in models:
        if m["brand"] != brand:
            brand = m["brand"]
            lines.append("B\t" + brand)
        mid = slug(m["brand"] + "-" + m["name"])
        while mid in ids:
            mid += "-2"
        ids.add(mid)
        flavor, firmware = m["flavor"]
        fields = [
            "P", mid, m["name"], m["series"], m["srcs"],
            fmt(m["bed_x"]), fmt(m["bed_y"]), fmt(m["height"]), fmt(m["origin_x"]), fmt(m["origin_y"]),
            "r" if m["shape"] == "round" else "",
            fmt(m["nozzle"]), ";".join(fmt(x) for x in m["nozzles"]), fmt(m["filament"]),
            ("b" if m["heated_bed"] else "") + ("c" if m["heated_chamber"] else ""),
            fmt(m.get("max_speed")), fmt(m.get("max_accel")), fmt(m.get("max_z_speed")), fmt(m.get("corner")),
            flavor, firmware, m.get("kinematics") or "",
            fmt(m.get("retract")), fmt(m.get("retract_speed")),
            gid(m["start"]), gid(m["end"]), str(m.get("extruders") or 1),
            bid(m),
        ] + travel_fields(m)
        lines.append("\t".join(f.replace("\t", " ") for f in fields))
    out.write("zslice-printers 1\n")
    out.write("# The printer library of zslice. Made by tools/printer_library.py; do not edit.\n")
    out.write("# The format is in src/printers.zig. The data comes from these sources:\n")
    for k in ORDER:
        name, lic, url = SOURCES[k]
        out.write("S\t%s\t%s\t%s\t%s\t%s\n" % (k, name, lic, url, versions.get(k, "")))
    for text, i in sorted(gcodes.items(), key=lambda t: t[1]):
        out.write("G\t%s\n" % esc(text))
    for line, i in sorted(bed_lines.items(), key=lambda t: t[1]):
        out.write("D\t%s\n" % line)
    for line in lines:
        out.write(line + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cura", required=True)
    ap.add_argument("--prusa", required=True)
    ap.add_argument("--orca", required=True)
    ap.add_argument("--cura-version", default="")
    ap.add_argument("--prusa-version", default="")
    ap.add_argument("--orca-version", default="")
    ap.add_argument("--curale", help="the folder of CuraLE_Resources (optional)")
    ap.add_argument("--curale-version", default="")
    ap.add_argument("--beds", help="the folder of the bed files (its old .mesh and .png files go away)")
    a = ap.parse_args()
    beds = None
    if a.beds:
        here = os.path.dirname(os.path.abspath(__file__))
        spec = importlib.util.spec_from_file_location("printer_beds", os.path.join(here, "printer_beds.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        os.makedirs(a.beds, exist_ok=True)
        for f in os.listdir(a.beds):
            if f.endswith((".mesh", ".png")):
                os.remove(os.path.join(a.beds, f))
        beds = mod.Beds(a.beds)
    recs = read_cura(a.cura) + read_prusa(a.prusa) + read_orca(a.orca)
    if a.curale:
        recs += read_cura(a.curale, "l", flat=True)
    for s in "cpol":
        rs = [r for r in recs if r["src"] == s]
        warn("%s: %d records, %d with a start G-code" % (SOURCES[s][0], len(rs), sum(1 for r in rs if r["start"])))
    models = merge(recs)
    warn("library: %d models, %d brands, %d with a vendor start G-code" % (len(models), len({m["brand"] for m in models}), sum(1 for m in models if m["start"])))
    write(models, {"c": a.cura_version, "p": a.prusa_version, "o": a.orca_version, "l": a.curale_version}, sys.stdout, beds)
    if beds is not None:
        used = [m["bed_used"] for m in models if m.get("bed_used")]
        warn("beds: %d models with a bed, %d with a mesh, %d with a texture" % (len(used), sum(1 for d in used if d["mesh"]), sum(1 for d in used if d["texture"])))
        for src in "cpol":
            warn("beds: from %s: %d models" % (SOURCES[src][0], sum(1 for d in used if d["src"] == src)))
        total = sum(beds.sizes.values())
        warn("beds: %d files, %.1f MB (%.1f MB meshes, %.1f MB textures)" % (len(beds.sizes), total / 1e6, sum(v for k, v in beds.sizes.items() if k.endswith(".mesh")) / 1e6, sum(v for k, v in beds.sizes.items() if k.endswith(".png")) / 1e6))
        for name, size in sorted(beds.sizes.items(), key=lambda t: -t[1])[:8]:
            warn("beds: large: %s %d KB" % (name, size // 1000))
        for path, why in sorted(beds.left_out.items()):
            warn("beds: left out: %s (%s)" % (path, why))


if __name__ == "__main__":
    main()
