# OrcaSlicer

The settings, the ideas, and the tools that zslice uses from OrcaSlicer (AGPL-3.0). zslice copies no code of it. The printer data of OrcaSlicer is in [Printer data](printer-data.md).

## Test tools

### Support test oracles

```ref
kind: tool
source: CuraEngine, OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
files: tools/support_check.py
area: support
summary: Test oracles for support.
```

CuraEngine (Ultimaker Cura 5.x) and OrcaSlicer 2.5 (the `orca-slicer` command line, with the profiles of its `Custom` vendor), https://github.com/SoftFever/OrcaSlicer

**License:** AGPL-3.0 (both); the definitions and profiles are data, no code

**Used in:** `tools/support_check.py`

**How zslice uses it:** Test oracles for support. The script slices the same parts with zslice, CuraEngine (normal and tree support), and OrcaSlicer (normal and organic tree support), and compares the unsupported overhang area, the floating support, the support volume, and the time.

## Settings

### First layer bed temperature and travel speed

```ref
kind: setting
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: src/settings.zig, src/gcode.zig, src/gcode_vars.zig
area: gcode
summary: `filament.first_layer_bed_temp` and `machine.first_layer_travel_speed` have the meaning of the OrcaSlicer settings of the bed of the first layer and `initial_layer_travel_speed`.
```

OrcaSlicer has a bed temperature of the first layer for each plate type (`hot_plate_temp_initial_layer` and the others) and `initial_layer_travel_speed` (`src/libslic3r/PrintConfig.cpp`). zslice has one bed temperature of the first layer and one travel speed of the first layer, and fills the start G-code variables of OrcaSlicer and Bambu Studio for the first layer bed (`bed_temperature_initial_layer`, `*_plate_temp_initial_layer`) with it.
