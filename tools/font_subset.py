#!/usr/bin/env python3
"""Make the font of the labels (src/fonts/Inter-Bold-Latin.ttf).

Usage:
  python3 -I tools/font_subset.py Inter-Bold.ttf src/fonts/Inter-Bold-Latin.ttf

The input is extras/ttf/Inter-Bold.ttf of the Inter release zip
(https://github.com/rsms/inter/releases, Inter 4.1). The script:

1. keeps the glyphs of Basic Latin (U+0020 to U+007E) and Latin-1
   (U+00A0 to U+00FF), and the components of their composite glyphs;
2. drops the hinting, GSUB, GPOS, and GDEF;
3. reads the pair kerning of the "kern" feature of GPOS (PairPos formats
   1 and 2, also in Extension lookups) for each pair of the kept
   characters, and writes it as a "kern" table of format 0.

src/font.zig reads only the "kern" table, so step 3 keeps the kerning.

Inter has no Reserved Font Name (see licenses/ofl-1.1-inter.txt), so the
SIL OFL 1.1 lets the subset keep the name.

It needs fontTools (pip install fonttools).

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import sys

from fontTools import subset
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._k_e_r_n import KernTable_format_0

CODES = list(range(0x20, 0x7F)) + list(range(0xA0, 0x100))


def pair_lookups(font):
    """The pair lookups of the kern feature, in lookup order."""
    gpos = font["GPOS"].table
    idx = set()
    for fr in gpos.FeatureList.FeatureRecord:
        if fr.FeatureTag == "kern":
            idx.update(fr.Feature.LookupListIndex)
    out = []
    for i in sorted(idx):
        lk = gpos.LookupList.Lookup[i]
        subs = []
        for st in lk.SubTable:
            if lk.LookupType == 9:
                if st.ExtensionLookupType != 2:
                    continue
                st = st.ExtSubTable
            elif lk.LookupType != 2:
                continue
            subs.append(st)
        if subs:
            out.append(subs)
    return out


def pair_value(subs, a, b):
    """The x advance change of the pair (a, b) in one lookup, or None."""
    for st in subs:
        cov = st.Coverage.glyphs
        if a not in cov:
            continue
        if st.Format == 1:
            ps = st.PairSet[cov.index(a)]
            for rec in ps.PairValueRecord:
                if rec.SecondGlyph == b:
                    v = rec.Value1
                    return getattr(v, "XAdvance", 0) if v else 0
            continue
        c1 = st.ClassDef1.classDefs.get(a, 0) if st.ClassDef1 else 0
        c2 = st.ClassDef2.classDefs.get(b, 0) if st.ClassDef2 else 0
        v = st.Class1Record[c1].Class2Record[c2].Value1
        return getattr(v, "XAdvance", 0) if v else 0
    return None


def main():
    src, dst = sys.argv[1], sys.argv[2]
    # The modified time of the input stays: the output is the same each run.
    font = TTFont(src, recalcTimestamp=False)
    cmap = font.getBestCmap()
    names = sorted({cmap[c] for c in CODES if c in cmap})
    lookups = pair_lookups(font)
    pairs = {}
    for a in names:
        for b in names:
            total = 0
            for subs in lookups:
                v = pair_value(subs, a, b)
                if v:
                    total += v
            if total:
                pairs[(a, b)] = total

    opts = subset.Options()
    opts.hinting = False
    opts.layout_features = []
    opts.drop_tables += ["GSUB", "GPOS", "GDEF", "kern", "DSIG"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.glyph_names = False
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=CODES)
    sub.subset(font)

    kern = newTable("kern")
    kern.version = 0
    t = KernTable_format_0()
    t.version = 0
    t.coverage = 1
    t.format = 0
    t.tupleIndex = None
    t.kernTable = pairs
    kern.kernTables = [t]
    font["kern"] = kern
    font.save(dst)
    print(f"{len(names)} characters, {len(font.getGlyphOrder())} glyphs, {len(pairs)} kerning pairs")


if __name__ == "__main__":
    main()
