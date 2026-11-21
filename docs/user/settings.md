# Settings reference

<!-- Made by tools/settings_doc.py from src/settings.zig. Do not edit by hand. -->

Each setting has a name in the form `group.name`. Set it on the command line with `-s group.name=value`, in C with `zs_settings_set`, and in JavaScript as a key of the settings object.

Units: lengths in mm, speeds in mm/s, flow in mm³/s, temperatures in °C. A ratio is 0 to 1.

A setting marked "Per layer" can change for some layers of a part (for example "This layer and up" in the app). [Settings for some layers](../internals/layer-settings.md) explains the others.

## machine

Facts about the printer. They change only when the printer changes.

### Printer

**`machine.name`** (text). Default: `"generic"`

The name of the printer, for the G-code header.

**`machine.model`** (text). Default: `""`

The id of the printer model in the printer library, for example "creality-ender-3-v2". The 3D view shows the bed model of this printer. Empty: the view shows the bed as a grid.

### Bed

**`machine.bed_size_x`** (number). Default: `220`

The size of the bed in X.

**`machine.bed_size_y`** (number). Default: `220`

The size of the bed in Y.

**`machine.origin_x`** (number). Default: `0`

The G-code X of the front left corner of the bed. The slicer places parts in bed coordinates (0, 0 at the front left corner) and adds this to each X in the G-code. Most printers: 0. A printer with its origin at the bed center: minus half the bed width.

**`machine.origin_y`** (number). Default: `0`

The G-code Y of the front left corner of the bed. See `origin_x`.

**`machine.max_height`** (number). Default: `250`

The highest part that the printer can make.

**`machine.bed_type`** (BedType). Default: `textured_pei_plate`

The build plate on the bed, for a printer with plates that change (Bambu Lab): the start G-code of the printer uses it ({curr_bed_type}), and the printer checks it against the plate that it sees.

### Nozzle

**`machine.nozzle_diameter`** (number). Default: `0.4`

The diameter of the nozzle hole. The default line width comes from it.

**`machine.nozzle_type`** (one of: `hardened_steel`, `stainless_steel`, `tungsten_carbide`, `brass`). Default: `hardened_steel`

The material of the nozzle. A Bambu Lab printer checks it against the nozzle that it has (the file names it), and a hard filament (with carbon or glass fiber) needs hardened steel or tungsten carbide.

**`machine.nozzle_flow`** (one of: `standard`, `high_flow`). Default: `standard`

The flow of the hot end: `standard`, or `high_flow` (a longer melt zone). A Bambu Lab printer checks it against its nozzle.

**`machine.nozzle_tip_radius`** (number). Default: `0.5`

The radius of the flat face at the tip of the nozzle, around the hole. A common brass nozzle has a face about 1 mm across. Slope smoothing uses it to keep the nozzle off the layer that it just printed.

**`machine.nozzle_cone_angle`** (number). Default: `45`

The angle between the axis of the nozzle and the side of its cone, in degrees. Slope smoothing uses it with `nozzle_tip_radius`.

### Chamber and fans

**`machine.chamber_temp`** (number). Default: `25`

The temperature of the air around the print, in °C: the room for an open printer, about 35 to 45 in a closed box with no heater, or the set point of a heated chamber. The simulated print cools the plastic toward it.

**`machine.part_fan_air`** (number). Default: `6`

The speed of the air of the part cooling fans at full speed where the plastic leaves the nozzle, in m/s, of all the fans together. The simulated print cools the plastic with it. About 5 to 10 for a radial blower and a duct.

### Motion

**`machine.max_speed`** (number). Default: `150`

The maximum speed of the print head in X and Y.

**`machine.travel_speed`** (number). Default: `150`

The speed of travel moves (moves with no extrusion).

**`machine.first_layer_travel_speed`** (number). Default: `0`

The speed of the travel moves of the first layer, in mm/s. A slower travel does not pull the new lines off the bed. 0: `travel_speed`. As "Initial Layer Travel Speed" in Cura and "Initial layer travel speed" in OrcaSlicer.

**`machine.max_z_speed`** (number). Default: `10`

The speed of Z moves at each layer change.

**`machine.max_z_accel`** (number). Default: `100`

The acceleration of Z moves (the layer change and the z hop), in mm/s². Only the time estimate uses it.

**`machine.hour_rate`** (number). Default: `0`

The cost of one hour of this printer, in your currency: the power, the wear, and the time of the machine. A print costs its hours times this, and its filament. 0: only the filament counts.

**`machine.max_accel`** (number). Default: `1500`

The acceleration of the print head in X and Y, in mm/s². The time estimate uses it, and it is the acceleration of each feature that has no acceleration of its own (0 in `outer_wall_accel` and the others).

**`machine.corner_speed`** (number). Default: `8`

The speed at which the head turns a corner with no stop (jerk in Marlin, square corner velocity in Klipper), in mm/s. The time estimate uses it.

**`machine.kinematics`** (one of: `cartesian`, `corexy`). Default: `cartesian`

How the motors move the head, for the time estimate. `cartesian`: a motor for X and one for Y (also a bed slinger, which moves the bed on Y). `corexy`: two motors, A = X + Y and B = X - Y, both on the frame. With per-axis limits (`max_accel_x` and the others) and Marlin, the limits of a CoreXY apply to its motors: a diagonal move turns one motor at 1.41 times the speed of the head.

**`machine.max_accel_x`** (number). Default: `0`

The acceleration limit of the X axis (of motor A on a CoreXY with Marlin), in mm/s², as the firmware has it (M201 X). 0: `max_accel`. Klipper has one limit for all directions: leave it at 0.

**`machine.max_accel_y`** (number). Default: `0`

The acceleration limit of the Y axis (of motor B on a CoreXY with Marlin), in mm/s² (M201 Y). A bed slinger moves the bed on Y and has a lower limit. 0: `max_accel`.

**`machine.max_speed_x`** (number). Default: `0`

The speed limit of the X axis (M203 X), in mm/s. 0: `max_speed`.

