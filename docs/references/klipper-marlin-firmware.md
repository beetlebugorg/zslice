# Firmware and G-code

The firmware commands, the G-code conventions, and the motion models of Klipper, Marlin, RepRapFirmware, and grbl.

## Algorithms, formats, and conventions

### G-code variables and macro languages

```ref
kind: format
source: Cura, PrusaSlicer, OrcaSlicer, Bambu Studio, RepRapFirmware, Repetier
license: LGPL-3.0
link: https://github.com/Ultimaker/Cura
files: src/gcode_vars.zig, src/gcode.zig, tools/profile_check.py
area: gcode
summary: The variable names of each slicer, the expression syntax, and the heat rule of a start G-code.
```

The G-code variables and the macro languages of the start and end G-code: the Cura settings of `fdmprinter.def.json` and the Cura 5 start G-code syntax (`{name}`, `{name, extruder}`, `{if}`, `{elif}`, `{else}`, `{endif}`), https://github.com/Ultimaker/Cura; the PrusaSlicer macro language and list of placeholders (https://help.prusa3d.com/article/macros_1775 and https://help.prusa3d.com/article/list-of-placeholders_205643); the OrcaSlicer placeholder list (https://github.com/SoftFever/OrcaSlicer/wiki, "Built-in placeholders variables"); the Bambu Studio placeholders in its machine presets (through the OrcaSlicer `BBL` profiles); the object model expressions of RepRapFirmware (https://docs.duet3d.com, "GCode Meta Commands")

**License:** LGPL-3.0 (Cura), AGPL-3.0 (PrusaSlicer, OrcaSlicer, Bambu Studio); the names, the syntax, and the documented behavior, no code

**Used in:** `src/gcode_vars.zig`, `src/gcode.zig`, `tools/profile_check.py`

