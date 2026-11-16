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

The [settings reference](settings.md) explains each one.

### The three groups

The settings have three groups. Each group has a different owner:

| Group | What it describes | When it changes |
|---|---|---|
| `machine` | The printer: the bed size, the nozzle, the speed limits, the start and end G-code. | When you change the printer. |
| `filament` | The material: the diameter, the temperatures, the maximum flow, the cooling. | When you change the filament. |
| `project` | What you want for this part: the layer height, the walls, the skin, the infill. | For each part. |

The `engine` group has options that do not change the print, for example the number of threads.

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

zslice moves the part so that its bottom is at z = 0. With `project.auto_center=true` (the default), it also moves the center of the part to the center of the bed (`machine.bed_size_x` / 2, `machine.bed_size_y` / 2). With `project.auto_center=false`, the X and Y of the STL file stay as they are.
