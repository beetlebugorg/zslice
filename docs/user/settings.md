# Settings reference

<!-- Made by tools/settings_doc.py from src/settings.zig. Do not edit by hand. -->

Each setting has a name in the form `group.name`. Set it on the command line with `-s group.name=value`, in C with `zs_settings_set`, and in JavaScript as a key of the settings object.

Units: lengths in mm, speeds in mm/s, flow in mm³/s, temperatures in °C. A ratio is 0 to 1.

## machine

Facts about the printer. They change only when the printer changes.

### Printer

**`machine.name`** (text). Default: `"generic"`

The name of the printer, for the G-code header.

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

### Nozzle

**`machine.nozzle_diameter`** (number). Default: `0.4`

The diameter of the nozzle hole. The default line width comes from it.

### Motion

**`machine.max_speed`** (number). Default: `150`

The maximum speed of the print head in X and Y.

**`machine.travel_speed`** (number). Default: `150`

The speed of travel moves (moves with no extrusion).

**`machine.max_z_speed`** (number). Default: `10`

The speed of Z moves at each layer change.

**`machine.max_accel`** (number). Default: `1500`

The acceleration of the print head in X and Y, in mm/s². The time estimate uses it, and it is the acceleration of each feature that has no acceleration of its own (0 in the project).

**`machine.corner_speed`** (number). Default: `8`

The speed at which the head turns a corner with no stop (jerk in Marlin, square corner velocity in Klipper), in mm/s. The time estimate uses it.

**`machine.accel_control`** (true or false). Default: `false`

Write acceleration commands in the G-code: the acceleration of each feature (project `*_accel`), and the corner speed at the start. Off: the printer uses its own values; the time estimate still uses `max_accel` and `corner_speed`.

**`machine.gcode_flavor`** (one of: `marlin`, `klipper`). Default: `marlin`

The G-code dialect of the acceleration commands. `marlin`: M204 S and M205 X Y. `klipper`: SET_VELOCITY_LIMIT ACCEL and SQUARE_CORNER_VELOCITY.

### Extruder

**`machine.extruder`** (one of: `direct`, `bowden`). Default: `direct`

The extruder type. `direct`: the motor is on the print head. `bowden`: the motor pushes the filament through a long tube.

**`machine.retract_length`** (number). Default: `0.8`

The retraction length of this extruder. A bowden extruder needs more.

**`machine.retract_speed`** (number). Default: `40`

The speed of the filament during a retraction.

### G-code

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

The text before the print. These variables are replaced: {nozzle_temp}, {first_layer_nozzle_temp}, {bed_temp}, {standby_temp}, {layer_height}, {first_layer_height}, {first_layer_speed} (mm/s), {nozzle_diameter}, {filament_diameter}, {filament_name}, {machine_name}, and {job_name}.

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

**`filament.color`** (text). Default: `"#d0d0cc"`

The color of the filament, as "#rrggbb". The 3D view draws the print in this color.

**`filament.diameter`** (number). Default: `1.75`

The diameter of the filament.

**`filament.density`** (number). Default: `1.24`

g/cm^3. For the filament weight in the statistics.

### Temperatures

**`filament.nozzle_temp`** (number). Default: `210`

The nozzle temperature from the second layer.

**`filament.first_layer_nozzle_temp`** (number). Default: `215`

The nozzle temperature on the first layer.

**`filament.bed_temp`** (number). Default: `60`

The bed temperature.

### Flow

**`filament.max_flow`** (number). Default: `12`

The maximum plastic flow that the hot end melts with this filament. This limits the speed of wide and tall lines.

**`filament.flow_ratio`** (number). Default: `1.0`

A multiplier for all extrusion, to calibrate the flow.

### Cooling

**`filament.fan_speed`** (number). Default: `1.0`

The part cooling fan speed, as a ratio.

**`filament.fan_off_layers`** (integer). Default: `1`

The fan is off for this number of layers at the start.

**`filament.fan_max_speed`** (number). Default: `1.0`

The fan speed on short layers, as a ratio. See `fan_boost_time`.

**`filament.fan_boost_time`** (number). Default: `15`

A layer that takes less time than this (s) gets the fan at `fan_max_speed`.

**`filament.min_layer_time`** (number). Default: `6`

The shortest time (s) for one layer. A layer that takes less time prints slower, so that the plastic below has time to cool.

**`filament.min_speed`** (number). Default: `10`

