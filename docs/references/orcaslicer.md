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

### Support speeds

```ref
kind: setting
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: src/settings.zig
area: support
summary: `project.support_speed` and `project.support_interface_speed` have the meaning of `support_speed` and `support_interface_speed`.
```

OrcaSlicer has a speed for the support and one for the support interface (`src/libslic3r/PrintConfig.cpp`). zslice gives them as ratios of the allowed speed, as its other speeds.

### Pressure advance

```ref
kind: format
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: src/gcode.zig, src/settings.zig
area: gcode
summary: `filament.pressure_advance` writes the pressure advance command of each firmware, as `GCodeWriter::set_pressure_advance` of OrcaSlicer writes it.
```

OrcaSlicer writes `M900 K` for Marlin (with `L1000 M10` for Bambu Lab printers), `SET_PRESSURE_ADVANCE ADVANCE=` for Klipper, `M572 D0 S` for RepRapFirmware, and `M233 X Y` for Repetier (`src/libslic3r/GCodeWriter.cpp`) after the start G-code, when `enable_pressure_advance` is on. zslice writes the same commands after the start G-code when `filament.pressure_advance` is more than 0. The commands only; no code is copied.

### Filament start and end G-code

```ref
kind: setting
source: OrcaSlicer, PrusaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: src/gcode.zig, src/settings.zig
area: gcode
summary: `filament.start_gcode` and `filament.end_gcode` have the meaning of `filament_start_gcode` and `filament_end_gcode`, for the filament of the print.
```

OrcaSlicer writes `filament_start_gcode` after the machine start G-code and at each change to the filament, and `filament_end_gcode` before the machine end G-code and at each change from it (`src/libslic3r/GCode.cpp`). zslice writes them after the start G-code and before the end G-code of the print, for the filament of the print. A filament change does not write them yet.

### Setting lists of Cura and OrcaSlicer

```ref
kind: data
source: Cura, OrcaSlicer
license: LGPL-3.0 (Cura), AGPL-3.0 (OrcaSlicer)
link: https://github.com/SoftFever/OrcaSlicer
version: Cura commit 1a221ec29a86960d16a412940becc1f63534c41f, OrcaSlicer commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106
files: tools/setting_coverage.py, tools/setting_coverage_cura.txt, tools/setting_coverage_orca.txt, docs/user/setting-coverage.md
area: files
summary: The keys and the labels of all Cura and OrcaSlicer settings, for the coverage table of the user guide.
```