**`machine.max_speed_y`** (number). Default: `0`

The speed limit of the Y axis (M203 Y), in mm/s. 0: `max_speed`.

**`machine.accel_control`** (true or false). Default: `false`

Write acceleration commands in the G-code: the acceleration of each feature (`outer_wall_accel` and the others), and the corner speed at the start. Off: the printer uses its own values; the time estimate still uses `max_accel` and `corner_speed`.

**`machine.gcode_flavor`** (one of: `marlin`, `klipper`, `reprap`, `repetier`). Default: `marlin`

The G-code dialect of the acceleration commands. `marlin`: M204 S and M205 X Y. `klipper`: SET_VELOCITY_LIMIT ACCEL and SQUARE_CORNER_VELOCITY. `reprap` (RepRapFirmware): M204 P T and M566 X Y. `repetier`: M201 X Y and M207 X.

### Acceleration

**`machine.outer_wall_accel`** (number; per layer). Default: `0`

The acceleration of the outer wall, in mm/s². A lower value gives a cleaner surface. 0: `max_accel`. The G-code has it only with `accel_control`. Each printer has its own value.

**`machine.inner_wall_accel`** (number; per layer). Default: `0`

The acceleration of the inner walls and the skirt, in mm/s². 0: `max_accel`.

**`machine.skin_accel`** (number; per layer). Default: `0`

The acceleration of the skin, in mm/s². The bridges, the ironing, and the support interface use it too. 0: `max_accel`.

**`machine.infill_accel`** (number; per layer). Default: `0`

The acceleration of the sparse infill and the support, in mm/s². 0: `max_accel`.

**`machine.travel_accel`** (number; per layer). Default: `0`

The acceleration of travel moves, in mm/s². 0: `max_accel`.

**`machine.first_layer_accel`** (number). Default: `0`

The acceleration of all lines on the first layer, in mm/s². 0: the acceleration of each feature.

### Extruder

**`machine.extruder`** (one of: `direct`, `bowden`). Default: `direct`

The extruder type. `direct`: the motor is on the print head. `bowden`: the motor pushes the filament through a long tube.

**`machine.retract_length`** (number). Default: `0.8`

The retraction length of this extruder. A bowden extruder needs more.

**`machine.retract_speed`** (number). Default: `40`

The speed of the filament during a retraction.

### Filament change

**`machine.filament_change`** (one of: `pause`, `tool`). Default: `pause`

How the printer changes to another filament of the plate. `pause`: one filament path; the print pauses (M600) and you change the filament by hand. `tool`: a unit that feeds many filaments (a Bambu Lab AMS, a Prusa MMU) changes it with a tool change (T0, T1, and on).

**`machine.nozzles`** (integer). Default: `1`

The number of nozzles of the print head: 1, or 2 for a head with a second nozzle (the Bambu Lab X2D and H2D). Each filament prints with its own nozzle (`filament.nozzle`). The firmware calibrates the offset between the nozzles: the G-code has one frame for both.

**`machine.nozzle1_max_x`** (number). Default: `0`

The right edge of the area that the first nozzle reaches, in bed X (mm). The left nozzle of the H2D stops 25 mm from the right side. 0: the whole bed.

**`machine.nozzle1_max_height`** (number). Default: `0`

The highest z that the first nozzle reaches (mm). 0: `max_height`.

**`machine.nozzle2_min_x`** (number). Default: `0`

The left edge of the area that the second nozzle reaches, in bed X (mm). The second nozzle of the X2D stops 20.5 mm from the left side of the bed. 0: the whole bed.

**`machine.nozzle2_max_height`** (number). Default: `0`

The highest z that the second nozzle reaches (mm). 0: `max_height`.

**`machine.change_gcode`** (text). Default: `""`

The text of a filament change. Empty: zslice writes the command of the G-code flavor (M600 for a pause, Tn for a tool change). The variables of Bambu Studio and PrusaSlicer work here: {next_extruder}, {previous_extruder}, [next_filament_id], [flush_length], [new_filament_temp], [old_filament_temp], {layer_z}, {max_layer_z}, and {toolchange_count}.

**`machine.change_time`** (number). Default: `40`

The time of one filament change, in seconds, for the time estimate: the cut, the unload, the load, and the flush. A pause counts this time too, but the real time depends on you.

**`machine.flush_volume`** (number). Default: `140`

The plastic (mm³) that the nozzle flushes after a change to a filament of the same color. A change from a dark color to a light color flushes up to 5 times more (see `project.flush_multiplier`). A pause flushes nothing: you push the new filament through by hand.

### G-code

**`machine.thumbnails`** (text). Default: `""`

The pictures of the print at the top of the G-code, for the screen of the printer: sizes in pixels, as "300x300,32x32" (PNG, the form of PrusaSlicer and Klipper). Empty: none.

**`machine.label_objects`** (true or false). Default: `false`

Label each part in the G-code, so the printer can skip a part that fails and print the others: EXCLUDE_OBJECT_DEFINE, _START, and _END on Klipper (it needs [exclude_object] in printer.cfg), and M486 on Marlin and RepRapFirmware. Off by default.

**`machine.start_gcode`** (text). Default: (multi-line text)

```gcode
G90 ; absolute positions
M83 ; relative extrusion
M140 S{bed_temp}
M104 S{first_layer_nozzle_temp}
G28 ; home all axes
M190 S{bed_temp}
M109 S{first_layer_nozzle_temp}
```

The text before the print. These variables are replaced: {nozzle_temp}, {first_layer_nozzle_temp}, {bed_temp}, {standby_temp}, {layer_height}, {first_layer_height}, {first_layer_speed} (mm/s), {nozzle_diameter}, {filament_diameter}, {filament_name}, {machine_name}, and {job_name}. The variables and the expressions of Cura, PrusaSlicer, OrcaSlicer, and Bambu Studio also work. A line with a variable that has no value becomes a comment. If the text does not heat the nozzle or the bed, zslice heats them before it.

**`machine.end_gcode`** (text). Default: (multi-line text)