**How zslice uses it:** The variable names of each slicer and the zslice value of each, the expression syntax (`[name]`, `{expr}`, `? :`, `=~ /regex/`, `is_nil`, `local`, `if ... then`), and the rule of PrusaSlicer and CuraEngine that heats the bed and the nozzle before a start G-code that does not. zslice has its own parser and its own small regular expression matcher. The acceleration commands of RepRapFirmware (`M204 P T`, `M566` in mm/min, https://docs.duet3d.com/User_manual/Reference/Gcodes) and Repetier-Firmware (`M201`, `M207`, https://github.com/repetier/Repetier-Firmware)

### G-code over a serial port

```ref
kind: format
source: RepRap
license: Protocol
link: https://reprap.org/wiki/G-code
files: linux/src/net/printer-link.c
area: network
summary: The USB connection.
```

G-code over a serial port: one command, then wait for the line `ok` (the Marlin and RepRap host protocol), https://reprap.org/wiki/G-code

**License:** Protocol

**Used in:** `linux/src/net/printer-link.c`

**How zslice uses it:** The USB connection.

### Junction deviation

```ref
kind: idea
source: grbl
license: MIT
link: https://github.com/grbl/grbl
files: src/motion.zig
area: gcode
summary: The speed limit at a junction of two moves, from the angle and the corner speed.
```

Junction deviation, Sonny Jeon, grbl (https://github.com/grbl/grbl, "Improving Grbl: Cornering Algorithm", 2011)

**License:** MIT (grbl); the method, not code

**Used in:** `src/motion.zig`

**How zslice uses it:** The speed limit at a junction of two moves, from the angle and the corner speed.

### Klipper kinematics

```ref
kind: idea
source: Klipper
license: GPL-3.0
link: https://www.klipper3d.org/Kinematics.html
files: src/motion.zig
area: gcode
summary: The look-ahead and the junction speeds of the motion estimate.
```

Klipper kinematics documentation, `docs/Kinematics.md` (https://www.klipper3d.org/Kinematics.html): look-ahead, the square corner velocity, and the minimum cruise ratio

**License:** GPL-3.0 (Klipper); the method, not code

**Used in:** `src/motion.zig`

**How zslice uses it:** The look-ahead passes, the junction speed from the square corner velocity, the limit of the arc to the middle of each move, the extruder corner speed, and the peak of a group of moves with the minimum cruise ratio. zslice has its own implementation.

### Filament change commands

```ref
kind: format
source: Marlin, RepRapFirmware, Klipper, Prusa
license: Public documents
link: https://marlinfw.org/docs/gcode/M600.html
files: src/filaments.zig, src/gcode.zig
area: gcode
summary: A change of the filament between layers or parts.
```

The filament change commands of the firmwares: Marlin `M600` (Filament Change, https://marlinfw.org/docs/gcode/M600.html), RepRapFirmware `M600` (https://docs.duet3d.com/User_manual/Reference/Gcodes, it runs `filament-change.g`), Klipper `PAUSE` (the `pause_resume` module, https://www.klipper3d.org/G-Codes.html#pause_resume), and the tool change `Tn` of the units that feed many filaments (the Prusa MMU3, https://help.prusa3d.com/article/mmu3-printing-in-multi-material_417224)

**License:** Public documents

**Used in:** `src/filaments.zig`, `src/gcode.zig`

**How zslice uses it:** A change of the filament between layers or parts: a pause with M600 (PAUSE on Klipper) for a printer with one filament path, or a tool change Tn for a unit that feeds many filaments.

### Object labels: EXCLUDE_OBJECT and M486

```ref
kind: format
source: Klipper, Marlin, RepRapFirmware, OrcaSlicer
license: Public documents
link: https://www.klipper3d.org/G-Codes.html#exclude_object
files: src/gcode.zig, src/engine.zig, src/plate_job.zig
area: gcode
summary: The labels of the parts in the G-code, so the firmware can skip a part: EXCLUDE_OBJECT_DEFINE, EXCLUDE_OBJECT_START, and EXCLUDE_OBJECT_END on Klipper, and M486 T, S, and S-1 on Marlin and RepRapFirmware.
```

Klipper `exclude_object` (https://www.klipper3d.org/G-Codes.html#exclude_object), Marlin `M486` (https://marlinfw.org/docs/gcode/M486.html), and RepRapFirmware `M486` (https://docs.duet3d.com/User_manual/Reference/Gcodes). OrcaSlicer writes them with `gcode_label_objects`.

**License:** Public documents

**Used in:** `src/gcode.zig`, `src/engine.zig`, `src/plate_job.zig`

**How zslice uses it:** With `machine.label_objects`, the start of the file defines each part (its name and the box of its footprint on Klipper, the count with M486 T), and the paths of a part on each layer go between a start and an end label. A filament change is outside of all labels.

## Reading G-code and the planner

### Layer, feature, and time comments of other slicers

```ref
kind: format
source: Cura, PrusaSlicer, OrcaSlicer, Bambu Studio, Klipper
license: AGPL-3.0
files: src/gcode_read.zig
area: gcode
summary: The G-code reader finds the layers, the features, and the time of a file from Cura, PrusaSlicer, OrcaSlicer, or Bambu Studio.
```

The comments that start a layer (`;LAYER:` of Cura, `;LAYER_CHANGE` of PrusaSlicer and OrcaSlicer, `; CHANGE_LAYER` of Bambu Studio), give its height (`;Z:`, `;HEIGHT:`), name a feature (`;TYPE:`, `; FEATURE:`), and give the print time (`;TIME:` of Cura, with 6666 as the value of CuraEngine with no estimate; `= 1h 2m 3s` of PrusaSlicer and OrcaSlicer). The rule of Klipper for absolute E (G90 and M82). The conventions only; no code is copied.

### Planner limits of Marlin and Klipper

```ref
kind: idea
source: Marlin, Klipper
license: GPL-3.0
link: https://marlinfw.org/docs/gcode/M201.html
files: src/motion.zig, src/gcode.zig, src/settings.zig
area: gcode
summary: The acceleration limits of the motors of a CoreXY in Marlin, and the extruder limits of Marlin and Klipper, for the time estimate.
```

Marlin applies `M201 X Y` to the motors A = X + Y and B = X - Y of a CoreXY, and has an extruder jerk of 5 mm/s and no cruise ratio. Klipper limits the head in all directions alike, has a minimum cruise ratio, and limits the acceleration of the filament (`max_extrude_only_accel`). Klipper sets limits with `SET_VELOCITY_LIMIT`. The documented behavior only; no code is copied (https://www.klipper3d.org/Config_Reference.html).
