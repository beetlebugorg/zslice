# The command line

The `zslice` tool slices a part with no window. Use it in scripts, on a server, or to check a slice. [Your first print](getting-started.md) explains the apps.

## Build zslice

You need Zig 0.17 (https://ziglang.org/download/).

```sh
git clone https://github.com/beetlebugorg/zslice
cd zslice
zig build -Doptimize=ReleaseFast
```

The tool is `zig-out/bin/zslice`. Copy it to a folder in your `PATH`, or use the full path.

## Slice a part

```sh
zslice slice part.stl -o part.gcode
```

zslice reads binary and ASCII STL files and 3MF files. It writes G-code for printers with Marlin or Klipper firmware. At the end, it shows a summary:

```
239 layers, 3.92 m filament (11.7 g), about 50 min, sliced in 383 ms
```

The time is an estimate. It uses the acceleration and the corner speed of the machine settings. The heat-up and the start G-code are not in it.

Without `-o`, zslice writes the G-code to the standard output.

## Change settings

Use `-s group.name=value` for each change:

```sh
zslice slice part.stl -o part.gcode \
  -s project.layer_height=0.15 \
  -s project.wall_count=3 \
  -s filament.nozzle_temp=220
```

Use `-m`, `-f`, and `-p` for a machine, a filament, and a project profile:

```sh
zslice slice part.stl -m generic -f generic-petg -p fine -o part.gcode
```

To see all settings and their default values:

```sh
zslice settings
zslice profiles      # the built-in profiles
```

The [settings reference](settings.md) explains each setting. To keep settings in files (one for your printer, one for each filament), see [Profiles](profiles.md).

### The three groups

The settings have three groups. Each group has a different owner:

| Group | What it describes | When it changes |
|---|---|---|
| `machine` | The printer: the bed size, the nozzle, the speed limits, the start and end G-code. | When you change the printer. |
| `filament` | The material: the diameter, the temperatures, the maximum flow, the cooling. | When you change the filament. |
| `project` | What you want for this part: the layer height, the walls, the skin, the infill. | For each part. |

The `engine` group has options that do not change the print, for example the number of threads.

### How much plastic

zslice computes the plastic for each line from the shape of a real bead. The nozzle presses the bead flat on the top and the bottom, and its sides are round. A line 0.44 mm wide and 0.2 mm tall has a cross section of 0.079 mm². If your lines come out too thin or too thick, calibrate `filament.flow_ratio`.

zslice 0.1 used a rectangle (width x height) for this area, as Cura does. That is about 11 % more plastic for this line. If you calibrated `flow_ratio` with zslice 0.1, calibrate it again.

### Speeds

A project does not set speeds in mm/s. It sets a ratio (0 to 1) for each feature, for example `project.outer_wall_speed=0.5`. zslice computes the allowed speed of each line from two limits:

1. The machine limit: `machine.max_speed`.
2. The flow limit of the filament: `filament.max_flow` divided by the cross section of the line (line width x layer height). A wide, tall line needs more plastic for each millimeter, so it must go slower.

The allowed speed is the lower of the two. The ratio of the feature then scales it. An example with the defaults: a 0.44 mm x 0.2 mm line can go at 12 / (0.44 x 0.2) = 136 mm/s. The outer wall ratio is 0.5, so the outer wall goes at 68 mm/s.

Thus one project works on a slow printer and on a fast printer, and with PLA and with TPU. Only the machine and filament settings change.

## Look at a layer

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
| Teal | Slope smoothing (beads in the steps of a sloped top) |
| Lime | Slope ironing (ironing over the steps of a sloped top) |
| Sky blue | Bridges |
| Gray dashes | Travel moves |

The light gray area is the outline of the layer. Each line has the width of the line, so you can see gaps and overlaps.

Layer numbers start at 0. If the number is too large, zslice shows the number of layers in the part.

### Try the demo part

```sh
zslice demo demo.stl
zslice preview demo.stl --layer 28 -o layer28.svg
```

The demo part is a wide box with a smaller box on top, and a tube. Layer 28 is just below the step. It has skin on the step and in the floor of the tube hole, and sparse infill under the upper box.

## Check a part

These commands print what the apps show in their Gaps and Check tools:

```sh
zslice gaps part.stl               # the gaps of each layer
zslice gaps part.stl --layer 49    # the gaps of one layer
zslice check part.stl              # what can make the print fail
```

## Other commands

| Command | What it does |
|---|---|
| `zslice printers` | Lists the printers of the printer library: the id, the firmware, the bed, and the name. `-m <id>` loads the machine profile of a printer. |
| `zslice profile project -p fine` | Writes the settings of one group (`machine`, `filament`, or `project`) as a profile file, with the options applied. Start a new profile from it. |
| `zslice import cura <folder> -o <profiles folder>` | Converts a Cura profile stack (a folder with `cura.json`) to zslice profiles. |
| `zslice import <file> [-o <profiles folder>]` | Converts a profile of PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura (`.ini`, `.json`, `.3mf`, `.curaprofile`). It writes the report of each value, and with `-o` the profiles. See [Profiles](profiles.md#import-from-prusaslicer-orcaslicer-bambu-studio-or-cura). |
| `zslice orient part.stl` | Lists the orientations that smart placement compares, with the cost of each, and the best one. |
| `zslice gcode file.gcode` | Reads a G-code file of any slicer, as the print view does. It prints the size, the layers, the moves, the box, the print time, the time to read it, and the peak memory. |

Run `zslice` with no command to see all commands and options.

## See which settings matter for a part

`zslice sweep` slices the part again and again. For each project and filament setting, it tries values across the usual range. The other settings keep their base values:

```sh
zslice sweep part.stl -m my-printer -f my-pla -p my-project -o sweep.tsv
```

The file has one row for each slice: the setting, the value, the print time, the plastic in grams, the cost, the travel, and the retractions. At the end, the tool lists the settings that change the print time and the cost of this part the most. The cost is the plastic weight times `filament.price_per_kg`.

- `--points N` sets the number of values for a number setting (default 5).
- `--only TEXT` sweeps only the settings with TEXT in their name.

A sweep of the Benchy (382 slices) runs for about 45 seconds.

## Measure the speed

`zslice bench part.stl` slices the part many times and prints the time of a full slice and of a slice after a change of one setting:

```
full slice     wall median   349.7 ms
late (infill)  wall median    62.4 ms
wall count     wall median   310.0 ms
```

These times are for a 3DBenchy on a desktop CPU from 2015 with 4 cores (8 threads).

`zslice bench part.stl --only draft` times the draft slice that an app can show during a drag: the outlines lose the points within 0.05 mm of a straight line, and the gaps get no fill. A draft of a 3DBenchy needs about a third of the CPU time of the full slice. The command line never writes the G-code of a draft.

`zslice bench part.stl --only sim --runs 1` slices the part once, then times the simulated print of the plastic (see [The print as it forms](../internals/print-sim.md)). `--only sim-side` turns the part on its side first, and `--only sim-flip` turns it upside down, for steep overhangs with no support. For a 3DBenchy:

```
simulate       wall median  1460.5 ms
simulate: 585778 masses, 21851 soft, peak 89 soft, 12272 moved in 481 paths, max move 7.77 mm, 11.69 g, 243723 steps, 7.0 MB more at the peak
```

With `-o masses.csv`, it also writes the masses that moved: the box of the part on the bed, then a row for each mass with its layer, its path, its feature, the place where the slicer meant it to be (`wx`, `wy`, `wz`), and the place where it set (`x`, `y`, `z`). `tools/calib/predict.py` reads this file for the calibration prints (see `tools/calib/README.md`).