```gcode
M104 S0
M140 S0
M107
G91
G1 Z5 F600
G90
M84
```

The text after the print. The same values as in `start_gcode` are replaced.

## filament

Facts about the material.

### Filament

**`filament.name`** (text). Default: `"generic PLA"`

The name of the filament, for the G-code header.

**`filament.material`** (text). Default: `"PLA"`

The type of the plastic, for example "PLA", "PETG", "ABS", or "TPU". The Filament menu lists the rolls of this type.

**`filament.color`** (text). Default: `"#d0d0cc"`

The color of the filament, as "#rrggbb". The 3D view draws the print in this color.

**`filament.nozzle`** (integer). Default: `0`

The nozzle of this filament on a printer with two nozzles (`machine.nozzles = 2`): 0 is the main nozzle, 1 is the second one. On the X2D, the AMS feeds the main nozzle, and the external spool feeds the second one. A printer with one nozzle: 0.

**`filament.diameter`** (number). Default: `1.75`

The diameter of the filament.

**`filament.density`** (number). Default: `1.24`

g/cm^3. For the filament weight in the statistics.

**`filament.price_per_kg`** (number). Default: `25`

The price of one kilogram of this filament, in your currency. For the cost of a print (the filament weight times this price).

### Temperatures

**`filament.nozzle_temp`** (number; per layer). Default: `210`

The nozzle temperature from the second layer.

**`filament.first_layer_nozzle_temp`** (number). Default: `215`

The nozzle temperature on the first layer.

**`filament.bed_temp`** (number; per layer). Default: `60`

The bed temperature.

**`filament.first_layer_bed_temp`** (number). Default: `0`

The bed temperature on the first layer. From the second layer, the bed goes to `bed_temp` (M140, no wait). 0: `bed_temp` on all layers. As "Build Plate Temperature Initial Layer" in Cura and "Initial layer" bed temperature in OrcaSlicer.

### Flow

**`filament.max_flow`** (number; per layer). Default: `12`

The maximum plastic flow that the hot end melts with this filament. This limits the speed of wide and tall lines.

**`filament.flow_ratio`** (number; per layer). Default: `1.0`

A multiplier for all extrusion, to calibrate the flow.

**`filament.pressure_advance`** (number). Default: `0`

The pressure advance of this filament, in seconds: the firmware pushes the filament ahead of a speed change by this time. zslice writes it after the start G-code (M900 K on Marlin, SET_PRESSURE_ADVANCE on Klipper, M572 on RepRapFirmware). 0: no command, so the value of the firmware stays. As "Pressure advance" in OrcaSlicer (`enable_pressure_advance` and `pressure_advance`).

### Cooling

**`filament.fan_speed`** (number; per layer). Default: `1.0`

The part cooling fan speed, as a ratio.

**`filament.fan_off_layers`** (integer). Default: `1`

The fan is off for this number of layers at the start.

**`filament.fan_ramp_layers`** (integer). Default: `0`

After the layers with the fan off, the fan speed goes up in steps over this number of layers: layer k of the ramp (from 1) gets k / (ramp + 1) of the fan speed. 0: full speed at once.

**`filament.fan_max_speed`** (number; per layer). Default: `1.0`

The fan speed on short layers, as a ratio. See `fan_boost_time`.

**`filament.fan_boost_time`** (number; per layer). Default: `15`

A layer that takes less time than this (s) gets the fan at `fan_max_speed`.

**`filament.min_layer_time`** (number; per layer). Default: `6`

The shortest time (s) for one layer. A layer that takes less time prints slower, so that the plastic below has time to cool.

**`filament.min_speed`** (number; per layer). Default: `10`

The lowest print speed (mm/s) for the slow-down of `min_layer_time`.

**`filament.cooling_mode`** (one of: `slow_down`, `lap`; per layer). Default: `slow_down`

How a layer that takes less than `min_layer_time` gets its time to cool. `slow_down`: it prints slower. `lap`: it prints at the planned speed; then the nozzle goes up 1 mm and moves around the layer with the fan at full until the time is over, so the air blows on the new plastic. The lap keeps the planned speed of the walls.

**`filament.standby_temp`** (number). Default: `0`

A lower nozzle temperature for waits, for example while the printer probes the bed. The start G-code can use it as {standby_temp}. 0 is off.

### Size compensation

**`filament.shrinkage_xy`** (number). Default: `1`

The part is printed larger by this ratio in X and Y, because the plastic shrinks as it cools. Example: 1.003 for 0.3 % shrinkage.

**`filament.shrinkage_z`** (number). Default: `1`

The part is printed taller by this ratio, for shrinkage in Z.

**`filament.xy_offset`** (number; per layer). Default: `0`

Moves all outlines out by this distance (in if negative). Use it if parts come out too large or too small by a fixed amount.

**`filament.hole_xy_offset`** (number; per layer). Default: `0`

Moves the edges of holes by this distance. A positive value makes holes larger. It adds to `xy_offset`, which makes holes smaller when it is positive. Holes often come out too small.

### Retraction

**`filament.retract_ratio`** (number; per layer). Default: `1.0`

A multiplier for the retraction length of the machine. Soft filament needs less.

### G-code

**`filament.start_gcode`** (text). Default: `""`

G-code after the start G-code of the machine, for this filament. The variables of the start G-code work here. Empty: none. As "Filament start G-code" in OrcaSlicer and PrusaSlicer.

**`filament.end_gcode`** (text). Default: `""`

G-code before the end G-code of the machine, for this filament. Empty: none. As "Filament end G-code" in OrcaSlicer and PrusaSlicer.

## project

What you want for this part.

### Layers

**`project.layer_height`** (number; per layer). Default: `0.2`

The height of each layer after the first. A smaller value gives a smoother surface and a longer print.

**`project.first_layer_height`** (number). Default: `0.3`

The height of the first layer. A thicker first layer sticks to the bed better.

### Lines

**`project.line_width`** (number; per layer). Default: `0`

The line width. 0 uses 1.1 x the nozzle diameter.

