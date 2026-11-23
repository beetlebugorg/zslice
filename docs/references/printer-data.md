# Printer data

The printer library and the bed models of the printers, and the rules that place them.

## Data in the binaries

The printer library (`src/printers/library.txt`) has data from the printer definitions of four slicers. `tools/printer_library.py` converts them: it reads the bed, the nozzle, the motion limits, the firmware, and the start and end G-code of each printer model, and writes one record for each model. The native C library (`libzslice`, which the GTK app links) embeds the file (`src/printers.zig`). The wasm module does not embed it: the web app loads the file as `printers.txt`. The license texts of the sources are in all binaries, the wasm module too. The header of the file names the sources and their versions.

The Bambu Lab data is in [Bambu Studio](bambu-studio.md).

### Cura printer definitions

```ref
kind: data
source: Cura
license: LGPL-3.0-or-later
link: https://github.com/Ultimaker/Cura
version: commit 1a221ec29a86960d16a412940becc1f63534c41f
files: src/printers/library.txt, tools/printer_library.py, src/printers.zig
texts: licenses/lgpl-3.0.txt, licenses/gpl-3.0.txt
area: printers
summary: The values of the `.def.json` files, and the G-code with the variables of zslice.
```

Cura printer definitions, UltiMaker, https://github.com/Ultimaker/Cura, `resources/definitions` and `resources/extruders`, commit `1a221ec29a86960d16a412940becc1f63534c41f` (9 November 2026)

**License:** LGPL-3.0-or-later ("Cura is released under the terms of the LGPLv3 or higher")

**Text:** `licenses/lgpl-3.0.txt` (from the Cura repository), `licenses/gpl-3.0.txt` (the LGPL-3.0 adds to the GPL-3.0)

**Notes:** The values of the `.def.json` files, and the G-code with the variables of zslice. The LGPL-3.0 allows the use in a work under the AGPL-3.0. The retraction of the travels of a printer (`machine.z_hop` and the others) comes from `retraction_hop_enabled`, `retraction_hop`, `retraction_hop_only_when_collides`, `retract_at_layer_change`, and `retraction_min_travel`, only where the definition sets them (not the defaults of `fdmprinter`).

### PrusaSlicer vendor bundles

```ref
kind: data
source: PrusaSlicer
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
version: tag version_2.9.7
files: src/printers/library.txt, tools/printer_library.py, src/printers.zig
area: printers
summary: The `[printer_model:*]` and `[printer:*]` sections, with their `inherits`.
```

PrusaSlicer vendor bundles, Prusa Research, https://github.com/prusa3d/PrusaSlicer, `resources/profiles/*.ini`, tag `version_2.9.7` (commit `450d70dd81c9b8990bc6bc8e690e31f82ddceb11`). The main branch moved the bundles out of the repository, so the tool uses the last release.

**License:** AGPL-3.0 (the license of the PrusaSlicer repository)

**Text:** `LICENSE` (the same AGPL-3.0 text as zslice)

**Notes:** The `[printer_model:*]` and `[printer:*]` sections, with their `inherits`. The retraction of the travels of a printer comes from `retract_lift` (a lift at each retraction), `wipe`, `retract_layer_change`, and `retract_before_travel`. A Prusa model with `single_extruder_multi_material = 1` and more than one extruder (an MMU) gets the field "t" of the library: a tool change for each filament change.

### OrcaSlicer printer profiles

```ref
kind: data
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: commit e76b4d676c74f43ee1736675e0e8894425179cc4
files: src/printers/library.txt, tools/printer_library.py, src/printers.zig
area: printers
summary: The `machine_model` and `machine` presets of each vendor, with their `inherits`.
```

OrcaSlicer profiles, https://github.com/SoftFever/OrcaSlicer, `resources/profiles`, commit `e76b4d676c74f43ee1736675e0e8894425179cc4` (17 November 2026)

**License:** AGPL-3.0 (the license of the OrcaSlicer repository)

**Text:** `LICENSE`

**Notes:** The `machine_model` and `machine` presets of each vendor, with their `inherits`. The retraction of the travels of a printer comes from `z_hop`, `z_hop_types` ("Auto Lift" is `machine.z_hop_only_crossing`), `wipe`, `wipe_distance`, `retract_when_changing_layer`, and `retraction_minimum_travel`, only where the presets of the vendor set them (not the defaults of `fdm_machine_common`). The Prusa presets test `idle_temperature[...] == 0` for a filament with no idle temperature; the tool writes the test as `is_nil(idle_temperature[...])`, the form of PrusaSlicer and zslice.

