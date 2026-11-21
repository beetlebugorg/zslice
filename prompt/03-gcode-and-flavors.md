# 03. The G-code emitter and the firmware flavors

## Goal

Turn layer plans into printer commands for Marlin, Klipper, RepRapFirmware, and Repetier, with a time estimate that uses the acceleration. Render the start and end G-code of any printer of the library. Add thumbnails, object labels, and signed files. Part 13 adds the Bambu Lab `.gcode.3mf` file.

## Read first

- [Firmware and G-code](../docs/references/klipper-marlin-firmware.md).
- "The header and end comments of slicer G-code" in [Formats and protocols](../docs/references/formats-and-protocols.md).
- [Profiles](../docs/user/profiles.md), section "Start and end G-code", and [Send to a printer](../docs/user/printers.md), section "The start and end G-code".
- The header comments of `src/gcode.zig`, `src/gcode_vars.zig`, `src/motion.zig`, `src/flow.zig`, and `src/gcode_sign.zig`.

## Build

1. `src/flow.zig`: the bead is a stadium: a rectangle with a half circle on each side. Its area and the bead height give the width.
2. `src/gcode.zig`:
   - G0 travels, G1 extrusions, relative E (M83).
   - Retraction for a travel longer than `retract_min_travel`. Z hop only for a travel that crosses an edge of the layer. No z hop at the retraction of a layer change.
   - A travel between tree support paths that crosses no edge of the part has no retraction.
   - Combing: a travel inside the part goes around the holes with no retraction. A grid index of the outline edges tests a straight travel.
   - `;LAYER:n` and `;TYPE:WALL-OUTER` comments in the CuraEngine convention. Viewers and printdeck read them.
   - Pressure advance per filament: M900 (Marlin), SET_PRESSURE_ADVANCE (Klipper), M572 (RepRapFirmware).
   - Object labels (`machine.label_objects`): EXCLUDE_OBJECT on Klipper, M486 on Marlin and RepRapFirmware.
   - Cooling: a layer shorter than `min_layer_time` prints slower, never below `min_speed`. A bisection with the motion planner finds the slowest speed ratio that still meets the time. A layer shorter than `fan_boost_time` gets the fan at `fan_max_speed`. `filament.cooling_mode = lap` prints a short layer at full speed, then moves the head 1 mm over it with the fan at full.
3. `src/motion.zig`: the time of each move with the acceleration, junction speeds, and a look-ahead, as the firmware plans them. Retractions, Z moves, and z hops are moves from rest to rest. The replay of the view uses these times, so the replay is as exact as the estimate.
4. Each layer is written in two passes: the moves with no text and their times, then the text.
5. `src/gcode_vars.zig`: the start and end G-code variables of Cura (`{name}`, `{name, 0}`, `{if}`), PrusaSlicer, OrcaSlicer, and Bambu Studio (`[name]`, `{expression}` with lists, regex, `? :`, `{local x = 2}`), and zslice (`{bed_temp}`, ...). A line with a variable that has no zslice value becomes a comment: `; zslice: no value for NAME: <the line>`. A condition with such a variable is false. Never write a command with a wrong value. The emitter adds the heating commands that a start G-code leaves out.
6. `src/render/cpu.zig`: a software renderer for the thumbnails that Prusa, Klipper, and Bambu Lab screens show. An iso view, a depth test, a clear background, a PNG writer.
7. `src/gcode_sign.zig`: the last line of a signed file is `; zslice-signature: ed25519 <key id> <base64 signature>`. The signature is Ed25519 over the SHA-256 of all bytes before that line. The key id is the first 8 bytes of the SHA-256 of the public key, in hex. The C API is in `include/zslice.h` (`zs_sign_*`, `zs_verify_gcode`).
8. `src/gcode_read.zig` and `src/gcode_meta.zig`: a reader of G-code of any slicer, with the byte offset of each segment, for a print view and for a host that knows the offset of a running print.

## Numbers and rules that matter

- `machine.gcode_flavor`: `marlin` (default), `klipper`, `reprap`, `repetier`.
- Names from outside (a part name, a file name) go into the G-code on one line ("Keep names from outside on one line in the G-code").
- The start G-code loads the first filament of the print, from the stream of layer 0. See the lesson.
- A filament change: the change G-code of the machine, M600, PAUSE on Klipper, or `Tn` for a unit that feeds many filaments (part 05).

## Lessons

- **The start G-code loads the first filament of the print.** A plate of filament 4 only failed on the X2D in PREPARE with "Failed to get AMS mapping table". The start G-code loaded filament 1 (`M620 S0A`, `T0`), and a change to filament 4 came at layer 0. The print mapped only filament 4 to a tray, so the printer had no tray for filament 1. Now the emitter starts with the slot of the first path of layer 0. The start and end G-code get that slot and tool. Take the slot from the stored stream of layer 0, which has its paths in print order, so a job that reads stored streams makes no extra plan.
- Lift the nozzle only for travels that cross an edge of the layer. Do not lift at the retraction of a layer change.
- A long infill or support travel with no retraction inside a tree is correct: the support comes off, and a tree has many small islands.

## Acceptance checks

1. Each flavor writes its own pause, pressure advance, and object label commands. Test each one.
2. The time estimate comes from the motion planner, and the replay of the view ends at the estimate.
3. The start G-code of each printer of the library renders with no unknown syntax ("Check the G-code of each printer of the library": slice a test part with each profile).
4. A signed file checks as `ZS_SIGNATURE_OK` with its key, `ZS_SIGNATURE_BAD` after a change of one byte, and `ZS_SIGNATURE_UNSIGNED` with no line.
5. A plate of filament 4 only starts with T3 in the start G-code.