**`project.first_layer_line_width`** (number). Default: `0`

The line width on the first layer. 0 uses 1.25 x the nozzle diameter.

### Walls

**`project.wall_count`** (integer; per layer). Default: `2`

The number of walls (loops) around the outline of each layer.

**`project.wall_thickness`** (number; per layer). Default: `0`

The thickness of the walls, in mm, as in Cura: the wall count is this thickness divided by the line width, rounded (at least 1). 0: use `wall_count`.

**`project.wall_order`** (one of: `inner_first`, `outer_first`; per layer). Default: `inner_first`

The order of the walls of each island. `inner_first`: the inner walls from the inside out, then the outer wall. The outer wall then lies against plastic, and an overhang prints better. `outer_first`: the outer wall first, then the inner walls from the outside in. The outer surface is then more exact (a better fit of holes and of parts that join), but an overhang can curl.

**`project.alternate_extra_wall`** (true or false; per layer). Default: `false`

One more wall on each odd layer (layers 1, 3, 5, and so on). The walls of two layers then interlock with the infill, and the part is stronger across its layers. Off by default.

**`project.overhang_wall_speed`** (number; per layer). Default: `1`

The speed of the parts of a wall that hang over air, as a ratio of the speed of the wall. A slower overhang has more time to cool, so it curls less. 1: the speed of the wall. A wall that hangs a whole line over air prints as a bridge (see `bridges`).

**`project.overhang_wall_fan`** (number; per layer). Default: `0`

The fan while a wall overhang prints, from 0 to 1. The fan does not go below the fan of the layer. 0: the fan of the layer.

**`project.overhang_wall_threshold`** (number; per layer). Default: `0.5`

How far a wall must hang over air to print as an overhang (see `overhang_wall_speed`): the part of its line width that is outside the layer below, from 0 to 1. With a 0.2 mm layer and a 0.44 mm line, 0.5 is a slope of about 48 degrees.

**`project.fuzzy_skin`** (one of: `off`, `outer_wall`, `outside`; per layer). Default: `off`

A rough surface: the nozzle moves to a random side along the outer wall, so the surface looks fuzzy and hides the layer lines and the seam. `off`: a smooth wall. `outer_wall`: each outer wall, the holes too. `outside`: only the outside of each part, and not its holes (a hole keeps its size). The first layer stays smooth.

**`project.fuzzy_skin_thickness`** (number; per layer). Default: `0.3`

Fuzzy skin: the width of the band of the random points, in mm. A point goes up to half of it to the outside or to the inside of the wall. Keep it below the line width.

**`project.fuzzy_skin_point_distance`** (number; per layer). Default: `0.8`

Fuzzy skin: the mean distance between the random points, in mm.

**`project.spiral_vase`** (true or false). Default: `false`

Spiral vase mode: after the bottom layers, each layer prints only the outer wall of the part, and the nozzle rises along it, so the wall is one spiral with no seam. The part prints as a vase: no top, no infill, no inner walls, no holes. For a part with one outline on each layer. The bottom layers (`bottom_thickness`) print as usual.

**`project.thin_walls`** (true or false; per layer). Default: `false`

Print parts of the outline that are thinner than one line width (a thin fin, a sheet, a label): a loop inside each thin part, with a narrower line, so that its two sides fill the thickness. Without it, these parts print nothing. Off by default.

**`project.seam`** (one of: `hidden`, `sharpest`, `rear`, `nearest`, `random`; per layer). Default: `hidden`

Where each wall loop starts and ends (the seam). `hidden`: at the point where the seam is hardest to see: an inside corner first, then an outside corner, toward the back, and not where the wall hangs over air; similar layers pick the same point, so the seam is one clean line. `sharpest`: in the deepest inside corner, or else in the sharpest outside corner, or else at the rear. `rear`: at the back of the part (the largest y), in one straight line. `nearest`: at the point nearest to the nozzle, which is the fastest. `random`: at a different point on each layer, so that no seam line shows.

**`project.seam_corner`** (one of: `auto`, `none`, `inner`, `outer`, `any`, `weighted`; per layer). Default: `auto`

The corners that the `sharpest` seam looks for, as "Seam Corner Preference" in Cura. `auto`: the zslice score (an inside corner, or else the sharpest outside corner). `inner`: inside corners, the sharper the better. `outer`: outside corners. `any`: the sharpest corner of either kind. `weighted`: any corner, but an inside corner counts twice. `none`: no corner, so the seam goes to the back right. With the other kinds of seam it has no effect.

**`project.wall_generator`** (one of: `classic`, `arachne`; per layer). Default: `classic`

The method that makes the walls. `classic`: each wall is the outline moved in by a whole number of line widths, with one line width. `arachne`: the walls follow the center lines of the part, and the width of each line changes along it, so that a whole number of lines fills the part. A part thinner than two lines gets one line in its middle, so `thin_walls` has no effect. This is the method of Cura and the other open source slicers.

**`project.min_wall_line_width`** (number; per layer). Default: `0`

Arachne: the narrowest wall line. Where the wall count changes, the lines go from this width to two times this width. 0 uses 0.85 x the nozzle diameter.

**`project.min_feature_size`** (number; per layer). Default: `0`

Arachne: parts thinner than this print nothing. A thicker part that is thinner than a line gets one line of at least `min_bead_width`. 0 uses 1/4 of the line width.

**`project.min_bead_width`** (number; per layer). Default: `0`

Arachne: the narrowest line in a part thinner than a line. 0 uses `min_wall_line_width`.

**`project.wall_transition_length`** (number; per layer). Default: `0`

Arachne: the length over which one line splits into two, or two join into one, where the wall count changes. 0 uses the line width.

**`project.wall_transition_angle`** (number; per layer). Default: `10`

Arachne: in a wedge with a larger angle than this (in degrees), the wall count does not change along the middle: the walls follow the sides, and no line fills the middle.

**`project.wall_transition_filter_distance`** (number; per layer). Default: `100`

Arachne: two changes of the wall count closer together than this cancel out, so that the walls do not go back and forth.

