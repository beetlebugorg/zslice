# Getting started

## Build zslice

You need Zig 0.16 (https://ziglang.org/download/).

```sh
git clone <zslice repo> zslice
cd zslice
zig build -Doptimize=ReleaseFast
```

The tool is `zig-out/bin/zslice`. Copy it to a folder in your `PATH`, or use the full path.

## Slice a part

```sh
zslice slice part.stl -o part.gcode
```

zslice reads binary and ASCII STL files. It writes G-code for printers with Marlin or Klipper firmware. When it is done, it shows a summary:

```
69 layers, 1.88 m filament (5.6 g), about 11 min, sliced in 37 ms
```

The time is an estimate from the distance and the speed of each move. It does not include acceleration, so the real print takes longer.

Without `-o`, zslice writes the G-code to the standard output.

## Change settings

Use `-s group.name=value` for each change:

```sh
zslice slice part.stl -o part.gcode \
  -s project.layer_height=0.15 \
  -s project.wall_count=3 \
  -s filament.nozzle_temp=220
```

To see all settings and their default values:

```sh
zslice settings
```

The [settings reference](settings.md) explains each one. To keep settings in files (one for your printer, one for each filament), see [Profiles](profiles.md).

### The three groups

The settings have three groups. Each group has a different owner:

| Group | What it describes | When it changes |
|---|---|---|
| `machine` | The printer: the bed size, the nozzle, the speed limits, the start and end G-code. | When you change the printer. |
| `filament` | The material: the diameter, the temperatures, the maximum flow, the cooling. | When you change the filament. |
| `project` | What you want for this part: the layer height, the walls, the skin, the infill. | For each part. |

The `engine` group has options that do not change the print, for example the number of threads.

### How much plastic

zslice computes the plastic for each line from the shape of a real bead: the nozzle presses it flat on the top and the bottom, and its sides are round. A line 0.44 mm wide and 0.2 mm tall has a cross section of 0.079 mm². If your lines come out too thin or too thick, calibrate `filament.flow_ratio`.

zslice 0.1 used a rectangle (width x height) for this area, as Cura does. That is about 11 % more plastic for this line. If you calibrated `flow_ratio` with zslice 0.1, calibrate it again.

### Speeds

A project does not set speeds in mm/s. It sets a ratio (0 to 1) for each feature, for example `project.outer_wall_speed=0.5`. zslice computes the allowed speed of each line from two limits:

1. The machine limit: `machine.max_speed`.
2. The flow limit of the filament: `filament.max_flow` divided by the cross section of the line (line width x layer height). A wide, tall line needs more plastic for each millimeter, so it must go slower.

The allowed speed is the lower of the two. The ratio of the feature then scales it. Example, with the defaults: a 0.44 mm x 0.2 mm line can go at 12 / (0.44 x 0.2) = 136 mm/s. The outer wall ratio is 0.5, so the outer wall goes at 68 mm/s.

Thus one project works on a slow printer and on a fast printer, and with PLA and with TPU. Only the machine and filament settings change.

## Look at the layers

`preview` writes an SVG picture of one layer. Open it in a web browser.

```sh
zslice preview part.stl --layer 20 -o layer20.svg
```

| Color | Feature |
|---|---|
| Orange | Outer wall |
| Yellow | Inner walls |
| Blue | Skin (solid top and bottom fill) |
| Green | Sparse infill |
| Purple | Ironing |
| Brown | Skirt and brim |
| Light gray | Support |
| Dark gray | Support interface |
| Gray dashes | Travel moves |

The light gray area is the outline of the layer. Each line is drawn at the line width, so you can see gaps and overlaps.

Layer numbers start at 0. If the number is too large, zslice shows the number of layers in the part.

## Browse the settings

The Settings page of the app has three columns:

1. The sections of each group (Project, Filament, Machine, Engine). The search field above them finds settings by name or help text.
2. The settings of the section, with their values.
3. The selected setting: its value, its default (with a Reset button), what it does, and the lines of your project that it changes, with their share of the print time.

The preview shows the lines that the setting changes in their feature colors, and the other lines fade. Use Right and Left to move between the columns.

## See why a line is what it is

In the app, click a line in the 2D or 3D view. The Selected page shows what the line is (for example the outer wall on layer 12). At the top are its planned speed, its real speed (after the slow-down for cooling), and its plastic flow. Below them are the settings that change the line, in three sections: Speed, Shape, and Material. "How these values come about" explains each number.

Change a setting there, and the app slices again and shows the new values for the same line. The page stays where it is.

Each number has its unit after it. A ratio shows as a percentage: a skin speed of 70 % is 70 % of the speed that the machine and the filament allow.

To change a number:

- Type it. The app uses the value after a short pause, on Enter, or when you leave the field.
- Press Up or Down to step it by one unit of its last decimal place. Hold Shift for 10 steps, or Ctrl for a tenth of a step.
- Drag the name of the setting to the left or the right.
- Drag its slider. The slider covers the usual values. The preview follows as fast as the slicer can go: a change of the infill or the speeds keeps the walls and the skin areas of the last slice, so a new slice of a mid-size part takes less than 0.1 s.

A value out of the usual range shows in the warning color, and its tooltip gives the usual range. A value out of the limits of the setting (for example a 300 mm brim) is an error, and the tooltip gives the limits.

## Move the 3D view

| Mouse | Action |
|---|---|
| Left drag | Orbit: turn and tilt around the part; the bed stays level |
| Middle drag | Pan: move the view |
| Right drag | Rotate freely in any direction; the view can roll |
| Scroll | Zoom toward the pointer |
| Double-click | Reset the view (also removes a roll) |
| Left click | Pick a line (see below) |

## Watch the print

In the app, press the play button under the 3D and 2D switch. The 3D view shows the print as it grows, line by line, at the speed in the list (1x is the real speed). The layer slider follows. Move the slider to stop.

## Try the demo part

```sh
zslice demo demo.stl
zslice preview demo.stl --layer 28 -o layer28.svg
```

The demo part is a wide box with a smaller box on top, and a tube. Layer 28 is just below the step. It has skin on the step and in the floor of the tube hole, and sparse infill under the upper box.

## Iron the top surfaces

Ironing makes top surfaces smooth. After a layer with a top surface, the nozzle goes over that surface again with close lines (0.1 mm apart) and a small flow (10 % of a normal line). The hot nozzle melts the surface flat, and the small flow fills the gaps between the skin lines.

```sh
zslice slice part.stl -o part.gcode -s project.ironing=true
```

Ironing adds time: each top surface gets about 4 times as many lines as its skin. The settings `project.ironing_flow`, `project.ironing_spacing`, `project.ironing_inset`, and `project.ironing_speed` control it (see the [settings reference](settings.md#ironing)).

## Where the part goes on the bed

zslice moves the part so that its bottom is at z = 0. The X and Y come from `project.placement`:

- `auto` (the default): the X and Y of the file, if the part is fully on the bed there. If it is not (for example, a part modeled around the origin), zslice moves the center of the part to the center of the bed (`machine.bed_size_x` / 2, `machine.bed_size_y` / 2).
- `file`: always the X and Y of the file.
- `center`: always the center of the bed.

The X and Y of a file are bed coordinates: 0, 0 is the front left corner of the bed. If the G-code origin of your printer is somewhere else (for example the bed center), set `machine.origin_x` and `machine.origin_y` to the G-code position of the front left corner. For a printer with the origin at the bed center, they are minus half the bed size. The Cura import sets them from `machine_center_is_zero`.
