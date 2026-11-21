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