**`project.wall_distribution_count`** (integer; per layer). Default: `1`

Arachne: the number of walls, counted from the middle, that share a change of the line width. 1: only the middle line changes, and the outer walls keep their width.

### Top and bottom skin

**`project.top_thickness`** (number; per layer). Default: `0.8`

The thickness of solid skin under each top surface.

**`project.bottom_thickness`** (number; per layer). Default: `0.6`

The thickness of solid skin above each bottom surface.

**`project.skin_removal_width`** (number; per layer). Default: `0.2`

Skin pieces narrower than this are removed before the expand (a sliver of skin at the edge of a slope). A thin piece next to a large skin area still gets skin from the expand.

**`project.skin_expand_distance`** (number; per layer). Default: `0.8`

The skin grows this far into the sparse infill next to it, so that its edges hold on the infill and close against the walls.

**`project.solid_infill_width`** (number; per layer). Default: `1.5`

A sparse infill area narrower than this prints solid, as skin. A narrow strip would get no infill lines, and a gap would show next to the walls under a top surface.

**`project.skin_pattern`** (one of: `lines`, `monotonic`, `concentric`; per layer). Default: `lines`

How the skin is filled. `lines`: parallel lines in the nearest order. `monotonic`: parallel lines from one side to the other, so each line lies against the line before it in the same way; the top has an even sheen. `concentric`: loops that follow the outline.

**`project.angles_follow_part`** (true or false). Default: `true`

The skin and infill lines turn with the part: the turn of a part on the bed adds to `skin_angle` and `infill_angle`, so the lines keep their place on the part. Off: the angles are from the X axis of the bed for each part.

**`project.skin_angle`** (number; per layer). Default: `45`

The direction of the skin lines on the first layer, in degrees from the X axis. Ironing goes at a right angle to the top skin.

**`project.skin_angle_step`** (number; per layer). Default: `90`

How much the skin direction turns from one layer to the next, in degrees. 90 crosses the lines of each layer with the layer below.

**`project.skin_overlap`** (number; per layer). Default: `0.15`

Skin lines go this far into the walls, as a fraction of the line width, so that the skin bonds to the walls.

**`project.skin_link_length`** (number; per layer). Default: `15`

Retractless skin: the top and bottom skin of each island prints as few paths as it can. The skin lines split into pieces at holes and corners, and each piece prints as one zigzag. From the end of a zigzag, the nozzle goes on to the next zigzag along the walls, and prints on the way, if that way is at most this long (mm). A travel and a retraction come only where no such way is. The way can go over skin that is printed already: it adds a little plastic along the wall. The zigzags just below a zigzag print before it, so at a hole both sides fill before the skin over the hole. 0: off, each piece prints on its own. Only for the `lines` pattern.

**`project.bridges`** (true or false; per layer). Default: `true`

Print bridges as bridges: the part of a bottom skin over air that solid plastic holds at its sides prints in straight lines across the air (the direction with the most lines that start and end on solid plastic), each line anchored on the solid skin around it, slower (`bridge_speed`), with `bridge_flow` and `bridge_fan`. The parts of the walls over air (1 mm or longer) print as bridges too. Off: the bridge prints as normal skin and walls.

**`project.bridge_speed`** (number; per layer). Default: `0.3`

The speed of the bridge lines, as a ratio of the allowed speed. A slow line sags less.

**`project.bridge_flow`** (number; per layer). Default: `0.95`

The flow of the bridge lines, as a ratio of the flow of a normal line. A little less flow makes a thinner strand that cools fast.

**`project.bridge_fan`** (number; per layer). Default: `1.0`

The fan speed while the bridge lines print, from 0 to 1.

**`project.path_rules`** (text). Default: `""`

Rules for each path, one on each line: "speed = ...", "flow = ...", or "fan = ...", with a formula (see the formulas of the settings). The variables of a path: {feature} ("outer_wall", "inner_wall", "skin", "infill", "bridge", ...), {layer} (from 0), {z} (mm), {part}, {speed} (the planned speed, mm/s), {width} and {height} (mm), {length} (mm), and {fan} (0 to 1). "speed" sets the speed in mm/s, "flow" multiplies the flow, and "fan" sets the fan (0 to 1) while the path prints. For example: speed = {feature} == "outer_wall" and {z} < 5 ? 20 : {speed}. A line that does not work is left out.

**`project.gap_fill`** (true or false; per layer). Default: `true`

Fill the narrow areas that no wall and no skin line covers (a strip between two walls, a wedge of skin next to a hole) with a line along the middle of each area. The width of the line follows the width of the area. These lines print at the skin speed. A part thinner than one line gets a line from `thin_walls`, not from this setting.

### Infill

**`project.infill_density`** (number; per layer). Default: `0.2`

The fraction of the inside that the sparse infill fills, as a ratio. 0 makes the part hollow.

**`project.infill_pattern`** (one of: `lines`, `grid`, `triangles`, `trihexagon`, `cubic`, `gyroid`, `concentric`, `honeycomb`, `zigzag`, `flow`, `lightning`; per layer). Default: `grid`

The sparse infill pattern. `lines`: one direction on each layer, turned 90 degrees on the next layer. `grid`: two directions on each layer. `triangles`: three directions at 60 degrees on each layer, which cross at the same points, so they make triangles. `trihexagon`: the three directions of `triangles`, with the third set moved by half its spacing, so the lines make triangles and hexagons (as in Cura). `cubic`: three directions that move with the height, so the infill makes cubes in 3D. `gyroid`: smooth curves that change with the height, strong in all directions. `concentric`: loops that follow the outline. `honeycomb`: hexagon cells, the same on all layers. `zigzag`: the lines of `lines`, joined at the walls into one path, so the nozzle does not travel or retract between them. `flow`: the zigzag, with twice the density under each top surface (a band of 3 times the top thickness, at least 2 mm), where the top skin needs it, and the density of the setting in the middle. `lightning`: thin branches only under the top surfaces; they grow down from each top, join into trees, and end at the walls, so most of the inside stays empty. For display parts: it is fast and uses little plastic, but it is weak. The density sets the distance between the branches under a top.

