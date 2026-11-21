# Fonts

The font of the labels (`src/fonts/Inter-Bold-Latin.ttf`) is a subset of Inter Bold. `src/font.zig` embeds it in all binaries, the wasm module too.

## Data in the binaries

### Inter Bold

```ref
kind: font
source: Inter
license: SIL Open Font License 1.1
link: https://github.com/rsms/inter
version: release v4.1
files: tools/font_subset.py, src/fonts/Inter-Bold-Latin.ttf, src/font.zig
texts: licenses/ofl-1.1-inter.txt
area: fonts
summary: A subset of Inter Bold (Latin, with kerning) is the font of the labels.
```

Inter, Rasmus Andersson and the Inter Project Authors, https://github.com/rsms/inter, release `v4.1` (`Inter-4.1.zip`, SHA-256 `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e`), the file `extras/ttf/Inter-Bold.ttf` (SHA-256 `288316099b1e0a47a4716d159098005eef7c0066921f34e3200393dbdb01947f`). "Copyright (c) 2016 The Inter Project Authors."

**License:** SIL Open Font License 1.1

**Text:** `licenses/ofl-1.1-inter.txt` (the `LICENSE.txt` of the release)

**Notes:** `tools/font_subset.py` keeps Basic Latin and Latin-1 (190 characters, 214 glyphs), drops the hinting and the OpenType layout tables, and writes the pair kerning of the GPOS `kern` feature as a `kern` table (4663 pairs). The license names no Reserved Font Name, so the subset keeps the name. The OFL allows the font in a program under the AGPL-3.0; the font keeps its own license.

## Algorithms, formats, and conventions

### OpenType specification

```ref
kind: format
source: Microsoft
license: The format
link: https://learn.microsoft.com/en-us/typography/opentype/spec/
files: src/font.zig, tools/font_subset.py
area: fonts
summary: The reader of the font of the labels.
```

The OpenType and TrueType specification (Microsoft, https://learn.microsoft.com/en-us/typography/opentype/spec/): the table directory and the tables `head`, `maxp`, `hhea`, `hmtx`, `cmap` (formats 4 and 12), `loca`, `glyf` (simple and composite glyphs, quadratic curves), `kern` (format 0), `OS/2` (the cap height), and the pair adjustment of `GPOS` (formats 1 and 2)

**License:** The format

**Used in:** `src/font.zig`, `tools/font_subset.py`

**How zslice uses it:** The reader of the font of the labels. The tool reads GPOS with fontTools (https://github.com/fonttools/fonttools, MIT; a tool, no code in zslice).