The lowest print speed (mm/s) for the slow-down of `min_layer_time`.

**`filament.cooling_mode`** (one of: `slow_down`, `lap`). Default: `slow_down`

How a layer that takes less than `min_layer_time` gets its time to cool. `slow_down`: it prints slower. `lap`: it prints at the planned speed; then the nozzle goes up 1 mm and moves around the layer with the fan at full until the time is over, so the air blows on the new plastic. The lap keeps the planned speed of the walls.

**`filament.standby_temp`** (number). Default: `0`

A lower nozzle temperature for waits, for example while the printer probes the bed. The start G-code can use it as {standby_temp}. 0 is off.

### Size compensation

**`filament.shrinkage_xy`** (number). Default: `1`

The part is printed larger by this ratio in X and Y, because the plastic shrinks as it cools. Example: 1.003 for 0.3 % shrinkage.

**`filament.shrinkage_z`** (number). Default: `1`

The part is printed taller by this ratio, for shrinkage in Z.

**`filament.xy_offset`** (number). Default: `0`

Moves all outlines out by this distance (in if negative). Use it if parts come out too large or too small by a fixed amount.

**`filament.hole_xy_offset`** (number). Default: `0`

Moves the edges of holes by this distance. A positive value makes holes larger. It adds to `xy_offset`, which makes holes smaller when it is positive. Holes often come out too small.

### Retraction

**`filament.retract_ratio`** (number). Default: `1.0`

A multiplier for the retraction length of the machine. Soft filament needs less.

## project

What you want for this part.

### Layers

**`project.layer_height`** (number). Default: `0.2`

The height of each layer after the first. A smaller value gives a smoother surface and a longer print.

**`project.first_layer_height`** (number). Default: `0.3`

The height of the first layer. A thicker first layer sticks to the bed better.

### Lines

**`project.line_width`** (number). Default: `0`

The line width. 0 uses 1.1 x the nozzle diameter.

**`project.first_layer_line_width`** (number). Default: `0`

The line width on the first layer. 0 uses 1.25 x the nozzle diameter.

### Walls

**`project.wall_count`** (integer). Default: `2`

The number of walls (loops) around the outline of each layer.

**`project.wall_thickness`** (number). Default: `0`

The thickness of the walls, in mm, as in Cura: the wall count is this thickness divided by the line width, rounded (at least 1). 0: use `wall_count`.

**`project.thin_walls`** (true or false). Default: `true`

Print parts of the outline that are thinner than one line width (a thin fin, a sheet, a label): a loop inside each thin part, with a narrower line, so that its two sides fill the thickness. Without it, these parts print nothing.

**`project.seam`** (one of: `hidden`, `sharpest`, `rear`, `nearest`, `random`). Default: `hidden`

Where each wall loop starts and ends (the seam). `hidden`: at the point where the seam is hardest to see: an inside corner first, then an outside corner, toward the back, and not where the wall hangs over air; similar layers pick the same point, so the seam is one clean line. `sharpest`: in the deepest inside corner, or else in the sharpest outside corner, or else at the rear. `rear`: at the back of the part (the largest y), in one straight line. `nearest`: at the point nearest to the nozzle, which is the fastest. `random`: at a different point on each layer, so that no seam line shows.

### Top and bottom skin

**`project.top_thickness`** (number). Default: `0.8`

The thickness of solid skin under each top surface.

**`project.bottom_thickness`** (number). Default: `0.6`

The thickness of solid skin above each bottom surface.

**`project.skin_removal_width`** (number). Default: `0.2`

Skin pieces narrower than this are removed before the expand (a sliver of skin at the edge of a slope). A thin piece next to a large skin area still gets skin from the expand.

**`project.skin_expand_distance`** (number). Default: `0.8`

The skin grows this far into the sparse infill next to it, so that its edges hold on the infill and close against the walls.

**`project.solid_infill_width`** (number). Default: `1.5`

A sparse infill area narrower than this prints solid, as skin. A narrow strip would get no infill lines, and a gap would show next to the walls under a top surface.

**`project.skin_pattern`** (one of: `lines`, `monotonic`, `concentric`). Default: `lines`

How the skin is filled. `lines`: parallel lines in the nearest order. `monotonic`: parallel lines from one side to the other, so each line lies against the line before it in the same way; the top has an even sheen. `concentric`: loops that follow the outline.

**`project.skin_angle`** (number). Default: `45`