**`project.infill_angle`** (number; per layer). Default: `45`

The angle of the infill and skin lines, in degrees from the X axis.

**`project.infill_angles`** (text; per layer). Default: `""`

A list of infill angles in degrees from the X axis, with commas between them, one for each layer in turn: "45,45,45,135,135,135" prints 3 layers at 45 degrees, then 3 layers at 135 degrees, and again. The line patterns (lines, zigzag, flow, grid, triangles, trihexagon, cubic, honeycomb) use the angle of the layer in place of `infill_angle`, and the lines and zigzag patterns do not turn by 90 degrees on each layer. Empty: `infill_angle`. As "Infill Line Directions" in Cura.

**`project.infill_stack`** (true or false; per layer). Default: `false`

Keep the infill of all layers on top of each other: the lines, zigzag, and flow patterns do not turn by 90 degrees on each layer. The lines of each layer lie on the lines of the layer below, and make vertical walls, for example the openings of a grille. Grid, triangles, trihexagon, honeycomb, and concentric stack in each case. Honeycomb also prints each cell wall once, so all its walls have one width (else two of the six sides of a cell print twice).

**`project.infill_anchor`** (one of: `part`, `bed`; per layer). Default: `part`

Where the grid of the sparse infill starts. "part": at the center of each part, so a part with two equal sides gets equal infill on both, and the copies of a part get the same infill. "bed": at the origin of the bed, as before.

**`project.infill_flow`** (number; per layer). Default: `1.0`

The flow of the sparse infill lines, as a ratio of the flow of a normal line. As "Infill Flow" in Cura.

**`project.infill_connect`** (true or false; per layer). Default: `true`

Join the infill lines (lines, grid, triangles, cubic) at their ends with a short line along the edge, as "Connect Infill Lines" in Cura: the nozzle prints a zigzag with no travel and no retraction, and the joints tie the infill to the walls. Off: each line on its own.

**`project.infill_ribs`** (true or false; per layer). Default: `true`

A rib in each narrow infill area that the infill lines miss: one line along the length of the area, through its middle, on each layer, so the lines stack into a rib. At a low density the lines are far apart (10 % grid: 11 mm), and an area narrower than that gets no infill on most layers; the top over it then sags. Off: such an area stays empty.

**`project.lightning_angle`** (number). Default: `40`

The lightning infill: how far a branch leans from vertical, in degrees. On each layer down, the end of a branch gets shorter by the layer height times tan(angle), and a bent branch gets straighter by at most the same distance. A larger angle gives smaller trees and less plastic, but the lines hang out more over the layer below.

**`project.top_support_layers`** (integer; per layer). Default: `2`

Top support: the layers under each top skin that get denser infill lines (one direction on each layer, turned 90 degrees on the next), so that the skin lies on a flat grid and bridges less. 0: off. The flow pattern has its own band.

**`project.top_support_density`** (number; per layer). Default: `0.5`

The density of the top support lines, as a ratio. It works only if it is more than `infill_density`.

**`project.infill_overlap`** (number; per layer). Default: `0.2`

Sparse infill lines go this far into the walls, as a fraction of the line width.

**`project.infill_layers`** (integer; per layer). Default: `1`

Print the sparse infill once every this many layers, as one taller bead at the top layer of each group, with the flow of all the layers. The walls and the skin still print on each layer. Sparse infill is hidden, so it does not need the fine layers, and the print has fewer infill moves. A group is never thicker than the nozzle diameter: the count goes down where the layers are too thick. Only the area that is sparse infill in all layers of a group gets the tall bead, and the dense band under the top skin prints on each layer. 1: each layer.

### Ironing

**`project.ironing`** (true or false; per layer). Default: `false`

Iron the top surfaces. After the layer is complete, the nozzle goes over each top surface again with close lines and a small flow. The hot nozzle melts the surface flat, and the small flow fills the gaps between the skin lines.

**`project.ironing_flow`** (number; per layer). Default: `0.1`

The flow of the ironing lines, as a ratio of the flow of a normal line.

**`project.ironing_spacing`** (number; per layer). Default: `0.1`

The distance between the ironing lines.

**`project.ironing_inset`** (number; per layer). Default: `0.3`

The ironing area is this far inside the edges of the top surface, so that the nozzle does not push plastic over the edges.

**`project.ironing_speed`** (number; per layer). Default: `0.15`

The ironing speed, as a ratio of `machine.max_speed`. The flow limit of the filament does not apply, because the flow is small.

### Slope smoothing

**`project.slope_smoothing`** (true or false; per layer). Default: `false`

Fill the steps on gently sloped top surfaces. After each layer, the nozzle goes back along the edge of the layer, over the narrow ledge of the layer below. It lays a bead in the corner of each step, with the volume of the triangle there. The nozzle height can change along the bead, between the two layers.

**`project.slope_smoothing_min_width`** (number; per layer). Default: `0.3`

The narrowest ledge that gets a bead, as a ratio of the line width. A narrower step is small, and its bead is too small to meter.

**`project.slope_smoothing_max_width`** (number; per layer). Default: `2`

The widest ledge that gets a bead, as a ratio of the line width. A wider ledge is a flat top, or needs more than one bead.

**`project.slope_smoothing_flow`** (number; per layer). Default: `1`

The plastic of a smoothing bead, as a ratio of the volume of the triangle in the step.

**`project.slope_smoothing_speed`** (number; per layer). Default: `0.3`

The speed of the smoothing beads, as a ratio of the allowed speed.

**`project.slope_ironing`** (true or false; per layer). Default: `false`

Iron the sloped steps. After each layer (and after its smoothing beads), the nozzle goes along the same ledges as slope smoothing, with a very small flow. At each point, the nozzle tip is at the height of the filled step there, so the hot tip makes the bead tops flat. The ledges are the ones of `slope_smoothing_min_width` and `slope_smoothing_max_width`.

