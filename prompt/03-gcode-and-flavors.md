# 03. The G-code emitter and the firmware flavors

## Goal

Turn layer plans into printer commands for Marlin, Klipper, RepRapFirmware, and Repetier, with a time estimate that uses the acceleration. Render the start and end G-code of any printer of the library. Add thumbnails, object labels, and signed files. Part 13 adds the Bambu Lab `.gcode.3mf` file.

## Read first

- [The G-code reference](../docs/internals/gcode.md): each command that the writer writes, the settings that turn it on, the firmware that reads it (Marlin, Klipper, RepRapFirmware, Repetier, Bambu Lab, Prusa Buddy), the commands of the templates, the counts of a test slice, and the commands that a firmware can ignore.
- [Firmware and G-code](../docs/references/klipper-marlin-firmware.md).
- "The header and end comments of slicer G-code" in [Formats and protocols](../docs/references/formats-and-protocols.md).
- [Profiles](../docs/user/profiles.md), section "Start and end G-code", and [Send to a printer](../docs/user/printers.md), section "The start and end G-code".
- The header comments of `src/gcode.zig`, `src/gcode_vars.zig`, `src/motion.zig`, `src/flow.zig`, and `src/gcode_sign.zig`.

## Build

1. `src/flow.zig`: the bead is a stadium: a rectangle with a half circle on each side. Its area and the bead height give the width.
2. `src/gcode.zig`:
   - G0 travels, G1 extrusions, relative E (M83).
   - The travel retraction uses the settings of the printer (part 02). A travel longer than `machine.retract_min_travel` retracts. With `machine.z_hop_only_crossing` (default on), the nozzle lifts only for a travel that leaves the part, crosses an edge of the layer, or goes to or from the support. `machine.retract_layer_change` (default off) retracts at each layer change.
   - Wipe (`machine.retract_wipe`): only before a travel that leaves the part, crosses an edge, or goes to or from the support. The nozzle moves on a small circle inside the part, half a line width clear of the outer wall. With no room, it moves back along its last line. `retract_wipe_distance` 0 is 1.9 mm.
   - A support travel skips the retraction only inside one support island: the box of one support loop holds both ends, and the loop holds the middle of the travel. Bambu Studio has the same rule. A travel to another tree branch retracts, lifts, and wipes.
   - Combing: a travel inside the part goes around the holes with no retraction. A grid index of the outline edges tests a straight travel. `project.combing_mode` has the modes of Cura: `all` (default), `not_in_skin`, `not_on_top`, `within_infill`, and `off`. Each layer plan has its comb area (part 04). A travel with no way inside the area retracts, and lifts with the z hop of the printer.
   - `;LAYER:n` and `;TYPE:WALL-OUTER` comments in the CuraEngine convention. Viewers and printdeck read them.
   - Pressure advance per filament: M900 (Marlin), SET_PRESSURE_ADVANCE (Klipper), M572 (RepRapFirmware). It is a layer setting: the writer sets it again at the first layer of a range with another value.
   - Object labels (`machine.label_objects`): EXCLUDE_OBJECT on Klipper, M486 on Marlin and RepRapFirmware.
   - Cooling: a layer shorter than `min_layer_time` prints slower, never below `min_speed`. A bisection with the motion planner finds the slowest speed ratio that still meets the time. A layer shorter than `fan_boost_time` gets the fan at `fan_max_speed`. `filament.cooling_mode = lap` prints a short layer at full speed, then moves the head 1 mm over it with the fan at full.
3. `src/motion.zig`: the time of each move with the acceleration, junction speeds, and a look-ahead, as the firmware plans them. Retractions, Z moves, and z hops are moves from rest to rest. The replay of the view uses these times, so the replay is as exact as the estimate.
4. Each layer is written in two passes: the moves with no text and their times, then the text.
5. `src/gcode_vars.zig`: the start and end G-code variables of Cura (`{name}`, `{name, 0}`, `{if}`), PrusaSlicer, OrcaSlicer, and Bambu Studio (`[name]`, `{expression}` with lists, regex, `? :`, `{local x = 2}`), and zslice (`{bed_temp}`, ...). A line with a variable that has no zslice value becomes a comment: `; zslice: no value for NAME: <the line>`. A condition with such a variable is false. Never write a command with a wrong value. The emitter adds the heating commands that a start G-code leaves out. For the X2D, `first_filaments` gives, for each nozzle, the first filament that the print uses on that nozzle, in print order, support aside, or -1 (the template then writes 0). The plate job finds it.
6. `src/render/cpu.zig`: a software renderer for the thumbnails that Prusa, Klipper, and Bambu Lab screens show. An iso view, a depth test, a clear background, a PNG writer.
7. `src/gcode_sign.zig`: the last line of a signed file is `; zslice-signature: ed25519 <key id> <base64 signature>`. The signature is Ed25519 over the SHA-256 of all bytes before that line. The key id is the first 8 bytes of the SHA-256 of the public key, in hex. The C API is in `include/zslice.h` (`zs_sign_*`, `zs_verify_gcode`).
8. Tool changers (`machine.tool_numbers = nozzle`, part 02): Tn is the nozzle of the filament. The old nozzle goes to its standby temperature. The new nozzle waits for its temperature. The next nozzle heats `preheat_time` seconds before a change in the layer. The lines of a nozzle move by minus its offset. The tower primes each nozzle after its change. The extruder variables of PrusaSlicer (`next_extruder`, `initial_tool`, and the filament lists) are nozzles there. The XL and the CORE One INDX models print two filaments with tool changes and no M600.
9. The print statistics of PrusaSlicer for a Prusa printer (a model id that starts with `prusa-`): the time, the filament used, the type, and the color, in the names and forms of PrusaSlicer, at the end of the file. A tool change print has one item for each tool. The Buddy firmware (MINI, MK3.5, MK3.9, MK4, XL, CORE One) reads them before a print.
10. Spiral vase: each spiral layer starts at the point of its loop that is furthest in one fixed direction, so it starts where the layer below ended. No travel to a rising wall that starts within a line width. No Z move to the z where the nozzle already is. No retraction at a layer change.
11. `src/gcode_read.zig` and `src/gcode_meta.zig`: a reader of G-code of any slicer, with the byte offset of each segment, for a print view and for a host that knows the offset of a running print.

