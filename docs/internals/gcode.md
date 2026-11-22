# G-code reference

This page lists each G-code, M-code, tool change, and firmware macro that zslice writes, and the firmware that reads it. It is for developers who change the G-code writer (`src/gcode.zig`) or add a printer.

zslice writes commands from three places:

1. The emitter (`gcode.Emitter` in `src/gcode.zig`). It writes the moves, the temperatures, the fan, and the commands that the settings turn on. Its own commands are in [The full table](#the-full-table).
2. The default start and end G-code of zslice (`Machine.start_gcode` and `Machine.end_gcode` in `src/settings.zig`). The generic machine profiles use them.
3. The start, end, layer change, and filament change G-code of a printer model. These texts come from the printer library (`src/printers/library.txt`) and from the Bambu Studio presets (`src/printers/bambu/` and `src/printers/change/`). zslice fills in their variables (`src/gcode_vars.zig`) and copies the commands as they are. See [Commands in the printer templates](#commands-in-the-printer-templates).

The firmware facts come from the documents of each firmware. Each fact has its link. The Bambu Lab facts come only from the code of zslice and from [Bambu Studio and Bambu Lab](../references/bambu-studio.md). A fact that is not sure says so.

## How zslice picks a command

Six settings and facts pick the commands. Each other setting changes only the values.

- `machine.gcode_flavor`: `marlin` (the default), `klipper`, `reprap` (RepRapFirmware), or `repetier`. It picks the commands for the acceleration, the corner speed, the pressure advance, the object labels, and a filament change with a pause. The printer library has a firmware name for each model. `printers.zig` sets `klipper` for Klipper, `reprap` for a name with "reprap", `repetier` for a name with "repetier", and `marlin` for all others (Marlin, Marlin 2, Cheetah, Bambu Lab, Prusa).
- A Bambu Lab model (`machine.model` with facts in `src/printers/bambu.txt`). The emitter then writes the header and config blocks of Bambu Studio, the progress line of each layer, the spaghetti detector commands, `M106 S0` for the fan off, and `M900 K L1000 M10` for the pressure advance. It writes no object labels.
- A Prusa model (`machine.model` that starts with `prusa-`). The emitter writes the statistics comments that the Buddy firmware reads. These are comments, not commands.
- `machine.accel_control`: on, the emitter writes the acceleration of each feature and the corner speed. Off (the default), it writes neither.
- `machine.label_objects`: on, the emitter labels the parts. Off (the default), it writes no labels.
- `filament.pressure_advance`: more than 0, the emitter writes the pressure advance after the start G-code. A layer range with another value (the pressure advance tower of `calib.zig`) writes the new value at its first layer.

The filament change has its own settings: `machine.filament_change` (`pause` or `tool`), `machine.tool_numbers`, `machine.nozzles`, `machine.change_gcode`, `machine.standby_delta`, and `machine.preheat_time`. See [Settings](../user/settings.md).

## Summary by firmware

The command that zslice writes for each job. "-" means that zslice writes no command for that job.

| Job | Marlin | Klipper | RepRapFirmware | Repetier | Bambu Lab | Prusa (Buddy) |
|---|---|---|---|---|---|---|
| Moves | G0, G1 | G0, G1 | G0, G1 | G0, G1 | G0, G1 | G0, G1 |
| Relative extrusion | M83 | M83 | M83 | M83 | M83 | M83 |
| Nozzle temperature | M104, M109 | M104, M109 | M104, M109 | M104, M109 | M104, M109 | M104, M109 |
| Bed temperature | M140, M190 | M140, M190 | M140, M190 | M140, M190 | M140, M190 | M140, M190 |
| Part fan | M106 S, M107 | M106 S, M107 | M106 S, M107 | M106 S, M107 | M106 S (M106 S0 for off) | M106 S, M107 |
| Acceleration (`accel_control`) | M204 S | SET_VELOCITY_LIMIT ACCEL | M204 P T | M201 X Y | M204 S | M204 S |
| Corner speed (`accel_control`) | M205 X Y | SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY | M566 X Y (mm/min) | M207 X | M205 X Y | M205 X Y |
| Pressure advance | M900 K | SET_PRESSURE_ADVANCE ADVANCE | M572 D0 S | M233 X Y | M900 K L1000 M10 | M900 K (see [Doubts](#doubts-and-possible-bugs)) |
| Object labels (`label_objects`) | M486 T, S, S-1 | EXCLUDE_OBJECT_DEFINE, _START, _END | M486 T, S, S-1 | - | - | M486 T, S, S-1 |
| Filament change, pause | M600 | PAUSE | M600 | M600 | the change G-code of the model | M600 |
| Filament change, tool | Tn | Tn | Tn | Tn | the change G-code of the model (M620, Tn, M621) | Tn |
| Progress | - | - | - | - | M73 P R | - |

## The full table

These are the commands that the emitter writes itself, in `src/gcode.zig`. The firmware column says what each firmware does with the command. "Yes" means that the firmware reads the command with the meaning that zslice uses.

| Command | What zslice uses it for | When zslice writes it | Firmware |
|---|---|---|---|
| `G0 X Y F` | A travel move. | Each travel, the combing ways, and the cooling lap. | All: yes ([Marlin](https://marlinfw.org/docs/gcode/G000-G001.html), [Klipper](https://www.klipper3d.org/G-Codes.html#g-code-commands)). |
| `G0 Z F` | The layer change. The z hop up and down. The lift over the printed parts (`print_sequence = by_object`). The move back to the layer after a filament change, and the moves down to a lower prime tower and back. | Each layer. The z hop with `machine.z_hop` > 0. | All: yes. |
| `G1 X Y E F` | An extrusion move. E is relative (M83). | Each line. | All: yes. |
| `G1 X Y F` | A move along a printed line with no plastic: the end of a coasted path (`project.coasting_volume`), and the wipe after a closed outer wall (`project.outer_wall_wipe`). | With coasting or the outer wall wipe. | All: yes. |
| `G1 X Y Z E F` | An extrusion move that is not planar (slope smoothing). | With slope smoothing. | All: yes. |
| `G1 Z F` | The nozzle goes down to the first point of a path that is not planar. | With slope smoothing. | All: yes. |
| `G1 E- F` | A retraction. | A travel longer than `machine.retract_min_travel` with no combing way, a filament change, a layer change with `machine.retract_layer_change`, and the end. | All: yes. |
| `G1 E F` | The push back after a retraction. | After each retraction. | All: yes. |
| `G1 X Y E- F` | A retraction while the nozzle wipes (a small circle, or back along the last line). | With `machine.retract_wipe`. | All: yes. |
| `M83` | Relative extrusion. | Always, after the start G-code. On a Bambu Lab model also at the end of the start G-code block. | All: yes ([Marlin](https://marlinfw.org/docs/gcode/M083.html), [Klipper](https://www.klipper3d.org/G-Codes.html#g-code-commands), [RepRapFirmware](https://docs.duet3d.com/User_manual/Reference/Gcodes#m83-set-extruder-to-relative-mode)). |
| `M104 S` | A new nozzle temperature with no wait. | A layer with another `filament.nozzle_temp`. On a Bambu Lab model, the print temperature after a change G-code with `M620.15`. | All: yes ([Marlin](https://marlinfw.org/docs/gcode/M104.html)). |
| `M104 T S` | The temperature of one nozzle of a printer with more than one: the idle nozzle waits (`standby_delta`, `filament.standby_temp`), the next nozzle heats early (`preheat_time`), and the idle nozzle of a Bambu Lab head waits 10 °C below its temperature. | `machine.nozzles` > 1 and a change to another nozzle. | Marlin, Klipper, RepRapFirmware: yes ([Klipper](https://www.klipper3d.org/G-Codes.html#g-code-commands)). Bambu Lab: T is the firmware index of the nozzle (`physical_extruder_map`). |
| `M109 S` | A new nozzle temperature, and a wait for it. | Before the start G-code if it does not heat the nozzle. The first layer, if its temperature differs from the start G-code. After a pause change to a filament with another temperature. | All: yes. RepRapFirmware also selects a tool at M109 ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m109-set-extruder-temperature-and-wait)). |
| `M109 T S` | The next nozzle of a tool changer waits for its temperature. | `tool_numbers = nozzle` and a change to another nozzle, if the change G-code has no M109. | Marlin, Klipper: yes. RepRapFirmware: yes, and it selects tool T. |
| `M140 S` | A new bed temperature with no wait. | A layer with another `filament.bed_temp`. | All: yes. |
| `M190 S` | A new bed temperature, and a wait for it. | Before the start G-code if it does not heat the bed. The first layer, if its bed temperature differs from the start G-code. | All: yes. RepRapFirmware does not wait for a target below 40 °C ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m190-wait-for-bed-temperature-to-reach-target-temp)). |
| `M106 S` | The part fan, 0 to 255. | Each change of the fan speed: the layer fan, the ramp, the boost, the overhang and bridge fan, and the cooling lap. | Marlin, Klipper, Repetier, Prusa: yes. RepRapFirmware reads S as 0 to 1.0, or as more than 1.0 to 255 ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m106-fan-on)), so `S1` is full speed there. zslice writes no P (fan index): the fan is fan 0. |
| `M107` | The part fan off. | After the start G-code, and each time the fan goes to 0. Not on a Bambu Lab model. | All except Bambu Lab: yes. |
| `M106 S0` | The part fan off on a Bambu Lab model, as Bambu Studio writes it. | A Bambu Lab model. | Bambu Lab: from the code of zslice ("Bambu Studio writes M106 S0 ... and never M107"). |
| `M204 S` | The acceleration of the next moves (`marlin` flavor). | `accel_control`, each new value. | Marlin: yes, but S is a legacy parameter that sets the print and the travel acceleration ([docs](https://marlinfw.org/docs/gcode/M204.html)). Klipper: yes ([docs](https://www.klipper3d.org/G-Codes.html#g-code-commands)). Prusa Buddy: listed ([docs](https://help.prusa3d.com/article/buddy-firmware-specific-g-code-commands_633112)). Repetier: M204 sets the PID values ([Commands.cpp](https://github.com/repetier/Repetier-Firmware/blob/master/src/ArduinoAVR/Repetier/Commands.cpp)); zslice does not write it for `repetier`. |
| `M204 P T` | The print and the travel acceleration, the same value (`reprap` flavor). | `accel_control`, each new value. | RepRapFirmware: yes ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m204-set-printing-and-travel-accelerations)). |
| `M201 X Y` | The acceleration of the next moves (`repetier` flavor). | `accel_control`, each new value. | Repetier: M201 sets the per-axis limit of the print moves; M202 sets the travel moves ([Commands.cpp](https://github.com/repetier/Repetier-Firmware/blob/master/src/ArduinoAVR/Repetier/Commands.cpp)). Marlin and RepRapFirmware also read M201 as an axis limit. |
| `M205 X Y` | The corner speed in mm/s (`marlin` flavor). | `accel_control`, once after the start G-code. | Marlin: only with `CLASSIC_JERK`. A Marlin with junction deviation reads `M205 J` and does not read X and Y ([docs](https://marlinfw.org/docs/gcode/M205.html)). Klipper: not in its list. Prusa Buddy: listed with no details. Bambu Lab: not sure. |
| `M566 X Y` | The corner speed in mm/min (`reprap` flavor). | `accel_control`, once. | RepRapFirmware: yes, in mm/min ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m566-set-allowable-instantaneous-speed-change)). |
| `M207 X` | The corner speed in mm/s (`repetier` flavor). | `accel_control`, once. | Repetier: XY jerk. Marlin and RepRapFirmware: M207 is the firmware retraction ([Marlin](https://marlinfw.org/docs/gcode/M207.html), [RepRapFirmware](https://docs.duet3d.com/User_manual/Reference/Gcodes#m207-set-retract-length)). |
| `SET_VELOCITY_LIMIT ACCEL=` | The acceleration of the next moves (`klipper` flavor). | `accel_control`, each new value. | Klipper: yes ([docs](https://www.klipper3d.org/G-Codes.html#set_velocity_limit)). |
| `SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=` | The corner speed (`klipper` flavor). | `accel_control`, once. | Klipper: yes. |
| `M900 K` | The pressure advance (`marlin` flavor). | `filament.pressure_advance` > 0, and each layer range with another value. | Marlin: with `LIN_ADVANCE` ([docs](https://marlinfw.org/docs/gcode/M900.html)). Prusa Buddy: listed; the Prusa profiles use M572 (see [Doubts](#doubts-and-possible-bugs)). Klipper: not a native command. |
| `M900 K L1000 M10` | The pressure advance on a Bambu Lab model, as OrcaSlicer writes it ([OrcaSlicer](../references/orcaslicer.md)). | A Bambu Lab model and a pressure advance. | Bambu Lab only. In Marlin, L is a second K factor ([docs](https://marlinfw.org/docs/gcode/M900.html)). |
| `SET_PRESSURE_ADVANCE ADVANCE=` | The pressure advance (`klipper` flavor). | As M900 K. | Klipper: yes ([docs](https://www.klipper3d.org/G-Codes.html#set_pressure_advance)). |
| `M572 D0 S` | The pressure advance, in seconds (`reprap` flavor). | As M900 K. | RepRapFirmware: yes ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m572-set-or-report-extruder-pressure-advance)). Prusa Buddy: yes ([docs](https://help.prusa3d.com/article/buddy-firmware-specific-g-code-commands_633112)), but zslice does not write it for Prusa. |
| `M233 X Y` | The pressure advance (`repetier` flavor): the same value for X (quadratic) and Y (linear). | As M900 K. | Repetier: Y sets the linear advance. X sets the quadratic advance only with `ENABLE_QUADRATIC_ADVANCE` ([Commands.cpp](https://github.com/repetier/Repetier-Firmware/blob/master/src/ArduinoAVR/Repetier/Commands.cpp)). |
| `M486 T` | The number of labelled parts. | `label_objects`, at the top of the file. Not `klipper`, `repetier`, or Bambu Lab. | Marlin: with `CANCEL_OBJECTS` ([docs](https://marlinfw.org/docs/gcode/M486.html)). RepRapFirmware 3.1 and later ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m486-object-cancellation)). Prusa Buddy: yes. Klipper: only with the M486 macro of `sample-macros.cfg` ([docs](https://www.klipper3d.org/Config_Reference.html#exclude_object)). Repetier: not in Commands.cpp. |
| `M486 S` | The start of the paths of part S on a layer, with the name in a comment. | `label_objects`. | As M486 T. |
| `M486 S-1` | The end of the paths of a part: the next moves belong to no part. | `label_objects`. | As M486 T. |
| `EXCLUDE_OBJECT_DEFINE NAME= CENTER= POLYGON=` | The name, the center, and the box of each part. | `label_objects` and `klipper`, at the top of the file. | Klipper: with `[exclude_object]` in printer.cfg ([docs](https://www.klipper3d.org/G-Codes.html#exclude_object)). |
| `EXCLUDE_OBJECT_START NAME=` | The start of the paths of a part on a layer. | `label_objects` and `klipper`. | Klipper, as above. |
| `EXCLUDE_OBJECT_END NAME=` | The end of the paths of a part on a layer. | `label_objects` and `klipper`. | Klipper, as above. |
| `M600` | A pause to change the filament by hand. | `filament_change = pause`, no `change_gcode`, and not `klipper`. Also a tool changer with a new filament on the same nozzle. | Marlin: with `ADVANCED_PAUSE_FEATURE` ([docs](https://marlinfw.org/docs/gcode/M600.html)). RepRapFirmware 2.02 and later: it runs `filament-change.g` if it exists, else `pause.g` ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m600-filament-change-pause)). Prusa Buddy: yes. Repetier: the filament change wizard of the display. Klipper: no native M600. |
| `PAUSE` | A pause to change the filament by hand (`klipper` flavor). | As M600, with `klipper`. | Klipper: with `[pause_resume]` ([docs](https://www.klipper3d.org/G-Codes.html#pause_resume)). |
| `Tn` | A tool change: filament n (`tool_numbers = filament`), or nozzle n (`tool_numbers = nozzle`). | `filament_change = tool` and no `change_gcode`. With `tool_numbers = nozzle`, also after a change G-code that has no T line for the nozzle. | Marlin: yes ([docs](https://marlinfw.org/docs/gcode/T.html)). RepRapFirmware: yes, it runs the tool macros ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#t-select-tool)). Prusa MMU and XL: yes. Klipper: only with a macro ([docs](https://www.klipper3d.org/G-Codes.html#g-code-commands)). Bambu Lab: in the change G-code. |
| `M73 P R` | The progress (percent) and the minutes left, for the screen. | A Bambu Lab model, once at the start of each layer. zslice fills in the values after the slice. | Bambu Lab: from the code of zslice and Bambu Studio. Marlin: with `SET_PROGRESS_MANUALLY` ([docs](https://marlinfw.org/docs/gcode/M073.html)). zslice does not write it for other printers. |
| `M981 S1 P20000`, `M981 S0 P20000` | The spaghetti detector on (after the start G-code) and off (before the end G-code), as Bambu Studio writes them. | A Bambu Lab model. | Bambu Lab only ([Bambu Studio](../references/bambu-studio.md)). |
| `M400` | Wait for the moves to end, at the end of the start G-code. | A Bambu Lab model. | All: yes ([Klipper](https://www.klipper3d.org/G-Codes.html#g-code-commands)). |
| `G90` | Absolute positions, at the end of the start G-code. | A Bambu Lab model. The default start G-code also has it. | All: yes. |
| `G21` | Units in mm, at the end of the start G-code. | A Bambu Lab model. | Marlin, RepRapFirmware, Repetier, Bambu Lab: yes. Klipper: not in its list of commands. |

The emitter writes 31 commands of its own: G0, G1, G21, G90, M73, M83, M104, M106, M107, M109, M140, M190, M201, M204, M205, M207, M233, M400, M486, M566, M572, M600, M900, M981, Tn, SET_VELOCITY_LIMIT, SET_PRESSURE_ADVANCE, EXCLUDE_OBJECT_DEFINE, EXCLUDE_OBJECT_START, EXCLUDE_OBJECT_END, and PAUSE. The default start and end G-code add G28, G91, and M84: 34 in all.

### The order at the start of a file

1. A Bambu Lab model: the header block, the config block, and `; EXECUTABLE_BLOCK_START`.
2. The comments `;FLAVOR:`, `;MACHINE:`, `;FILAMENT:`, and `;LAYER_COUNT:`. The flavor is `Marlin` for `marlin` and `klipper`, `RepRap` for `reprap`, and `Repetier` for `repetier`.
3. The object labels: `EXCLUDE_OBJECT_DEFINE` for each part, or `M486 T`.
4. `M190` and `M109` if the start G-code does not heat the bed or the nozzle (see [Template variables](#template-variables)).
5. The start G-code of the machine, then the start G-code of the filament.
6. A Bambu Lab model: `; MACHINE_START_GCODE_END`, `M400`, `G90`, `G21`, `M83`, and `M981 S1 P20000`.
7. `M83`, then `M107` (`M106 S0` on a Bambu Lab model).
8. The corner speed (`accel_control`) and the pressure advance.

At the end: a retraction, `M981 S0 P20000` and `; MACHINE_END_GCODE_START` on a Bambu Lab model, the end G-code of the filament, the end G-code of the machine, the statistics comments, and the settings that differ from the defaults (as comments).

### The default start and end G-code

`Machine.start_gcode`:

```
G90 ; absolute positions
M83 ; relative extrusion
M140 S{bed_temp}
M104 S{first_layer_nozzle_temp}
G28 ; home all axes
M190 S{bed_temp}
M109 S{first_layer_nozzle_temp}
```

`Machine.end_gcode`:

```
M104 S0
M140 S0
M107
G91
G1 Z5 F600
G90
M84
```

All firmwares read these commands. Klipper lists G28, G90, G91, M84, M104, M107, M109, M140, and M190 in its [standard commands](https://www.klipper3d.org/G-Codes.html#g-code-commands).

## Firmware differences

- **Acceleration: M204.** Marlin calls `M204 S` legacy and wants `M204 P T` ([docs](https://marlinfw.org/docs/gcode/M204.html)). Klipper reads `M204 S`, and with P and T it takes the lower value ([docs](https://www.klipper3d.org/G-Codes.html#g-code-commands)). RepRapFirmware calls S deprecated ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m204-set-printing-and-travel-accelerations)). zslice writes `M204 S` for `marlin` and `M204 P T` for `reprap`.
- **Corner speed: M205 and M566.** Marlin reads `M205 X Y` only with `CLASSIC_JERK`. With junction deviation, it reads `M205 J` in mm ([docs](https://marlinfw.org/docs/gcode/M205.html)). zslice writes no `M205 J`. RepRapFirmware reads `M566` in mm/min, and `M205` in mm/s as an alias for slicers ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m205-set-max-instantaneous-speed-change-in-mmsec)). In Repetier, `M205` prints the EEPROM settings and `M207` sets the jerk. Klipper has a square corner velocity, not a jerk.
- **Pressure advance.** Marlin `M900 K`, Klipper `SET_PRESSURE_ADVANCE`, RepRapFirmware and Prusa Buddy `M572 D S`, and Repetier `M233`. The values of Klipper and RepRapFirmware are seconds. Marlin K is a factor of its linear advance model. zslice writes one value for all.
- **Object labels.** Klipper has `EXCLUDE_OBJECT_*`, and runs M486 only through a macro. Marlin, RepRapFirmware, and Prusa Buddy read M486. Prusa Buddy wants the `A` and `N` parameters alone on a line; zslice writes neither ([docs](https://help.prusa3d.com/article/buddy-firmware-specific-g-code-commands_633112)).
- **Filament change.** Klipper has no M600; zslice writes `PAUSE`. Marlin needs `ADVANCED_PAUSE_FEATURE` and a display. A Bambu Lab model changes the filament in its change G-code (`M620 S`, `Tn`, `M621 S`).
- **Tool numbers.** Klipper reads `T1` only through a macro. RepRapFirmware runs `tfree`, `tpre`, and `tpost` at a T command, and `M109` selects a tool.
- **Progress.** zslice writes M73 only on a Bambu Lab model. RepRapFirmware does not use P ([docs](https://docs.duet3d.com/User_manual/Reference/Gcodes#m73-set-remaining-print-time)). Klipper reads `M73 P` with `[display_status]` ([docs](https://www.klipper3d.org/G-Codes.html#display_status)).
- **Fan.** zslice writes M106 with S from 0 to 255 and no P. RepRapFirmware reads `S1` as full speed.
- **Bambu Lab.** The commands M620, M621, M622, M623, M73 L, M991, M981, and M1002 come from the templates of Bambu Studio. zslice copies them. Their meaning is not in a public document. zslice reads some of them: `M620.15` in a change G-code (the nozzle cools before the tower, so zslice heats it back after the change), and `M620 S` and `M621 S` (a test in `src/plate_job.zig` reads them as the start and the end of the moves of a change).

## Commands in the printer templates

The templates are data from other slicers. zslice does not check that a firmware reads them. A template for one printer has the commands of its maker for that printer.

### The printer library

The library has 1181 models. The scan below reads the first word of each line of each start, end, and tool change text of the models that are not Bambu Lab models. It strips the comments and the template blocks first, so the counts are near, not exact. The texts have about 161 G-codes, M-codes, and T commands, and about 120 other words (Klipper macros, and some false hits of the scan).

The most common commands, by the number of models:

| Command | Models | Command | Models |
|---|---|---|---|
| G1 | 980 | G4 | 189 |
| M104 | 948 | G0 | 187 |
| M109 | 943 | G29 | 169 |
| G28 | 941 | M221 | 135 |
| M140 | 910 | M220 | 109 |
| G92 | 901 | END_PRINT | 107 |
| M84 | 840 | START_PRINT | 105 |
| M190 | 814 | Tn | 103 |
| G90 | 716 | M420 | 102 |
| M107 | 532 | M204 | 79 |
| G91 | 455 | PRINT_END | 77 |
| M106 | 306 | PRINT_START | 75 |
| M83 | 300 | M400 | 68 |
| M82 | 292 | M862.3 | 47 |
| G21 | 284 | M555 | 31 |
| M117 | 251 | M572 | 27 |

Notes:

- `M82` (absolute extrusion) is in 292 models. zslice writes `M83` after the start G-code, so the moves of zslice are relative.
- A Klipper model often calls a macro: `START_PRINT`, `PRINT_START`, `END_PRINT`, or `PRINT_END`. The macro is in the printer.cfg of the printer. zslice does not add `M190` or `M109` when the macro gets a temperature variable (see [Template variables](#template-variables)).
- The Prusa models have `M862.1`, `M862.3`, `M862.5`, `M862.6` (print checks), `M115 U` (firmware version), and `M555` (the print area). The Buddy firmware reads them in the first lines of a file ([Firmware and G-code](../references/klipper-marlin-firmware.md#what-the-prusa-firmware-reads-before-a-print)).
- The tool change texts of the tool changers (the T lines of the library) are the `change_gcode` of their models.

### Bambu Lab templates

A Bambu Lab model uses the start, end, layer change, and filament change G-code of the Bambu Studio presets (`src/printers/bambu/` and `src/printers/change/`), not the texts of the library. 14 models have them. Their texts have 144 commands. Most of them are commands of the Bambu Lab firmware only:

G0, G1, G2, G3, G17, G28, G28.14, G28.140, G29, G29.1, G29.2, G29.20, G29.30, G29.4, G29.7, G29.9, G29.99, G39.1, G39.4, G90, G91, G92, G130, G150, G150.1, G150.2, G150.3, G151, G380, G383, G383.3, G383.4, G383.7, G387, G389, G390.1, G390.7, G392, G2814, G3811, M17, M18, M73, M73.2, M83, M104, M105, M106, M109, M140, M141, M142, M145, M145.2, M190, M191, M201, M201.2, M204, M204.2, M211, M220, M221, M290, M400, M412, M481, M500, M562, M620, M620.1, M620.10, M620.11, M620.13, M620.14, M620.15, M620.17, M620.22, M620.3, M620.6, M621, M622, M622.1, M623, M628, M629, M630, M640, M640.1, M640.2, M640.4, M640.7, M640.8, M641, M710, M900, M901, M960, M963, M964, M969, M970, M970.2, M970.3, M971, M972, M973, M974, M975, M976, M977, M980.3, M982.2, M983, M983.1, M983.3, M983.4, M984, M985.1, M991, M993, M1002, M1003, M1006, M1007, M1009, M1010, M1010.1, M1012.1, M1012.5, M1012.7, M1012.8, M1012.9, M1015.3, M1015.4, M1026, M1028, M1030, M1040, M9714, M9833, M9833.2, SYNC, and Tn.

The layer change G-code writes `M73 L` (the layer number) and `M991 S0 P` (the layer for the time lapse) at each layer.

## Test slices

The 3DBenchy (`zslice-testparts/3DBenchy.stl`, one part, one filament, 239 layers), sliced on 22 November 2026 with `zslice slice 3DBenchy.stl -m <id> -o b.gcode`. The second set adds `-s machine.accel_control=true -s machine.label_objects=true -s filament.pressure_advance=0.04`. The counts are the number of lines with each command (G0 and G1 left out).

| Printer (`-m`) | Firmware | Commands |
|---|---|---|
| none (generic) | Marlin | M104 3, M83 2, M140 2, M107 2, G90 2, M84, M190, M109, M106, G91, G28 |
| `creality-ender-3` | Marlin | M104 4, G92 3, M83 2, M140 2, M107 2, M84, M190, M109, M106, G90, G4, G28 |
| `creality-k1-max` | Klipper | M83 2, T0, START_PRINT, M204, M109, M107, M106, M104, G92, END_PRINT |
| `bambu-lab-x1-carbon` | Bambu Lab | M73 478, M991 240, M400 40, M1006 38, M960 20, M106 19, M1002 15, M973 11, and 44 more |
| `prusa-core-one` | Prusa (Buddy) | G29 7, M84 4, M104 4, M109 3, M107 3, G92 3, M862.1, M862.3, M862.5, M862.6, M572, M555, M115, and more |
| none, with the options | Marlin | M486 479, M205, M204, M900, and the commands of the generic slice |
| `creality-k1-max`, with the options | Klipper | EXCLUDE_OBJECT_START 239, EXCLUDE_OBJECT_END 239, EXCLUDE_OBJECT_DEFINE, SET_VELOCITY_LIMIT 2, SET_PRESSURE_ADVANCE, and the commands of the slice before |
| `bambu-lab-x1-carbon`, with the options | Bambu Lab | M900 6 (one is `M900 K0.04 L1000 M10`), M204 3, M205, no labels |
| `blv-mgn-cube-300`, with the options | RepRapFirmware | M486 479, M572, M566, M204 |
| `atmat-signal-xl`, with the options | Repetier | M233, M207, M201, no labels |
| `prusa-core-one`, with the options | Prusa (Buddy) | M486 479, M900, M205, M204, and M572 (from the end G-code) |

M486 479 is one `M486 T`, 239 `M486 S0`, and 239 `M486 S-1`. M73 478 on the X1 Carbon is 239 `M73 P R` lines of zslice and 239 `M73 L` lines of the layer template. The test part has one filament, so these slices have no filament change. The tests in `src/plate_job.zig` check the change commands (`M600`, `M620 S`, `M620.17`).

## Template variables

`src/gcode_vars.zig` fills in the variables of the start, end, layer change, and filament change G-code, and of the start and end G-code of a filament. It reads the syntax of four slicers and of zslice:

| Syntax | From | Examples |
|---|---|---|
| `{name}` | zslice | `{bed_temp}`, `{first_layer_nozzle_temp}`, `{standby_temp}`, `{layer_height}`, `{first_layer_height}`, `{first_layer_speed}`, `{nozzle_diameter}`, `{filament_diameter}`, `{filament_name}`, `{machine_name}`, `{job_name}` |
| `{name}`, `{name, extruder}` | Cura | `{material_print_temperature}`, `{material_bed_temperature_layer_0, 0}` |
| `{if ...}`, `{elif ...}`, `{else}`, `{endif}` | Cura 5 | `{if material_bed_temperature > 50}` |
| `[name]`, `[name[0]]` | PrusaSlicer, OrcaSlicer, Bambu Studio | `[first_layer_temperature]`, `[nozzle_temperature_initial_layer]` |
| `{expression}` | PrusaSlicer, OrcaSlicer, Bambu Studio | `{max_layer_z + 5}`, `{filament_type[0] =~ /PET.*/}`, `{a ? b : c}` |
| `{if ...}`, `{elsif ...}`, `{else}`, `{endif}`, `if ... then` | PrusaSlicer, OrcaSlicer | `{if first_layer_bed_temperature[0] > 60}` |
| `{local x = ...}`, `{global x = ...}` | PrusaSlicer, OrcaSlicer | the tool state of the Prusa CORE One INDX |
| `{move.axes[0].min}` | RepRapFirmware object model | stays in the G-code with the `reprap` flavor |

The functions are `is_nil`, `min`, `max`, `one_of`, `empty`, `size`, `digits`, `zdigits`, `int`, `round`, `floor`, `ceil`, `abs`, `sqrt`, and `float`. The map `gcode_vars.names` has 302 names of zslice, Cura, PrusaSlicer, OrcaSlicer, and Bambu Studio. Each name has a zslice value.

Rules:

- A line with a variable that has no zslice value becomes a comment: `; zslice: no value for NAME: <the line>`. zslice does not write a command with a wrong value.
- A condition with such a variable is false.
- The renderer finds the heating commands of the text: `M104`, `M109`, `M140`, and `M190` with S or R, and Klipper `SET_HEATER_TEMPERATURE HEATER=extruder` or `HEATER=heater_bed`. A macro line (a first word that is not a G, M, or T code) with a temperature variable counts as heating too (for example `START_PRINT EXTRUDER_TEMP={nozzle_temp}`). If the start G-code heats neither way, the emitter writes `M190 S` and `M109 S` before it, as PrusaSlicer and CuraEngine do.
- The change G-code also has the variables of a change: `{next_extruder}`, `{previous_extruder}`, `[next_filament_id]`, `[flush_length]`, `[new_filament_temp]`, `[old_filament_temp]`, `{layer_z}`, `{max_layer_z}`, and `{toolchange_count}`.

## Doubts and possible bugs

zslice writes these commands as the code says. The behavior of the firmware is not sure in each case.

1. **Prusa Buddy and M900.** A Prusa model gets the `marlin` flavor, so zslice writes `M900 K` for the pressure advance. The Prusa profiles of the library use `M572` (27 models), and the CORE One end G-code resets it with `M572 S0`. The Buddy page documents `M572` for the pressure advance and lists `M900` with no notes. A Buddy printer can ignore the M900 of zslice. Not sure.
2. **M205 X Y on Marlin 2.** Marlin reads `M205 X Y` only with `CLASSIC_JERK`. Most Marlin 2 builds use junction deviation. On such a build, the corner speed of `accel_control` has no effect. zslice has no `M205 J`.
3. **Repetier travel acceleration.** zslice writes `M201 X Y` for each new acceleration, also for `machine.travel_accel`. Repetier applies M201 to the print moves and M202 to the travel moves, so the travel acceleration does not change. M201 also sets the axis limit of the firmware until a reset.
4. **Repetier M233.** zslice writes the same value to X (quadratic advance) and Y (linear advance), as OrcaSlicer does. The two terms have different meanings. With `ENABLE_QUADRATIC_ADVANCE`, the quadratic term gets a value that is not for it. Not sure.
5. **M106 S1 on RepRapFirmware.** RepRapFirmware reads `S1` as full speed (1.0). zslice writes `S1` for a fan speed of about 0.4 %. A fan ramp or a low fan setting can give that value.
6. **M205 X Y on a Bambu Lab model.** With `accel_control`, zslice writes `M205 X Y` to a Bambu Lab printer. The meaning in the Bambu Lab firmware is not in the code or the references. Not sure.
7. **H3C templates.** `src/printers/bambu/bambu-lab-h3c-*.gcode` and `src/printers/change/bambu-lab-h3c.gcode` exist, but `bambu_gcode_ids` in `src/printers.zig` does not list `bambu-lab-h3c`, and the library has no such model. zslice does not use these files.

## Sources

- Marlin G-code documentation, https://marlinfw.org/docs/gcode/ (the source files of MarlinDocumentation, commit dc2778ada2).
- Klipper G-Codes and Config Reference, https://www.klipper3d.org/G-Codes.html and https://www.klipper3d.org/Config_Reference.html (commit c9559fa04e).
- RepRapFirmware G-code dictionary, https://docs.duet3d.com/User_manual/Reference/Gcodes (read on 22 November 2026).
- Repetier-Firmware, `src/ArduinoAVR/Repetier/Commands.cpp`, commit 7cb3741323.
- Prusa, "Buddy firmware-specific G-code commands", https://help.prusa3d.com/article/buddy-firmware-specific-g-code-commands_633112 (read on 22 November 2026).
- [Bambu Studio and Bambu Lab](../references/bambu-studio.md) and [OrcaSlicer](../references/orcaslicer.md) for the Bambu Lab commands.

The entry "G-code dictionaries of the firmwares" in [Firmware and G-code](../references/klipper-marlin-firmware.md) records these sources.