**`project.slope_ironing_passes`** (integer; per layer). Default: `2`

The number of ironing passes over each ledge, evenly across it.

**`project.slope_ironing_flow`** (number; per layer). Default: `0.1`

The flow of the slope ironing lines, as a ratio of the flow of a normal line.

**`project.slope_ironing_speed`** (number; per layer). Default: `0.15`

The slope ironing speed, as a ratio of `machine.max_speed`. The flow limit of the filament does not apply, because the flow is small.

### Speed ratios

**`project.outer_wall_speed`** (number; per layer). Default: `0.5`

The outer wall speed, as a ratio of the allowed speed. A slower outer wall gives a better surface.

**`project.inner_wall_speed`** (number; per layer). Default: `0.8`

The inner wall speed, as a ratio of the allowed speed.

**`project.skin_speed`** (number; per layer). Default: `0.7`

The skin speed, as a ratio of the allowed speed.

**`project.infill_speed`** (number; per layer). Default: `1.0`

The sparse infill speed, as a ratio of the allowed speed.

**`project.support_speed`** (number; per layer). Default: `0`

The speed of the support lines, as a ratio of the allowed speed. 0: `infill_speed`. As "Support Infill Speed" in Cura and "Support" speed in OrcaSlicer.

**`project.support_interface_speed`** (number; per layer). Default: `0`

The speed of the support interface, as a ratio of the allowed speed. 0: `skin_speed`. As "Support Interface Speed" in Cura and "Support interface" speed in OrcaSlicer.

**`project.first_layer_speed`** (number). Default: `0.3`

The speed of all lines on the first layer, as a ratio of the allowed speed.

**`project.slow_layers`** (integer). Default: `0`

The layers after the first that print slower: their speed goes up in even steps from the first layer speed to the full speed, so that the part bonds to the bed. 0: the second layer prints at full speed.

### Travel

**`project.retract_min_travel`** (number; per layer). Default: `1.5`

Travel moves shorter than this do not retract.

**`project.combing`** (true or false; per layer). Default: `true`

Combing: a travel move that stays inside the part (it crosses no outline of the layer) does not retract, because an ooze there is inside the part. Off: each travel longer than `retract_min_travel` retracts.

**`project.combing_max_distance`** (number; per layer). Default: `0`

A travel inside the part that is longer than this retracts all the same (a long move can ooze a string over a top surface). 0: no limit.

**`project.z_hop`** (number; per layer). Default: `0`

Lift the nozzle by this distance during a travel move with a retraction. 0 turns it off.

**`project.retract_wipe`** (true or false; per layer). Default: `false`

A retraction after a line of the part moves the nozzle on a small arc inside the part while the filament pulls back, as a hand wipes a drip off: the plastic that oozes goes inside, and not onto the surface. The arc stays inside the layer, or the retraction stays plain.

**`project.outer_wall_wipe`** (number; per layer). Default: `0`

After a closed outer wall, the nozzle moves on along the start of the wall for this distance (mm), with no plastic, before the retraction. The end of the wall then joins its start with no gap, and the seam shows less. 0 turns it off.

**`project.z_hop_only_crossing`** (true or false). Default: `true`

Lift the nozzle (`z_hop`) only for a travel that crosses an edge of the layer: it leaves the part, or it goes over a hole. A travel in a straight line inside the part (it retracts because it is longer than `combing_max_distance`) does not lift. Off: each travel with a retraction lifts.

**`project.retract_layer_change`** (true or false). Default: `false`

Retract at each layer change. Off: the travel to the first path of the layer retracts by the rules of the other travels (combing). Off by default, as in Cura.

### Support

**`project.support`** (one of: `off`, `everywhere`, `buildplate`). Default: `off`

Support under overhangs. `off`: no support. `everywhere`: support can stand on the bed or on the part. `buildplate`: only support that stands on the bed.

**`project.support_style`** (one of: `grid`, `tree`, `bridge`). Default: `grid`

The shape of the support. `grid`: all the space under each overhang, filled with lines. `tree`: branches from points under each overhang down to the bed or the part; they join on the way, get thicker as they go down, and thinner in narrow spaces (so a branch can go down a deep, narrow hole). Each branch prints as one wall loop, with lines only at its foot and under its tip. A tree uses less plastic and comes off more easily. `bridge`: only a sacrificial pad under each overhang (the interface layers, with the Z gap over it), with nothing under the pad. The pad bridges from the part around it, as a bridge does, and breaks off easily. For overhangs over a hole or a short gap, where a column down to the bed would be a waste.

**`project.support_tree_angle`** (number). Default: `50`

Tree support: the largest angle of a branch from vertical, in degrees. A larger angle lets branches reach farther, with less strength.

**`project.support_tree_spacing`** (number). Default: `3`

Tree support: the distance of the tips under an overhang. Tips also go along the edges of each overhang, at the same distance.

**`project.support_tree_tip`** (number). Default: `0`

Tree support: the diameter of a tip. 0 uses the line width times 2.

**`project.support_angle`** (number). Default: `50`

An overhang that leans more than this angle (degrees) from vertical gets support. A larger angle gives less support.

**`project.support_min_ledge`** (number). Default: `0`

No support under a small ledge: a strip of overhang that is within this distance (mm) of the layer below at each point, with no new overhang on the layer above next to it (for example the underside of an embossed letter on a wall). The nozzle prints it as a short cantilever. A slope keeps its support: each layer of it adds a new strip. 0: 1.5 line widths. A tiny value (0.01) turns the rule off.

**`project.support_density`** (number; per layer). Default: `0.15`

The fraction of the support area that the support lines fill, as a ratio.

**`project.support_xy_gap`** (number). Default: `0.6`

The gap between the support and the sides of the part. Under an overhang, the gap is at most half a line width: the Z gap keeps the support off the overhang there.

**`project.support_z_gap_layers`** (integer). Default: `1`

The number of empty layers between the support and the part above it or under it, so that the support comes off.

**`project.support_interface_layers`** (integer). Default: `2`

