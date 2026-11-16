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

**`filament.standby_temp`** (number). Default: `0`

A lower nozzle temperature for waits, for example while the printer probes the bed. The start G-code can use it as {standby_temp}. 0 is off.

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

**`project.seam`** (one of: `sharpest`, `rear`, `nearest`, `random`). Default: `sharpest`

Where each wall loop starts and ends (the seam). `sharpest`: in the deepest inside corner, where the seam is hard to see, or else in the sharpest outside corner, or else at the rear. `rear`: at the back of the part (the largest y), in one straight line. `nearest`: at the point nearest to the nozzle, which is the fastest. `random`: at a different point on each layer, so that no seam line shows.

### Top and bottom skin

**`project.top_thickness`** (number). Default: `0.8`

The thickness of solid skin under each top surface.

**`project.bottom_thickness`** (number). Default: `0.6`

The thickness of solid skin above each bottom surface.

**`project.skin_overlap`** (number). Default: `0.15`

Skin lines go this far into the walls, as a fraction of the line width, so that the skin bonds to the walls.

### Infill

**`project.infill_density`** (number). Default: `0.2`

The fraction of the inside that the sparse infill fills, as a ratio. 0 makes the part hollow.

**`project.infill_pattern`** (one of: `lines`, `grid`). Default: `grid`

The sparse infill pattern. `lines`: one direction on each layer, turned 90 degrees on the next layer. `grid`: two directions on each layer.

**`project.infill_angle`** (number). Default: `45`

The angle of the infill and skin lines, in degrees from the X axis.

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

### Travel

**`project.retract_min_travel`** (number). Default: `1.5`

Travel moves shorter than this do not retract.

**`project.z_hop`** (number). Default: `0`

Lift the nozzle by this distance during a travel move with a retraction. 0 turns it off.

### Support

**`project.support`** (one of: `off`, `everywhere`, `buildplate`). Default: `off`

Support under overhangs. `off`: no support. `everywhere`: support can stand on the bed or on the part. `buildplate`: only support that stands on the bed.

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

### Placement

**`project.auto_center`** (true or false). Default: `true`

Move the part so that the center of its bounding box is at the center of the bed, and its bottom is at z = 0.

## engine

Options for the engine. They do not change the print.

### Slicer

**`engine.resolution`** (number). Default: `0.005`

The largest change to the shape (mm) that the slicer makes when it removes points from the mesh outlines.

**`engine.gap_closing`** (number). Default: `1.0`

The largest gap (mm) that the slicer closes in a mesh with holes.

**`engine.threads`** (integer). Default: `0`

The number of threads. 0 uses one thread for each CPU.

**`engine.job_name`** (text). Default: `""`

The name of the print, for {job_name} in the start and end G-code. The command line tool sets it to the model file name.

