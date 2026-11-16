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

## Printers

Open Preferences (the menu, or Ctrl+,). The Printers page lists your printers. Each printer has its own machine settings (the bed, the nozzle, the speeds, the start G-code) and a connection:

- None: export a G-code file.
- printdeck, or OctoPrint: the address of the printer and its API key.
- Moonraker (Klipper): the address of Moonraker.
- USB: the serial port and the speed. The app sends the print itself, line by line, so the computer must stay on while it prints.

"Test the connection" shows what the printer tells: its state, its bed and nozzle (OctoPrint, Moonraker), and the filament in it (printdeck). "Use the bed and nozzle of the printer" and "Use the filament in the printer" copy them to your settings.

Pick the printer in the menu at the left of the header bar. With a connection, "Send to" puts the G-code on the printer; its menu has "Send and print" and "Export a G-code file". The status bar shows the state of the printer and the progress of its print.

The API keys are in `~/.config/zslice/app.ini`, which only you can read.

## Your settings stay

The app saves the machine, filament, and project settings that you change, and loads them at the next start. They are in `~/.config/zslice/machine.toml`, `filament.toml`, and `project.toml`. Each file has only the settings that differ from the defaults, with the help of each one, in the profile format (see docs/user/profiles.md), so you can also edit them. If a file does not load, the app says why in its log and keeps a copy with the extension `.bad`.

## Browse the settings

The Settings page of the app has three columns:

1. The sections of each group (Project, Filament, Machine, Engine). The search field above them finds settings by name or help text.
2. The settings of the section, with their values.
3. The selected setting: its value, its default (with a Reset button), what it does, and the lines of your project that it changes, with their share of the print time.

The preview shows the lines that the setting changes in their feature colors, and the other lines become faint ghosts, so lines inside the part (infill) show. A section shows the lines of all its settings. Some settings change no line, and the preview shows marks for them:

- the seam: a red mark at the start of each outer wall loop (the 3D view also shows the small seam blob of a real print)
- travel moves: blue lines between the paths, lifted by the z hop
- retractions: pink marks where the filament pulls back

A setting that changes only the G-code (a temperature, for example) shows all lines in their feature colors, and its page says what it changes. Use Right and Left to move between the columns.

## See why a line is what it is

In the app, click a line in the 2D or 3D view. The Selected page shows what the line is (for example the outer wall on layer 12). At the top are its planned speed, its real speed (after the slow-down for cooling), and its plastic flow. Below them are the settings that change the line, in three sections: Speed, Shape, and Material. "How these values come about" explains each number.

Change a setting there, and the app slices again and shows the new values for the same line. The page stays where it is.

Changes on the Selected page are for the loaded part only, never for other prints. "Change for" says where they go: the whole part (all layers), this layer, this layer and up, or this layer and down. A changed setting shows in the accent color, with a button to remove the change. Some settings cannot change for some layers (for example the layer height); they are off in a layer choice. The printer settings are off on this page; change them in Settings. The Settings page has the defaults for all prints.

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

## The context menu

Right-click a line in the 3D view (or press Shift+F10 with a line selected) for the menu:

- **Add support here** › Grid, Tree, or Bridge (a pad): support of that kind under a 3 mm disk at that place, on that layer. It works also when support is off in the settings.
- **Block support here**: no support from the settings under that place.
- **Remove the support marks here**, and **Clear all support marks**.
- **Reset the view**.

A left drag turns the view, and a middle drag moves it. Right drag no longer turns the view; the right button opens the menu.

## Scrub through a layer

The bar at the bottom of the preview moves the nozzle through the top layer of the layer slider. At the left end, the layer starts; at the right end, the layer is done. The label gives the time in the layer. Play moves the bar, and a drag of the bar pauses the replay. A nozzle in the 3D view shows where the print is.

## Keys in the preview

Click in the preview first, so that it gets the keys.

| Key | With a selected line | With no selection |
|---|---|---|
| ← or h | The segment before it, in print order (Shift: the line before) | The nozzle back 2 % of the layer |
| → or l | The segment after it, in print order (Shift: the line after) | The nozzle on 2 % of the layer |
| ↑ or k | The nearest line on the layer above | The top layer up one |
| ↓ or j | The nearest line on the layer below | The top layer down one |
| Page Up, Page Down | 10 layers up or down | 10 layers up or down |
| Esc | Clears the selection | — |

A click on a line selects the line (yellow) and the segment under the pointer (orange). After the last segment of a line, → goes on to the first segment of the next line. Shift with ↑ or ↓ (or k or j) moves the bottom knob of the layer slider. A line of the same feature (for example an outer wall) wins over a line of another feature that is a little nearer. The layer slider follows the selection.

## More than one part

Open adds each model to the plate (Ctrl+O, or drop files on the window). The first part keeps the place of its file if it is on the bed there; a new part goes to a free place. "Arrange the plate" in the menu packs all parts in rows.

- A click on a line selects the line (its settings are on the Selected page).
- Shift+click adds a line to the selection (or takes it out). With more than one line, a change for "This layer" goes to the layers of all of them, and "This layer and up" (or down) starts at the lowest (or ends at the highest) of them.
- Ctrl+click on a part selects the part: a blue frame shows it on the bed, and the Selected page has its place, its turn, its scale, the placement, and "Remove".
- Ctrl+drag moves the selected part, and Ctrl+wheel turns it by 15°.

"Clear the plate" in the menu removes all parts.

### Placement

"Smart placement" in the menu turns each part for the least support, the most area on the bed, and a low height, and then arranges the plate. The part page (and the Placement submenu of the context menu) has the other ways:

- **Smart placement** for one part.
- **Less support**: the orientation with the least support only.
- **Strong along** X, Y, or Z of the part: say which way the load goes. A print is weakest across its layers, so the part turns until that axis lies in the layers, and then takes the least support.
- **Turn 90° about X** or **about Y**, and **Scale** (in %).
- **Put this side on the bed** (context menu of a line): the side of the part at that line goes down.
- **Reset**: the orientation and the size of the file.

## Save the plate

"Save the plate as 3MF" in the menu (Ctrl+S) writes one 3MF file with all parts at their places, and the changes that you made for the parts and for some layers. The global settings (Settings) do not go in the file. Open the 3MF file to get the plate back. zslice also opens 3MF files from other slicers; parts that touch in the file (for example a sign and its text) stay one part.

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