The number of dense layers at the top of the support, under the part. They make the bottom surface of the part smooth.

**`project.support_interface_density`** (number; per layer). Default: `0.7`

The fraction of the interface area that its lines fill, as a ratio.

**`project.support_interface_pattern`** (one of: `lines`, `grid`, `dots`). Default: `lines`

The pattern of the support interface. `lines`: parallel lines. `grid`: lines in two directions, a flatter bed for the part. `dots`: the lines cut into short dabs, in rows that shift on each layer: little contact with the part, so the support breaks off easily and leaves a cleaner surface.

### Skirt and brim

**`project.skirt_loops`** (integer). Default: `1`

The number of skirt loops. A skirt is a loop around the part on the first layers, at a distance from it. It primes the nozzle before the part starts. 0 turns it off.

**`project.skirt_distance`** (number). Default: `3`

The distance from the part (or from the brim) to the skirt.

**`project.skirt_layers`** (integer). Default: `1`

The number of layers with a skirt.

**`project.brim_width`** (number). Default: `0`

The width of the brim. A brim is loops on the first layer around the outside of the part, joined to it. It holds the part on the bed, and helps against warping. 0 turns it off.

**`project.brim_location`** (one of: `outside`, `inside`, `everywhere`). Default: `outside`

Where the brim goes. `outside`: around the outside of the part. `inside`: in the holes of the part, along their edges. `everywhere`: both.

### First layer

**`project.first_layer_xy_offset`** (number). Default: `0`

Moves the outline of the first layer by this distance. A negative value compensates the "elephant foot": the first layer spreads out because the nozzle presses it on the bed.

### Placement

**`project.placement`** (one of: `auto`, `file`, `center`). Default: `auto`

Where the part goes on the bed. auto: at the X and Y of the file if the part is fully on the bed there, else at the center of the bed; a model added to a plate with parts gets smart placement (its best orientation, then a free spot), and the parts on the plate stay. file: always at the X and Y of the file. center: always at the center of the bed. The bottom of the part always goes to z = 0.

### Experimental

**`project.fast_offsets`** (true or false). Default: `false`

An experiment: a faster offset of the outlines. A closing corner of an offset gets the crossing point of its two edges in place of a small loop that a union then removes. A slice uses about 11 % less CPU. The outer walls stay within about 1.4 micrometers; some skin and fill lines move more than that where a thin piece is at a threshold, so a thin piece of skin can come or go. Off: the offsets of before, and the same G-code. The switch is for the whole app: the last slice that starts sets it.

### Filaments

**`project.filament`** (integer; per layer). Default: `1`

The filament that prints this part, or these layers: 1 is the first filament of the plate, 2 the second, and so on. A change at a layer is a filament change in the G-code.

**`project.support_filament`** (integer). Default: `0`

The filament of the support: 1 is the first filament of the plate, 2 the second, and so on. 0: the filament of the part. A filament for support only (one that breaks away, or one that dissolves in water) makes support easy to take off. On a printer with two nozzles, the support prints with the nozzle of that filament.

**`project.support_interface_filament`** (integer). Default: `0`

The filament of the support interface (the layers that touch the part). 0: the support filament.

**`project.prime_tower`** (true or false). Default: `true`

A prime tower for a printer that changes the filament with a tool change (`machine.filament_change = tool`): after each change, the nozzle flushes the old color into a small tower next to the parts, and each layer up to the last change prints a light layer of it, so the tower grows with the print. A Bambu Lab printer flushes into its chute (its change G-code); its tower then gets a small prime.

**`project.prime_tower_split`** (true or false). Default: `true`

A prime tower for each family of materials that bond (PLA, PETG, ABS and ASA, and the others): a change purges into the tower of the new filament, so PETG never prints on PLA. Each of these towers grows only on the layers with a purge into it (no light layers): the nozzle goes down to its top. Keep parts away from the towers. With one family, one tower as before.

**`project.prime_tower_width`** (number). Default: `20`

The width of the square prime tower.

**`project.prime_tower_x`** (number). Default: `-1`

The x of the center of the prime tower on the bed. -1: near the right side.

**`project.prime_tower_y`** (number). Default: `-1`

The y of the center of the prime tower. -1: near the back.

**`project.flush_multiplier`** (number). Default: `1`

A multiplier for the flush volume of each filament change (see `machine.flush_volume`). Lower wastes less plastic. Too low mixes the old color into the new one.

**`project.flush_into_hidden`** (true or false). Default: `true`

After a change to a filament, the nozzle first prints the hidden lines of that filament on the layer: its sparse infill and its support body. The old color goes into them, so the flush of the change is less by their volume. A change between two families of materials (see `prime_tower_split`) flushes into the support body only. The walls and the skin print after.

**`project.paint_anchor_depth`** (number). Default: `1.0`

A painted feature that stands on the part, for example a raised letter or frame in another filament, grows down into the part by this depth (mm). This hidden root of its filament replaces the infill of the part under the feature, so the feature holds to the part. The root stays inside the walls of the part: the outside of the part keeps its color. Each layer of the root adds a filament change. 0: no root.

**`project.paint_anchor_shape`** (one of: `footprint`, `core`). Default: `footprint`

The shape of the root of a painted feature (see `paint_anchor_depth`). `footprint`: all the area where the feature stands on the part, inside the walls of the part. `core`: only the middle of that area, inside the walls of the feature. A thin feature gets no core.

## engine

Options for the engine. They do not change the print.

### Slicer

**`engine.resolution`** (number). Default: `0.005`

The largest change to the shape (mm) that the slicer makes when it removes points from the mesh outlines.

**`engine.gap_closing`** (number). Default: `1.0`

The largest gap (mm) that the slicer closes in a mesh with holes.

**`engine.threads`** (integer). Default: `0`

The number of threads. 0 uses one thread for each CPU but one, so that the app and the desktop can answer while a slice runs.

**`engine.job_name`** (text). Default: `""`

The name of the print, for {job_name} in the start and end G-code. The command line tool sets it to the model file name.