The direction of the skin lines on the first layer, in degrees from the X axis. Ironing goes at a right angle to the top skin.

**`project.skin_angle_step`** (number). Default: `90`

How much the skin direction turns from one layer to the next, in degrees. 90 crosses the lines of each layer with the layer below.

**`project.skin_overlap`** (number). Default: `0.15`

Skin lines go this far into the walls, as a fraction of the line width, so that the skin bonds to the walls.

### Infill

**`project.infill_density`** (number). Default: `0.2`

The fraction of the inside that the sparse infill fills, as a ratio. 0 makes the part hollow.

**`project.infill_pattern`** (one of: `lines`, `grid`, `triangles`, `cubic`, `gyroid`, `concentric`, `honeycomb`, `zigzag`, `flow`). Default: `grid`

The sparse infill pattern. `lines`: one direction on each layer, turned 90 degrees on the next layer. `grid`: two directions on each layer. `triangles`: three directions at 60 degrees on each layer. `cubic`: three directions that move with the height, so the infill makes cubes in 3D. `gyroid`: smooth curves that change with the height, strong in all directions. `concentric`: loops that follow the outline. `honeycomb`: hexagon cells, the same on all layers. `zigzag`: the lines of `lines`, joined at the walls into one path, so the nozzle does not travel or retract between them. `flow`: the zigzag, with twice the density under each top surface (a band of 3 times the top thickness, at least 2 mm), where the top skin needs it, and the density of the setting in the middle.

**`project.infill_angle`** (number). Default: `45`

The angle of the infill and skin lines, in degrees from the X axis.

**`project.infill_connect`** (true or false). Default: `true`

Join the infill lines (lines, grid, triangles, cubic) at their ends with a short line along the edge, as "Connect Infill Lines" in Cura: the nozzle prints a zigzag with no travel and no retraction, and the joints tie the infill to the walls. Off: each line on its own.

**`project.top_support_layers`** (integer). Default: `2`

Top support: the layers under each top skin that get denser infill lines (one direction on each layer, turned 90 degrees on the next), so that the skin lies on a flat grid and bridges less. 0: off. The flow pattern has its own band.

**`project.top_support_density`** (number). Default: `0.5`

The density of the top support lines, as a ratio. It works only if it is more than `infill_density`.

**`project.infill_overlap`** (number). Default: `0.2`

Sparse infill lines go this far into the walls, as a fraction of the line width.

### Ironing

**`project.ironing`** (true or false). Default: `false`

Iron the top surfaces. After the layer is complete, the nozzle goes over each top surface again with close lines and a small flow. The hot nozzle melts the surface flat, and the small flow fills the gaps between the skin lines.

**`project.ironing_flow`** (number). Default: `0.1`

The flow of the ironing lines, as a ratio of the flow of a normal line.

**`project.ironing_spacing`** (number). Default: `0.1`

The distance between the ironing lines.

**`project.ironing_inset`** (number). Default: `0.3`

The ironing area is this far inside the edges of the top surface, so that the nozzle does not push plastic over the edges.

**`project.ironing_speed`** (number). Default: `0.15`

The ironing speed, as a ratio of `machine.max_speed`. The flow limit of the filament does not apply, because the flow is small.

### Speed ratios

**`project.outer_wall_speed`** (number). Default: `0.5`

The outer wall speed, as a ratio of the allowed speed. A slower outer wall gives a better surface.

**`project.inner_wall_speed`** (number). Default: `0.8`

The inner wall speed, as a ratio of the allowed speed.

**`project.skin_speed`** (number). Default: `0.7`

The skin speed, as a ratio of the allowed speed.

**`project.infill_speed`** (number). Default: `1.0`

The sparse infill speed, as a ratio of the allowed speed.

**`project.first_layer_speed`** (number). Default: `0.3`

The speed of all lines on the first layer, as a ratio of the allowed speed.

**`project.slow_layers`** (integer). Default: `0`

The layers after the first that print slower: their speed goes up in even steps from the first layer speed to the full speed, so that the part bonds to the bed. 0: the second layer prints at full speed.

### Acceleration

**`project.outer_wall_accel`** (number). Default: `0`

The acceleration of the outer wall, in mm/s². A lower value gives a cleaner surface. 0: the machine `max_accel`. The G-code has it only with machine `accel_control`.

**`project.inner_wall_accel`** (number). Default: `0`