## Numbers and rules that matter

- `machine.gcode_flavor`: `marlin` (default), `klipper`, `reprap`, `repetier`.
- Names from outside (a part name, a file name) go into the G-code on one line ("Keep names from outside on one line in the G-code").
- The start G-code loads the first filament of the print, from the stream of layer 0. See the lesson.
- A filament change: the change G-code of the machine, M600, PAUSE on Klipper, or `Tn` for a unit that feeds many filaments (part 05).
- A file name with the print time rounds the time to whole minutes first, then splits the hours: "_3h00m", not "_2h60m".

## Lessons

- **The start G-code loads the first filament of the print.** A plate of filament 4 only failed on the X2D in PREPARE with "Failed to get AMS mapping table". The start G-code loaded filament 1 (`M620 S0A`, `T0`), and a change to filament 4 came at layer 0. The print mapped only filament 4 to a tray, so the printer had no tray for filament 1. Now the emitter starts with the slot of the first path of layer 0. The start and end G-code get that slot and tool. Take the slot from the stored stream of layer 0, which has its paths in print order, so a job that reads stored streams makes no extra plan.
- **Name only a used filament for each nozzle in the X2D start G-code.** An X2D print of filaments 3 and 4, both on the main nozzle, stopped 37 s in with HMS 0500-0300-0002-0010 and 0500-0600-0002-0070. The start G-code prepares a filament for each nozzle (`M620.17 T1 ... L`). zslice took the first slot of the plate on that nozzle, used or not, and wrote L4: a filament with no tray in the AMS mapping. Bambu Studio writes the first filament that the print uses on the nozzle, or -1.
- **Retract a travel to another tree branch.** A travel between tree support paths had no retraction when it crossed no edge of the part. Long travels from branch to branch then strung in the air, with no lift. Only a travel inside one support island skips the retraction now. The G-code of the generic printer changes only with tree support.
- **Wipe and lift with the values of the printer.** With the travel retraction in the project, the X2D printed with no z hop and no wipe, and the nozzle dragged over the support tops. The generic printer keeps its old G-code for the 3DBenchy and the supported test parts.
- Round the print time of a file name to whole minutes before the split into hours.
- **Write the statistics that the firmware reads.** zslice wrote its own names, so the Prusa print preview showed no time and no filament, and the firmware took the file for a print of no tool.
- **Start each spiral layer where the last one ended.** A can with ribs printed with lines across its wall. The seam jumped between the equal corners of the ribs: on 222 of 392 layers the nozzle stopped, went up to 48 mm along the wall with no extrusion, and started again. A float step off the z of the layer also wrote a Z move of 0 mm at each layer change.

## Acceptance checks

1. Each flavor writes its own pause, pressure advance, and object label commands. Test each one.
2. The time estimate comes from the motion planner, and the replay of the view ends at the estimate.
3. The start G-code of each printer of the library renders with no unknown syntax ("Check the G-code of each printer of the library": slice a test part with each profile).
4. A signed file checks as `ZS_SIGNATURE_OK` with its key, `ZS_SIGNATURE_BAD` after a change of one byte, and `ZS_SIGNATURE_UNSIGNED` with no line.
5. A plate of filament 4 only starts with T3 in the start G-code.
6. An X2D plate of filaments 3 and 4 on the main nozzle names no unused filament for the second nozzle.
7. With tree support, a travel to another branch retracts. A travel inside one support loop does not.
8. Each combing mode slices the corpus. `not_in_skin` gives no travel over the skin with no retraction.
9. The test of each Prusa model (51 models, `src/plate_job.zig`) slices two cubes of two filaments. It checks the M862.3 printer name, a value for each template variable, the temperatures, the extrusions on the bed, a tool change on an MMU and a pause on the others, and the statistics comments.
10. The test of spiral vase mode finds no stop in the wall.