### Cura LulzBot Edition printer definitions

```ref
kind: data
source: Cura LulzBot Edition
license: LGPL-3.0
link: https://github.com/lulzbot3d/CuraLE_Resources
version: commit e44e13dedd1a055e956deced8723bec0ae7966be
files: src/printers/library.txt, tools/printer_library.py, src/printers.zig
texts: licenses/lgpl-3.0.txt, licenses/gpl-3.0.txt
area: printers
summary: The LulzBot printers (TAZ Workhorse, TAZ Pro, TAZ 5 to 8, Mini, SideKick, Bio) in the Cura format.
```

Cura LulzBot Edition resources, FAME 3D (LulzBot), https://github.com/lulzbot3d/CuraLE_Resources, `definitions` and `extruders`, commit `e44e13dedd1a055e956deced8723bec0ae7966be` (31 January 2025)

**License:** LGPL-3.0 (the `LICENSE` file of the repository)

**Text:** `licenses/lgpl-3.0.txt`, `licenses/gpl-3.0.txt`

**Notes:** The LulzBot printers (TAZ Workhorse, TAZ Pro, TAZ 5 to 8, Mini, SideKick, Bio) in the Cura format. LulzBot comes first for its own printers. The nozzle of a tool head is in its name ("SE 0.50 mm"): the tool takes it from there.

### Creality firmware configurations

```ref
kind: data
source: Creality firmware
license: GPL-3.0
link: https://github.com/CrealityOfficial/K1_Series_Klipper
version: K1_Series_Klipper e09f36e6, K2_Series_Klipper bc0a5207, CR-10SE_Klipper b633196f, Hi_Klipper 646b6aaa
files: tools/printer_library.py, src/printers/library.txt
texts: licenses/gpl-3.0.txt
area: printers
summary: The kinematics of the K1 and K2 models, and the chamber heater of the K2 Pro, CR-10 SE, and Hi.
```

Creality, the `config/<model>/printer.cfg` files of https://github.com/CrealityOfficial/K1_Series_Klipper (commit `e09f36e6ada60e5467b0bef731a96263b5d8095b`), https://github.com/CrealityOfficial/K2_Series_Klipper (commit `bc0a52078ace1e4d82995e396b38457b9f441024`), https://github.com/CrealityOfficial/CR-10SE_Klipper (commit `b633196f0a9dfb010dd3fc2bd20dbeb37039b93a`), and https://github.com/CrealityOfficial/Hi_Klipper (commit `646b6aaaa4dc1fe9c4f773f1a425ea4666e5ed9b`)

**License:** GPL-3.0 (the license of each repository); zslice uses facts and copies no code

**Text:** `licenses/gpl-3.0.txt`

**Notes:** The overrides of `tools/printer_library.py` use the `kinematics` value of the K1, K1C, K1 SE, K1 Max, K2, K2 Pro, and K2 Plus, and the `heater_generic chamber_heater` section. The K2 Pro has this section. The CR-10 SE and the Hi do not.

### Marlin and Klipper printer configurations

```ref
kind: data
source: Marlin Configurations, Klipper
license: GPL-3.0
link: https://github.com/MarlinFirmware/Configurations
version: Configurations aae053b1, Klipper c9559fa0
files: tools/printer_library.py, src/printers/library.txt
texts: licenses/gpl-3.0.txt
area: printers
summary: The CoreXY kinematics of the Ender-4 and Ender-6, and the Z travel of the Ender-5 S1.
```

Marlin example configurations, https://github.com/MarlinFirmware/Configurations, `config/examples/Creality`, commit `aae053b1572b759a90ce8570e1cade123bcab2f1`, and Klipper, https://github.com/Klipper3d/klipper, `config/printer-creality-ender5-s1-2023.cfg`, commit `c9559fa04ec6b11fb1a9a1610903546319fcf310`

**License:** GPL-3.0 (the license of each repository); zslice uses facts and copies no code

**Text:** `licenses/gpl-3.0.txt`