The acceleration of the inner walls and the skirt, in mm/s². 0: the machine `max_accel`.

**`project.skin_accel`** (number). Default: `0`

The acceleration of the skin, in mm/s². 0: the machine `max_accel`.

**`project.infill_accel`** (number). Default: `0`

The acceleration of the sparse infill and the support, in mm/s². 0: the machine `max_accel`.

**`project.travel_accel`** (number). Default: `0`

The acceleration of travel moves, in mm/s². 0: the machine `max_accel`.

**`project.first_layer_accel`** (number). Default: `0`

The acceleration of all lines on the first layer, in mm/s². 0: the acceleration of each feature.

### Travel

**`project.retract_min_travel`** (number). Default: `1.5`

Travel moves shorter than this do not retract.

**`project.combing`** (true or false). Default: `true`

Combing: a travel move that stays inside the part (it crosses no outline of the layer) does not retract, because an ooze there is inside the part. Off: each travel longer than `retract_min_travel` retracts.

**`project.combing_max_distance`** (number). Default: `0`

A travel inside the part that is longer than this retracts all the same (a long move can ooze a string over a top surface). 0: no limit.

**`project.z_hop`** (number). Default: `0`

Lift the nozzle by this distance during a travel move with a retraction. 0 turns it off.

### Support

**`project.support`** (one of: `off`, `everywhere`, `buildplate`). Default: `off`

Support under overhangs. `off`: no support. `everywhere`: support can stand on the bed or on the part. `buildplate`: only support that stands on the bed.

**`project.support_style`** (one of: `grid`, `tree`, `bridge`). Default: `grid`

The shape of the support. `grid`: all the space under each overhang, filled with lines. `tree`: branches from points under each overhang down to the bed or the part; they join on the way, get thicker as they go down, and thinner in narrow spaces (so a branch can go down a deep, narrow hole). A tree uses less plastic and comes off more easily. `bridge`: only a sacrificial pad under each overhang (the interface layers, with the Z gap over it), with nothing under the pad. The pad bridges from the part around it, as a bridge does, and breaks off easily. For overhangs over a hole or a short gap, where a column down to the bed would be a waste.

**`project.support_tree_angle`** (number). Default: `40`

Tree support: the largest angle of a branch from vertical, in degrees. A larger angle lets branches reach farther, with less strength.

**`project.support_tree_spacing`** (number). Default: `3`

Tree support: the distance of the tips under an overhang.

**`project.support_tree_tip`** (number). Default: `0`

Tree support: the diameter of a tip. 0 uses the line width times 2.

**`project.support_angle`** (number). Default: `50`

An overhang that leans more than this angle (degrees) from vertical gets support. A larger angle gives less support.

**`project.support_density`** (number). Default: `0.15`

The fraction of the support area that the support lines fill, as a ratio.

**`project.support_xy_gap`** (number). Default: `0.6`

The gap between the support and the sides of the part.

**`project.support_z_gap_layers`** (integer). Default: `1`

The number of empty layers between the support and the part above it or under it, so that the support comes off.

**`project.support_interface_layers`** (integer). Default: `2`

The number of dense layers at the top of the support, under the part. They make the bottom surface of the part smooth.

**`project.support_interface_density`** (number). Default: `0.7`

The fraction of the interface area that its lines fill, as a ratio.

### Skirt and brim

**`project.skirt_loops`** (integer). Default: `1`

The number of skirt loops. A skirt is a loop around the part on the first layers, at a distance from it. It primes the nozzle before the part starts. 0 turns it off.

**`project.skirt_distance`** (number). Default: `3`

The distance from the part (or from the brim) to the skirt.

**`project.skirt_layers`** (integer). Default: `1`

The number of layers with a skirt.

**`project.brim_width`** (number). Default: `0`

The width of the brim. A brim is loops on the first layer around the outside of the part, joined to it. It holds the part on the bed, and helps against warping. 0 turns it off.

### First layer

**`project.first_layer_xy_offset`** (number). Default: `0`

Moves the outline of the first layer by this distance. A negative value compensates the "elephant foot": the first layer spreads out because the nozzle presses it on the bed.

### Placement

**`project.placement`** (one of: `auto`, `file`, `center`). Default: `auto`

Where the part goes on the bed. auto: at the X and Y of the file if the part is fully on the bed there, else at the center of the bed. file: always at the X and Y of the file. center: always at the center of the bed. The bottom of the part always goes to z = 0.

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