`tools/setting_coverage.py` reads the keys, the labels, and the categories of `resources/definitions/fdmprinter.def.json` and `fdmextruder.def.json` of Cura (https://github.com/Ultimaker/Cura), and the keys, the labels, and the config blocks of `src/libslic3r/PrintConfig.cpp` of OrcaSlicer. It writes `docs/user/setting-coverage.md`, with the zslice setting of each key from `tools/setting_coverage_cura.txt` and `tools/setting_coverage_orca.txt`. The page has the names and the labels as data; no code is copied.

### The infill direction aligned to the model

```ref
kind: setting
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
files: src/app.zig, src/settings.zig
area: infill
summary: The skin and infill angles turn with a part that turns on the bed (project.angles_follow_part).
```

OrcaSlicer, the setting `align_infill_direction_to_model`: the infill and solid infill directions follow the rotation of the model on the plate.

**License:** AGPL-3.0

**Used in:** `src/app.zig` (angleChanges), `src/settings.zig`

**How zslice uses it:** The idea and the meaning of the setting; the code is new. zslice turns the skin and infill angles of each part by the turn of the part on the bed, on by default.

### Slower walls and more fan over an overhang

```ref
kind: setting
source: OrcaSlicer, Cura
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: OrcaSlicer commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106; Cura commit 1a221ec29a86960d16a412940becc1f63534c41f
files: src/layer.zig, src/gcode.zig, src/settings.zig
area: walls
summary: `project.overhang_wall_speed`, `project.overhang_wall_fan`, and `project.overhang_wall_threshold` have the meaning of the overhang speeds and the overhang fan threshold of OrcaSlicer, and of `wall_overhang_angle` and `wall_overhang_speed_factors` of Cura.
```

OrcaSlicer slows the parts of a wall by how much of the line hangs over the layer below (`overhang_1_4_speed` to `overhang_4_4_speed`), and turns the fan up from `overhang_fan_threshold`. Cura slows the walls over `wall_overhang_angle`. zslice has one speed and one fan for all wall parts that hang over air by more than a share of the line width. It finds them by the middle of each segment against the outline of the layer below, grown or shrunk by the threshold. The settings and the idea only; no code is copied.

### Preheat time and the change G-code of a tool changer

```ref
kind: setting
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer/tree/e76b4d676c74f43ee1736675e0e8894425179cc4
version: OrcaSlicer commit e76b4d67 (resources/profiles)
files: src/settings.zig, src/gcode.zig, src/printers.zig, tools/printer_library.py
area: gcode
summary: `machine.preheat_time` has the meaning of the preheat_time of the ooze prevention of OrcaSlicer; the printer library reads change_filament_gcode, extruder_offset, and the ooze prevention of the default process of each printer with more than one extruder.
```

OrcaSlicer heats the next tool of a multi-tool printer `preheat_time` seconds before its change, so the change waits less. zslice has `machine.preheat_time` with this meaning: before each path, it estimates the time of the lines up to the next change in the layer (length over speed), and writes `M104 T<n> S<temp>` when that time is less than the preheat time. The printer library takes `change_filament_gcode` (the tool change of the Prusa XL 5T and the CORE One INDX presets), `extruder_offset`, and `ooze_prevention`, `standby_temperature_delta`, and `preheat_time` of the default process of each printer. A printer whose own presets set `single_extruder_multi_material` is a unit that feeds many filaments to one nozzle, and gets no tool changer. The OrcaSlicer presets of the UltiMaker S5 have an `extruder_offset` of `0x22`; Cura has 22 mm in X for the same nozzle. The library keeps the values of each source as they are. No code is copied.

### OrcaSlicer presets and their keys

```ref
kind: format
source: OrcaSlicer, Bambu Studio
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer
version: commit 5a1ffc6a631ead5886f1c22920deb341fc1a0106 (src/libslic3r/PrintConfig.cpp)
files: src/import_profile.zig
area: files
summary: The import of an OrcaSlicer or Bambu Studio preset (.json) and of the settings of a 3MF project, with the meaning of each key that zslice maps.
```

OrcaSlicer and Bambu Studio keep a preset as a JSON object: a text, or a list of texts for each extruder, for each key, and `inherits` for the parent preset. A 3MF project has the same object in `Metadata/project_settings.config`. The bed temperature is for each plate type (`hot_plate_temp`, `textured_plate_temp`). A line width in percent is of the nozzle. `support_threshold_angle` is from the horizontal plane. zslice reads these files and maps the keys to its settings. The format and the names only; no code is copied.

### Calibration prints

```ref
kind: idea
source: OrcaSlicer
license: AGPL-3.0
link: https://github.com/SoftFever/OrcaSlicer/wiki/Calibration
version: the wiki of OrcaSlicer, read on 2026-11-21
files: src/calib.zig, src/app/calibrate.zig, docs/user/calibrate.md
area: ui
summary: The idea of calibration prints in the slicer: a temperature tower, a flow test, a retraction test, and a pressure advance test, each on its own plate.
```

OrcaSlicer has a Calibration menu with a temperature tower (blocks at different temperatures, read for strings, layer bond, overhangs, and bridges), a flow ratio test, a pressure advance test, and a retraction test. zslice makes its own test parts (`calib.zig`) and uses the tools of any plate for the values: a named layer range for each step of a tower, and the settings of each part for the flow test. The ranges of the temperature tower (for example 190 to 230 °C for PLA) are the usual ranges of each material, in steps of 5 °C. No code and no model of OrcaSlicer is copied.