**Notes:** `COREXY` in the Marlin configurations of the Ender-4 and the Ender-6. The Klipper configuration of the Ender-5 S1 has a Z `position_max` of 280 mm.

## Data next to the binaries

The bed models of the printers are files in `src/printers/beds/`: 456 meshes (`.mesh`) and 280 textures (`.png`), 10.5 MB in all. No binary and no wasm module contains them. The GTK app installs them in `share/zslice/beds`, and `zig build web` puts them in `zig-out/web/app/beds`. A shell loads the two files of the current printer (`zs_printers_bed`, `zs_view_set_bed`). The D lines of `src/printers/library.txt` name the files, and the P line of each printer model links its D line: 830 of the 1080 models have a bed, 813 with a mesh and 549 with a texture.

`tools/printer_library.py --beds` makes the files with `tools/printer_beds.py`. The tool reads the bed files of the four sources below, converts them (a mesh in printer axes with 16-bit coordinates and at most 5000 triangles; a PNG of at most 1024 pixels with 64 colors), and writes each file once. The bed of a model comes from the first of its records that has one, in the order of the library (the vendor bundle of a brand first, then OrcaSlicer, PrusaSlicer, Cura).

The bed files have no license notes of their own: no license or readme file is in the mesh, image, or vendor folders, and no mesh, SVG, or PNG file has license metadata. So the license of the repository covers them. The exceptions are in the notes of each entry.

### Cura bed meshes and textures

```ref
kind: data
source: Cura
license: LGPL-3.0-or-later
link: https://github.com/Ultimaker/Cura
version: commit 1a221ec29a86960d16a412940becc1f63534c41f
files: src/printers/beds, tools/printer_beds.py, src/bed.zig
texts: licenses/lgpl-3.0.txt, licenses/gpl-3.0.txt
area: printers
summary: The `platform` mesh (STL, OBJ, 3MF) of each definition, with `platform_offset`, and the `platform_texture` of an OBJ platform with UV coordinates.
```

Cura, UltiMaker, https://github.com/Ultimaker/Cura, `resources/meshes` and `resources/images`, commit `1a221ec29a86960d16a412940becc1f63534c41f` (9 November 2026)

**License:** LGPL-3.0-or-later (the license of the repository)

**Text:** `licenses/lgpl-3.0.txt`, `licenses/gpl-3.0.txt`

**What zslice uses:** The `platform` mesh (STL, OBJ, 3MF) of each definition, with `platform_offset`, and the `platform_texture` of an OBJ platform with UV coordinates. 275 models. The RatRig meshes (`ratrig_*.stl`) came to Cura from https://github.com/slic3r/slic3r-profiles (AGPL-3.0) "with kind permission of the author" (Cura commit `f6cc7993e`).

### PrusaSlicer bed models and textures

```ref
kind: data
source: PrusaSlicer
license: AGPL-3.0
link: https://github.com/prusa3d/PrusaSlicer
version: tag version_2.9.7
files: src/printers/beds, tools/printer_beds.py, src/bed.zig
area: printers
summary: The `bed_model` STL and the `bed_texture` SVG or PNG of each `[printer_model:*]` section.
```

PrusaSlicer vendor bundles, Prusa Research, https://github.com/prusa3d/PrusaSlicer, `resources/profiles/<vendor>/`, tag `version_2.9.7` (commit `450d70dd81c9b8990bc6bc8e690e31f82ddceb11`)

**License:** AGPL-3.0 (the license of the repository)

**Text:** `LICENSE`

**What zslice uses:** The `bed_model` STL and the `bed_texture` SVG or PNG of each `[printer_model:*]` section. 145 models.

### OrcaSlicer bed models and textures

```ref
kind: data
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: commit e76b4d676c74f43ee1736675e0e8894425179cc4
files: src/printers/beds, tools/printer_beds.py, src/bed.zig
area: printers
summary: The `bed_model` STL and the `bed_texture` SVG or PNG of each `machine_model` preset.
```

OrcaSlicer profiles, https://github.com/SoftFever/OrcaSlicer, `resources/profiles/<vendor>/`, commit `e76b4d676c74f43ee1736675e0e8894425179cc4` (17 November 2026)

**License:** AGPL-3.0 (the license of the repository)

**Text:** `LICENSE`

**What zslice uses:** The `bed_model` STL and the `bed_texture` SVG or PNG of each `machine_model` preset. 410 models.

### LulzBot bed plates

```ref
kind: data
source: Cura LulzBot Edition
license: LGPL-3.0
link: https://github.com/lulzbot3d/CuraLE_Resources
version: commit e44e13dedd1a055e956deced8723bec0ae7966be
files: src/printers/beds, tools/printer_beds.py, src/bed.zig
texts: licenses/lgpl-3.0.txt
area: printers
summary: The bed plates of the LulzBot printers, placed as Cura places them (`platform_offset`).
```

Cura LulzBot Edition resources, https://github.com/lulzbot3d/CuraLE_Resources, `meshes/bed_plates`, commit `e44e13dedd1a055e956deced8723bec0ae7966be`

**License:** LGPL-3.0 (the license of the repository; `meshes/README.md` adds no terms)

**Text:** `licenses/lgpl-3.0.txt`

**What zslice uses:** The bed plates of the LulzBot printers, placed as Cura places them (`platform_offset`).

### Left out

Left out:

- The bed textures of the PrusaSlicer RatRig bundle (`RatRig/rr-vc-300.svg`, `rr-vc-400.svg`, `rr-vc-500.svg`, `rr-vminion.svg`). The header of `RatRig.ini` says: "The graphics for the bed (SVG) was created by PwnCNC and published on Thingiverse under the Creative Commons Attribution license" (https://www.thingiverse.com/thing:4861532). The version of the license is not known (the page does not open), so the license is not clear. The RatRig models get their beds from OrcaSlicer and Cura.
- `gCreate/gmax15p.svg` and `gCreate/gmax2.svg` of PrusaSlicer: empty images (no size).
- `E2D/i310_bed.stl` and `E2D/i311_bed.stl` of PrusaSlicer: the bundle names them, but they are not in it.
- The Cura textures of an STL or 3MF platform (for example `anycubic_predator.png`, `uni.png`): such a mesh has no UV coordinates, so Cura shows no texture with it either.

Some textures show the logo of a brand. The logos are trademarks of their owners; the license of the files is not a license of the trademarks.

## Algorithms, formats, and conventions

### Printer definition formats

```ref
kind: format
source: Cura, PrusaSlicer, OrcaSlicer
license: LGPL-3.0
files: tools/printer_library.py, src/printers.zig
area: printers
summary: The converter reads these formats.
```

The printer definition formats: Cura `.def.json` (`inherits`, `metadata`, `overrides` with `default_value` and `value`), PrusaSlicer vendor bundles (INI sections `[printer_model:*]` and `[printer:*]`, `inherits` lists, `bed_shape`), and OrcaSlicer vendor profiles (`machine_model` and `machine` presets, `instantiation`, `printable_area`)

**License:** LGPL-3.0 (Cura), AGPL-3.0 (PrusaSlicer, OrcaSlicer); the formats, no code

**Used in:** `tools/printer_library.py`, `src/printers.zig`

**How zslice uses it:** The converter reads these formats. The simple G-code variables of the three slicers get the names of zslice; the other variables and the scripts stay, for the core (see the next line). Newer OrcaSlicer profiles keep the G-code of a Bambu Lab preset in a preset of its own ("<preset> template machine_start_gcode"). CuraEngine heats the bed and the nozzle before a start G-code with no heat commands (`machine_start_gcode`), so the converter adds them to such a Cura G-code.

### Cura bed placement

```ref
kind: idea
source: Cura
license: LGPL-3.0
link: https://github.com/Ultimaker/Uranium
version: commit a5dab929d07c85eb4d96b18a50973da3a46fb8b7
files: tools/printer_beds.py
area: printers
summary: The axes of each mesh format (the scene has y up.
```

The bed placement of Cura: Uranium `UM/Scene/Platform.py`, the mesh readers `plugins/FileHandlers/STLReader/STLReader.py` and `OBJReader/OBJReader.py` (https://github.com/Ultimaker/Uranium, main of 17 November 2026, commit `a5dab929d07c85eb4d96b18a50973da3a46fb8b7`), and Cura `plugins/3MFReader/ThreeMFReader.py` (commit `1a221ec2`)

**License:** LGPL-3.0 (the rules, not code)

**Used in:** `tools/printer_beds.py`

**How zslice uses it:** The axes of each mesh format (the scene has y up; STL and OBJ turn (x, y, z) into (x, z, -y); a 3MF platform keeps the coordinates of its file), the origin at the bed center, `platform_offset` as the node position, and the UV of the OBJ file with the image mirrored.

### PrusaSlicer bed placement

```ref
kind: idea
source: PrusaSlicer
license: AGPL-3.0
version: tag version_2.9.7
files: tools/printer_beds.py, src/bed.zig
area: printers
summary: The origin of the model at the center of the bed shape, 0.03 mm down, and the texture over the box of the bed shape.
```

The bed placement of PrusaSlicer: `src/slic3r/GUI/3DBed.cpp` (tag `version_2.9.7`)

**License:** AGPL-3.0 (the rules, not code)

**Used in:** `tools/printer_beds.py`, `src/bed.zig`

**How zslice uses it:** The origin of the model at the center of the bed shape, 0.03 mm down, and the texture over the box of the bed shape.

### OrcaSlicer bed placement

```ref
kind: idea
source: OrcaSlicer
license: AGPL-3.0
version: commit e76b4d67
files: tools/printer_beds.py, src/bed.zig
area: printers
summary: The origin of the model at the center of the printable area, 0.45 mm down.
```

The bed placement of OrcaSlicer: `src/slic3r/GUI/3DBed.cpp` and `PartPlate.cpp` (commit `e76b4d67`)

**License:** AGPL-3.0 (the rules, not code)

**Used in:** `tools/printer_beds.py`, `src/bed.zig`

**How zslice uses it:** The origin of the model at the center of the printable area, 0.45 mm down; the printer coordinates of the "bbl-3dp-" models; the texture over the box of the printable area, 12 mm more to the front for Bambu Lab.

### Printer fans and enclosures

```ref
kind: data
source: Printer makers
license: Product pages
link: https://us.store.bambulab.com/products/auxiliary-part-cooling-fan
files: src/printers.zig
area: printers
summary: The cooling of the printer families in the machine profiles of the library (`machine.chamber_temp`, `machine.part_fan_air`).
```

The fans and the enclosures of printer families, from the makers and their parts stores: Bambu Lab, "Auxiliary Part Cooling Fan" (a 12 W fan on the left side of the chamber of the X1 and P1 series), https://us.store.bambulab.com/products/auxiliary-part-cooling-fan; Creality K1 side blower fan, https://spool3d.ca/creality-k1-auxillary-side-blower-fan/, a 12032 radial fan (https://printables.com/model/524431-creality-k1-side-fan-cover-12032); Creality Ender 3 V2 4010 blower, https://store.dremc.com.au/products/ender-3-v2-hotend-axial-and-blower-fan; Prusa print fan blowers, https://www.prusa3d.com/product/print-fan-blower/, https://partsbuilt.com/print-cooling-fan-mk4-xl-original-prusa, and https://www.123-3d.co.uk/Prusa-Print-Fan-Blower-for-MK4S-MK3-9-Core-One-i13409.html (a 5015 blower), and the chamber of the Core One, https://help.prusa3d.com/article/chamber-temperature-is-critical-31261-core-one-l-35261-core-one-17261-xl_861880; the Voron Stealthburner fans (a 5015 part cooling blower), https://forum.vorondesign.com/threads/stealthburner-fan-specifications.985; QIDI X-Max 3 (a heated chamber to 65 °C), https://qidi3d.com/products/qidi-x-max-3, and the X-Plus 3 auxiliary fan, https://qidi3d.com/products/x-plus-3-auxiliary-fan; UltiMaker S3 and S5 radial fans (35 x 35 x 10 mm, one on each side of the head), https://shop.cadmicro.com/products/ultimaker-radial-fan-35x35x10-for-um3-series-s3-s5; the LulzBot SE tool head (a 24 V radial blower), https://lulzbot.com/store/lulzbot-se-tool-head-nickel-plated-copper-0-5-mm-kt-cp0136

**License:** Product pages

**Used in:** `src/printers.zig`

**How zslice uses it:** The cooling of the printer families in the machine profiles of the library (`machine.chamber_temp`, `machine.part_fan_air`). The fans and the enclosures come from these pages. The air speeds are estimates from the fan sizes, and the air of a closed printer with PLA is an estimate.
