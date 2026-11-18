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

The time is an estimate with the acceleration and the corner speed of the machine settings. Heat-up and the start G-code are not in it.

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

### See which settings matter for a part

`zslice sweep` slices the part again and again. For each project and filament setting, it tries values across the usual range, with the other settings at their base values:

```sh
zslice sweep part.stl -m my-printer -f my-pla -p my-project -o sweep.tsv
```

The file has one row for each slice: the setting, the value, the print time, the plastic in grams, the cost, the travel, and the retractions. At the end, the tool lists the settings that change the print time and the cost of this part the most. The cost is the plastic weight times `filament.price_per_kg`. `--points N` sets the number of values for a number setting (default 5), and `--only TEXT` sweeps only the settings with TEXT in their name. A sweep of the Benchy (382 slices) takes about 45 seconds.

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
| Teal | Slope smoothing (beads in the steps of a sloped top) |
| Lime | Slope ironing (ironing over the steps of a sloped top) |
| Gray dashes | Travel moves |

The light gray area is the outline of the layer. Each line is drawn at the line width, so you can see gaps and overlaps.

Layer numbers start at 0. If the number is too large, zslice shows the number of layers in the part.

## Add your printer

At the first start, zslice opens the printer picker. Later, pick "Add a printer…" at the end of the printer menu in the header bar.

1. Type a part of the name in the search: "ender 3", "mk4", "k1 max", "voron 2.4". The list narrows as you type. Or pick a brand at the left: its models show in groups by series.
2. Click a model. The card at the right draws its build volume to scale (the red dot is X0 Y0 of the G-code), with the print sheet of the printer on the plate if the library has one, and lists its nozzle, its filament, its heating, its firmware, and its motion limits.
3. Click Next (or double-click the model). Check the name, the nozzle, the filament diameter, and the size. Set the connection, and test it.
4. Click "Add printer". The printer is the current printer, with its machine settings.

The library has more than 1000 printers of more than 180 brands. The data comes from the printer definitions of Cura, PrusaSlicer, and OrcaSlicer ("Data from" on the card). zslice uses the values of the definitions with two choices of its own:

- The print speed (`machine.max_speed`, the base of the speed ratios) follows the acceleration of the printer: 100 mm/s below 1000 mm/s², 150, 200, and 300 mm/s from 10000 mm/s². It stays under the speed limit of the firmware.
- Some definitions have a start G-code with scripts (`{if ...}`), which zslice cannot run. Such a printer gets the start G-code of zslice, and the card says so. Check the start G-code (Printer settings, G-code) before the first print.

If your printer is not in the list, pick "My printer is not in the list" at the end: the generic printer, with the size that you enter.

### The bed in the 3D view

For most printers of the library (830 of 1080), the 3D view shows the bed of the printer under the plate: the shape of the bed, and the print of the sheet (the logo and the marks) if the source has one. The bed is a soft gray, so the print stands out. The parts of a bed model above the plate (a frame, a back plate) are see-through. The 10 mm grid stays on the bed. A printer with no bed model in the library, and the generic printer, show the grid alone.

The setting `machine.model` (Printer settings) has the id of the model in the library, for example `prusa-mk4s`. The picker sets it. A printer from before this setting gets its bed if its name is the name of a model in the library. Clear `machine.model` to see the grid alone.

### Printers on your network

The picker also searches the local network (mDNS) and lists the printers that it finds under "On your network": OctoPrint, printdeck, Moonraker (Klipper), and PrusaLink. Click one: zslice fills its address and its kind in the second step. If the printer tells its model (PrusaLink) or its bed (Klipper), zslice selects the model; else pick it in the list. An OctoPrint or printdeck printer needs its API key in the second step.

The web app cannot search the network: browsers do not allow the mDNS packets. Enter the address of the printer in the second step.

## Printers

Open Preferences (the menu, or Ctrl+,). The Printers page lists your printers. Each printer has its own machine settings (the bed, the nozzle, the speeds, the start G-code) and a connection:

- None: export a G-code file.
- printdeck, or OctoPrint: the address of the printer and its API key.
- Moonraker (Klipper): the address of Moonraker.
- USB: the serial port and the speed. The app sends the print itself, line by line, so the computer must stay on while it prints.

"Test the connection" shows what the printer tells: its state, its bed and nozzle (OctoPrint, Moonraker), its motion limits and the filament in it (printdeck). "Use the printer's bed, nozzle, and motion" copies the bed, the nozzle, and the motion limits (acceleration, corner speed, Z speed and acceleration: so the time estimate plans as the printer moves) to the printer settings, and "Use the filament in the printer" copies the filament.

With a printdeck printer, the status bar also shows the printer's own estimate after each slice, for example "LulzBot TAZ Workhorse: 1 h 41 min (3 min start)". printdeck learns it from its past prints: the time of the start macro (homing, heating, probing, priming), and how its real move times compare with the plan. zslice sends the G-code to the printer for this (compressed), and only reads the answer: the printer does not keep the file or print it.

printdeck also tells which roll of filament is in the printer and how many grams are left on it. The status bar shows it ("Operational · Gray, 818 g left"), and the cost of the print uses the price of that roll (else `filament.price_per_kg`). If a print needs more filament than the roll has left, zslice asks before it sends the print.

Each roll keeps its own filament settings ("Keep filament settings for each roll in the printer" in the Preferences, on by default). zslice saves them for the roll in the printer (in `rolls/` in the settings folder), with each change, so the tuning of a roll (its flow, its temperatures) stays with it. When you load another roll, its settings come back. A roll that zslice has not seen starts from the settings before, with its name, diameter, and color; a roll of another material starts from the built-in profile of that material.

Pick the printer in the menu at the left of the header bar. With a connection, the main button ("Print to Printdeck", "Print to OctoPrint", "Print to Moonraker", or "Print" over USB) puts the G-code on the printer and starts the print; its menu has "Upload only" and "Export a G-code file". The status bar shows the state of the printer and the progress of its print.

The API keys are in `~/.config/zslice/app.ini`, which only you can read.

"Manage printers…" in the web app, and the Printers page of Preferences in the GTK app, have the connection, the API key, and **Get a key** for each printer. Get a key asks the printer for a key of its own for zslice: the printer asks "Allow zslice to use the Printdeck?" on its touch screen (printdeck), or in its web page (OctoPrint, with the App Keys plugin). Allow it within 2 minutes, and zslice keeps the key. You can also copy the key: printdeck shows it on its System page (`http://<printer>/system`, "Slicer API key"), and OctoPrint in Settings › API. A printdeck starts a print from zslice only after a press of Print on its screen.

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

Changes on the Selected page are for the loaded part only, never for other prints. "Change for" says where they go: the whole part (all layers), this layer, this layer and up, or this layer and down. A changed setting shows in the accent color, with a button to remove the change. Some settings cannot change for some layers (for example the first layer height and the support angle); they are off in a layer choice. The settings reference marks the settings that can change per layer. A new layer height starts with the selected layer. The printer settings are off on this page; change them in Settings. The Settings page has the defaults for all prints.

Each number has its unit after it. A ratio shows as a percentage: a skin speed of 70 % is 70 % of the speed that the machine and the filament allow.

To change a number:

- Type it. The app uses the value after a short pause, on Enter, or when you leave the field.
- Press Up or Down to step it by one unit of its last decimal place. Hold Shift for 10 steps, or Ctrl for a tenth of a step.
- Drag the name of the setting to the left or the right.
- Drag its slider. The slider covers the usual values. The preview follows as fast as the slicer can go: a change of the infill or the speeds keeps the walls and the skin areas of the last slice, so a new slice of a mid-size part takes less than 0.1 s.

A value out of the usual range shows in the warning color, and its tooltip gives the usual range. A value out of the limits of the setting (for example a 300 mm brim) is an error, and the tooltip gives the limits.

## The panel and the print card

The view has the whole window. The print card floats at the bottom right of the view: the print time, the plastic, the layers, Export or Print, and the main settings of the print (the layer height, the walls, the infill, the support, the brim or the skirt, the temperatures, and the nozzle). Click one of these settings to change it in the search.

The panel has all settings, the selected line, the history, and the project. Press `N`, or click the panel button at the top right, to show it or hide it. It slides over the view. Click **Pin** to put it beside the view, as a column with a splitter; click **Pin** again to let it slide over. Esc hides it when it slides over the view. A link to a setting shows the panel. The app keeps the choice for the next start. A hidden panel shows the whole print: the lines of the selected setting show only while the panel shows.

A click on a line opens a card next to it: the feature and the layer, the planned speed, the real speed, and the flow, why the line is slow, its size (a circle shows its diameter), and the settings that matter for it. The card picks them from the line: the setting that makes it slow (the minimum layer time of a short layer, or the acceleration for short segments), the first layer settings on the first layer, a setting that you changed, and then the main settings of its feature (for infill: the density, the pattern, and the speed). Each pick says why it is there. Change a setting in the card, and the part slices at once. **Fade the others** shows the line solid and the other lines as faint ghosts. **All settings…** opens the Selected page of the panel. Esc, ×, or a click on no line closes the card.

## The part card

With the Move tool (M) or the Turn tool (R), or Ctrl and a click with any tool, a click on a part selects it, and a card opens next to it:

- its name, its size, and its turn;
- **Duplicate** (D): a copy at a free place on the bed, with the settings of the part;
- **Split to parts**: each separate body of the part becomes a part of its own, at its place, with the settings of the part (see "Cut a part" below);
- **Cut…**: cut the part in two with a level plane (see "Cut a part" below);
- **Best orientation** and **Less support**: turn the part;
- **Reset**: the orientation and the scale of the file again;
- **Remove** (Delete);
- the settings that the part has of its own, each with an editor and × (the value of the plate again);
- the keyboard: Tab and Shift+Tab select the next part and the part before; the arrow keys move the selected part 1 mm (with Shift: 10 mm); R with Left or Right turns it 15°; Esc clears the selection. In the web app, the part slices after a pause of 0.6 s in the keys; in the GTK app, each key slices at once;
- **+ Add a setting for this part**: the search for this part. It shows only the settings that a part can have of its own, and a change goes to the part.

### Cut a part

Cut a part that is too tall or too big for the bed, or a part that prints better in two pieces (for example with less support):

1. Select the part, and click **Cut…** on its card.
2. Set the height of the cut with the slider or the number. An orange plane shows the cut in the view.
3. Keep **Turn the top over** on, so the top prints on its flat cut face.
4. Keep **Pegs to line up the parts** on, and choose the count and the diameter (2 pegs of 5 mm at first).
5. Click **Cut**.

The part below and the part above each have a closed cut face. With pegs, both cut faces get matching holes, and the pegs print as small parts of their own next to them. After the print, glue the pegs into the holes of one part, and press the other part on: the pegs line the parts up. The holes are 0.15 mm wider than the pegs. A peg goes only where the cut face is wide enough for it and its wall, and where each part has 1 mm of material past the end of its hole. A message says how many pegs fit. Undo (Ctrl+Z) puts the part back.

Drag the top row of a card (the part card or the line card) to move it. It keeps that place until it closes.

The background of the view follows the dark mode of your system (in the GTK app: the theme of the app, which follows the system unless Preferences sets one).

## Keyboard shortcuts

Press `?` to see all keyboard shortcuts of the app, grouped (in the GTK app, also in the main menu). Type in the sheet to filter it. Esc closes it.

## Search settings and actions

Press `/` (or click **Search** in the preview toolbar of the web app) to search the settings and the actions. Type a few letters, for example `infill`, `brim`, or `export`. A word also finds its other names: `speed` finds the motion settings, `perimeters` the walls, `cooling` the fans, and `temp` the temperatures.

- Each setting in the results has its control: a slider and an entry for a number, a list for a choice, and a switch. Change it right there. The part slices again at once, and the view under the search shows the new lines. A drag of a slider slices as you drag.
- The view does not change while you go through the results. Click the eye of a setting (or press V on it) to show only the lines that it changes, with the other lines as ghosts; click it again, or close the search, for all lines.
- The tag under each setting says its section and where its value comes from (the printer, the profile, or this print).
- An action (Export G-code, Print, Arrange the plate, Undo, and others) runs with a click or Enter.
- The search does not block the view: while it is open, drag in the view to turn it, use the wheel to zoom, and click a line, to see the change from any side. Esc, `/`, or × closes it.
- It opens at the left of the view. Drag its top bar to move it; it opens at the same place next time. A double click on the top bar puts it back.
- Keys: Up and Down go through the results. Left and Right change the value of the result (a step, or the next choice). Space or Enter turns a switch or runs an action. Tab goes into the controls. Esc closes the search.

## Tools

The tool strip at the left of the view picks the tool of the mouse. In the GTK app, the strip also has **Gaps** (G) and **Check**. The key of each tool is in the corner of its button:

| Tool | Key | What a click does |
|---|---|---|
| Select (arrow) | S | Selects a line. The Selected page shows what it is and its measurements. |
| Move (cross) | M | A drag on a part moves it, and the wheel over it turns it by 15°: the same as Ctrl in the other tools. |
| Turn (arrow in a circle) | R | Click a part: three rings go around it. Drag the red ring to turn the part about X, the green ring about Y, and the blue ring about Z (on the bed), in steps of 15° (Shift: 5°). The part turns at once. In the web app, it slices once, when you let go of the ring; in the GTK app, each step slices at once. Keys: Left and Right turn it about Z, Up and Down about X, Page Up and Page Down about Y. |
| Measure (ruler) | T | Two clicks measure between two points of the print or the bed, in the 3D or the 2D view. The distance shows on a label over the middle of the tape, with its parts along x, y, and z. A point near the end of a line snaps to it. A click on a circle or an arc (a hole, a boss) shows its diameter and radius, selects the line, and puts the point at its center, so two holes give the distance between their centers. Hold Shift for no snap. Esc clears the measure. |

The readout floats on the tape: the distance, its parts along X, Y, and Z, and the distance on the bed. A gold line joins the two points, in the 3D and the 2D view.

**Measurements of a line.** The Selected page shows them for the selected segment: its length, the length of the straight edge it is a part of, the length and the size of the whole line, and for a circle its radius and diameter, or for a segment in an arc the radius and the angle of the arc. They follow the segment as h and l move it.

## Move the 3D view

| Mouse | Action |
|---|---|
| Left drag | Orbit: turn and tilt around the part; the bed stays level, and the tilt stops at 89° over the top and under the bed |
| Middle or right drag | Pan: move the view |
| Scroll (mouse wheel) | Zoom toward the pointer |
| Two fingers pressed down on a touchpad, and a drag | Pan |
| A light two-finger swipe, or a pinch | Zoom toward the pointer |
| Double-click on a side of a part | The view turns to face that side, and zooms to it |
| Double-click elsewhere | Reset the view |
| Left click | Pick a line (see below) |

## The context menu

Right-click a line in the 3D view (or press Shift+F10 with a line selected) for the menu:

- **Preview to this layer** (C): the layer slider goes to the layer of the line, so the part shows as printed up to there. Click the side of the part at a height, then press C.
- **Show all layers** (Shift+C), when the slider hides some layers.
- **New profile from here up** (or **from here down**): a layer profile from the layer of the line. See "Layer profiles" below.
- **Add support here** › Grid, Tree, or Bridge (a pad): support of that kind under a 3 mm disk at that place, on that layer. It works also when support is off in the settings.
- **Block support here**: no support from the settings under that place.
- **Remove the support marks here**, and **Clear all support marks**.
- **Copy for AI**: copies a report of the line to the clipboard, to paste into an AI chat and ask why it prints as it does. The report has what the line is, its numbers and why, the values of the settings that change it, the printer and the filament, its points, and its place in the G-code: zslice writes the G-code of the slice to `~/.cache/zslice/last-slice.gcode`, and the report gives the line numbers in that file and the lines.
- **Reset the view**.

A right drag turns the view, and a right click with no drag opens the menu.

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
| C | Preview to the layer of the line | — |
| Shift+C | All layers | All layers |
| Esc | Clears the selection | — |

A click on a line selects the line (yellow) and the segment under the pointer (orange). After the last segment of a line, → goes on to the first segment of the next line. Shift with ↑ or ↓ (or k or j) moves the bottom knob of the layer slider. A line of the same feature (for example an outer wall) wins over a line of another feature that is a little nearer. The layer slider follows the selection.

## Gaps

Turn on **Gaps** (G, in the tool strip of the GTK app) to see the gaps of the top layer of the layer slider in red: the areas that should be solid that no line covers (the sparse infill is left out, as it is sparse on purpose). The toolbar gives the number of gaps of the layer and their area.

Click a gap to select it. The Selected page then gives its size, its width, the lines next to it, and the settings that can close it, the best first, with the value to try and why. **Apply** changes the setting for all prints; **This layer** changes it only for the layer of the gap. The part slices again, and the page shows the same gap with the new settings, or says that it is closed.

`zslice gaps part.stl` lists the gaps of each layer on the command line (`--layer N` for one layer).

**Gap fill** (`project.gap_fill`, on by default) closes most gaps by itself: each narrow area between the walls or in the skin gets one line along its middle, with a width that follows the area. On the 3DBenchy it fills 92 % of the gap area. Turn it off to see the gaps that it fills.

**Retractless skin** (`project.skin_link_length`, 15 mm by default) prints the top and bottom skin of each island as few paths as it can. The skin lines split into pieces at holes and corners, and each piece is one zigzag. From the end of a zigzag, the nozzle goes on to the next zigzag along the walls and prints on the way, if that way is at most 15 mm long. A travel comes only where no such way is. At a hole, both sides fill before the skin over the hole. On the 3DBenchy (with gap fill off) the skin travels go from 955 to 330, for 1 % more filament. Set it to 0 to print each piece on its own.

## Check the print

**Check** (in the tool strip of the GTK app) lists what can make the print fail or print badly, the worst first:

- an overhang with support off, flatter than `project.support_angle`;
- a bridge, with its span (a long bridge can still sag);
- a shape that starts in the air (an island);
- a line that needs more plastic than the hot end melts (`filament.max_flow`);
- layers that print in less than `filament.min_layer_time` (one issue for each run of such layers);
- a layer with many retractions.

Each issue says what it is and which setting changes it. Click an issue: the view goes to its layer, and the line of the issue (or the line nearest to it) is selected. `zslice check part.stl` prints the same list.

## Bridges

A bottom skin over air that solid plastic holds at its sides is a bridge. zslice prints it across the air, in the direction where the longest line is the shortest, of the directions where the lines start and end on plastic. The lines go 1.5 mm into the plastic around the bridge (the anchors), and join there, so the nozzle does not travel over the air. The parts of the walls over air print as bridges too.

Bridges print at `project.bridge_speed` (a ratio of the allowed speed), with `project.bridge_flow` and `project.bridge_fan`. The fan goes back to the fan of the layer after them. In the previews, bridges are sky blue, and the G-code marks them `;TYPE:BRIDGE`. `project.bridges` turns all of this off.

## The print card

The print card at the bottom right of the view shows the print time (with a printdeck printer, its time with the heat-up and the start), the plastic in grams and meters, the cost, and the layers. Under it: the state of the slice, the islands warning, and the printer with the roll in it. Its button prints on the printer ("Print to Printdeck", with "Upload only" and "Export a G-code file…" in its menu), or exports the G-code if there is no printer.

## Undo

Ctrl+Z undoes a change of the settings or of the plate (a move, a turn, a scale, a removed part, the settings of a part), and Ctrl+Shift+Z (or Ctrl+Y) redoes it. A drag of a slider is one step. The main menu has Undo and Redo too. The undo list keeps 100 steps; the plates in it take at most 200 MB, so on a plate of large parts the oldest steps go first.

## History

Each change of the settings or of the plate is a change in the history (the steps of undo and redo). Two views show it:

- **The timeline** under the preview: one badge for each change, the oldest at the left, as the timeline of Fusion. The color and the glyph of a badge show the kind of change: walls (orange squares), infill (green grid), top and bottom (blue lines), speed (purple chevrons), temperature and cooling (red thermometer), support (gray pillars), layers (amber lines), quality (pink star), the printer, and the place of a part (teal: move, turn, scale, add, remove). Point at a badge to see its changes in words ("Infill density 28 % → 45 % · This print"). Click a badge to go back to that change: the preview slices as it was then, at once. The changes after it stay (dimmed) until you edit something. With the focus on the timeline, ← and → go to the change before and after.
- **The History tab** of the panel: each change with its badge, its time, and its changes, the newest first, and the scope of each change: the printer, the filament, this print, a part, or a layer range ("Layers 86 and up"). Click a change to go back to it, or use ↑ and ↓. Space goes back to the change shown before, so two changes are easy to compare. The ↶ button of one setting in a change undoes only that setting and keeps the later changes: it adds a new change. A double click on a setting goes back to that change and opens the setting where it changed (this print, the part, or the layer profile), so you can edit it there.

The changes for some layers (layer profiles and changes for one layer or a range) also show as orange marks on the right of the layer slider. Point at a mark to see its changes, and click it to go to its top layer and open its layer profile in the settings.

The core makes the list: `zs_app_history_facts` writes the state of a step, `zs_history_diff` gives the changes from one step to the next, `zs_app_history_describe` writes them in words, and `zs_app_history_revert` undoes one change.

## Printer, filament, and quality

Each setting gets its value from a cascade of levels. A higher level replaces the value of a lower one:

1. **Default:** the built-in value.
2. **Global:** your settings for all prints.
3. **Printer:** the printer profile (the menu at the left of the header).
4. **Filament:** the filament profile, or the roll in the printer (the Filament menu).
5. **Quality:** the quality profile: fine (0.1 mm layers), standard (0.2 mm), draft (0.3 mm), coarse (0.4 mm), or your own (the Quality menu).
6. **This print:** your changes for this plate.
7. **This part:** the changes of one part (see [Settings for one part](#settings-for-one-part)).

The bar at the top of the Settings page says what a change is for: **This print (all parts)**, **Global (all prints)**, or one part. A global setting is for every print, under the quality profile: for example, the seam at the rear, or your usual skirt. The global settings are in `global.toml` in the settings folder.

In the Settings page, a small tag under the name of a setting says where its value comes from ("fine", "Gray", "This print"); a default has no tag. The detail page says the same, and **Reset** goes back to the value under your change: for a change of this print, the value of the quality profile.

The Filament and Quality menus list the built-in profiles and your own (in `profiles/filament/` and `profiles/project/` in the settings folder, where `zslice slice -f` and `-p` find them too), and have **Save as profile…**. The Quality menu shows the quality profile, with a dot when this print has changes on top of it. A pick of another quality keeps your changes. **Save as profile…** saves the quality with your changes, and the new profile is then the quality.

### Formulas

A setting can follow other settings. In the detail page of a setting (the › of its row), type a formula in **Formula** and press Enter, for example:

- `= {line_width} * 2`: twice the line width (for an automatic width, the width that the slicer uses).
- `= max({layer_height} * 4, 0.8)`: four layers, and at least 0.8 mm.
- `= {infill_pattern} == "gyroid" ? 3 : 2`: three walls with gyroid infill, else two.

`{name}` is a setting: its short name (`{layer_height}`) or its full name (`{filament.nozzle_temp}`). A formula has `+ - * / %`, `^` (a power), comparisons, `and`, `or`, `not`, `cond ? a : b`, and the functions `min`, `max`, `round` (`round(x)`, or `round(x, step)`), `floor`, `ceil`, `abs`, `sqrt`, `clamp(x, lo, hi)`, and `lerp(a, b, t)`. The value follows each change of the settings that it uses, and its tag shows the formula. A plain value in the field of the setting removes the formula; so does an empty Formula field. A formula that does not work turns the field red, and the value stays. The formulas are in `formulas.txt` in the settings folder.

### Path rules

`project.path_rules` (Settings, Speed ratios) changes the speed, the flow, or the fan of the paths that match a formula. Write one rule on each line:

```
speed = {feature} == "outer_wall" and {z} < 5 ? 20 : {speed}
flow = {feature} == "bridge" ? 0.9 : 1
fan = {layer} < 3 ? 0 : {fan}
```

The variables of a path: `{feature}` (`"outer_wall"`, `"inner_wall"`, `"skin"`, `"infill"`, `"bridge"`, ...), `{layer}` (from 0), `{z}` (mm), `{part}`, `{speed}` (the planned speed, mm/s), `{width}` and `{height}` (mm), `{length}` (mm), and `{fan}` (0 to 1). `speed` sets the speed in mm/s, `flow` multiplies the flow, and `fan` sets the fan while the path prints. The rules go in order, so a rule sees the speed and the fan of the rules before it. A line that does not work is left out; a line that starts with `#` is a note.

## Settings for one part

With more than one part on the plate, the Settings page has a bar at the top: **Settings for: This print (all parts)**, or one part. With a part, a change is for that part only, on top of the values of the print, and its tag says "This part". **Reset** gives the part the value of the print again. The part page (Ctrl+click on a part) has **Edit settings for this part**, which opens the same view.

A part can have its own value of almost any part or filament setting: the walls, the layer height, the seam, the speeds, the infill, the skin, the support. Each part slices as its own job, and the G-code joins the layers of all parts by height (a part with thicker layers prints at every second height, for example). The settings that are for the whole plate (the temperatures, the fan and the cooling, the travel and the retraction, the first layer height, the skirt and the brim) say "Same for all parts", and cannot change there. The part page also has **Quality**: a quality profile for this part only, for example a jig in draft next to a figure in fine. A 3MF file keeps the settings of each part.

The panel at the right has two pages, Selected and Settings, and one history for both: **Back** (the arrow at the left of the tabs, the arrow of the Settings path, the back button of the mouse, or Alt+Left) goes to where you were before, also across the two pages. For example: a link from the Selected page opens a setting, and Back returns to the line.

In the Settings page, each row of a section has the setting's field (a number with its unit, a switch, or a choice), so a quick change needs no other page. The › at the end of a row opens its detail page: what it does, its default, and the lines of the project that it changes, with their time.

## Layer profiles

A layer profile changes settings for some layers only, for example a denser infill from layer 48 up.

1. Right-click a line in the 3D view at the height where the change starts, and pick **New profile from here up** (or **from here down**).
2. The Settings page opens with a bar at the top: the name of the profile and its layers. Each setting shows its value for these layers. A change goes only to these layers, and it shows in the accent color.
3. Click **Done** to stop. Then a change in the Settings page goes to all prints again.

The **Layer profiles** section at the top of the Settings page lists each profile: its layers and how many changes it has. Click a profile to see its changes and edit it. In the bar, the pen renames the profile, and the trash deletes it with all its changes. A change for "This layer and up" on the Selected page shows in the list too. A 3MF file keeps the profiles. A setting for the whole print (for example the bed temperature) cannot change for some layers; the page says so.

## More than one part

Open adds each model to the plate (Ctrl+O, or drop files on the window). The first part keeps the place of its file if it is on the bed there; a new part goes to a free place. "Arrange the plate" in the menu packs all parts in rows.

- A click on a line selects the line (its settings are on the Selected page).
- Shift+click adds a line to the selection (or takes it out). With more than one line, a change for "This layer" goes to the layers of all of them, and "This layer and up" (or down) starts at the lowest (or ends at the highest) of them.
- Ctrl+click on a part selects the part: a blue frame shows it on the bed, and the Selected page has its place, its turn, its scale, the placement, and "Remove".
- Ctrl+drag moves the selected part, and Ctrl+wheel turns it by 15°. `[` and `]` turn it by 15° too (with Shift, by 1°), and Delete removes it, after a question.

"Clear the plate" in the menu removes all parts.

### Placement

"Smart placement" in the menu turns each part for the least support, the most area on the bed, and a low height, and then arranges the plate. The part page (and the Placement submenu of the context menu) has the other ways:

- **Smart placement** for one part.
- **Less support**: the orientation with the least support only.
- **Strong along** X, Y, or Z of the part: say which way the load goes. A print is weakest across its layers, so the part turns until that axis lies in the layers, and then takes the least support.
- **Turn 90° about X** or **about Y**, and **Scale** (in %).
- **Put this side on the bed** (context menu of a line): the side of the part at that line goes down.
- **Reset**: the orientation and the size of the file.

## More than one plate

Each plate has its own parts, settings, changes, support marks, and undo history. The plate bar has ‹ and › (the plate before and the next plate), "Plate n of N", **+ Plate** (a new empty plate after the others, with the settings of the active plate), and **×** (remove the active plate). All plates slice: the active plate first, then the others in the background. "Send all plates" in the menu slices each plate with parts and sends it to the current printer, one file for each plate; "Export all plates…" writes the files into a folder (name-plate-1.gcode, and so on).

To remove a plate, click **×** on the plate bar, right-click the label of a plate (in the GTK app: the name on the plate bar) and choose "Remove plate n", or choose "Remove this plate" in the menu or in the search. A plate with parts asks first. A removal cannot be undone. The plate on the left of the removed plate becomes active. The last plate stays, with no parts. You can remove a plate of a project: its print status stays in the Project tab.

In the web app, all plates are in one view, in a row, and the plate bar at the bottom left also has **All** (Home). The GTK app shows the active plate only. The keys of the plates:

- `]` makes the next plate active, and shows it.
- `[` makes the plate before active, and shows it.
- `F` shows the active plate.
- `Home` shows all plates (in the GTK app: the start view).

 Each plate slices: the active plate first, then the others. With your own plates, **Open** puts the file on the active plate, and **+** in the toolbar adds models to it; the other plates stay. A printdeck.yml project makes way for an opened file.

## Save the plate

"Save the plate as 3MF" in the menu (Ctrl+S) writes one 3MF file with all parts at their places, and the changes that you made for the parts and for some layers. The global settings (Settings) do not go in the file. Open the 3MF file to get the plate back. zslice also opens 3MF files from other slicers; parts that touch in the file (for example a sign and its text) stay one part, but a part with its own settings or a volume stays apart (see "Cura projects" below).

## Cura projects: part settings and modifier volumes

zslice opens a Cura project (a 3MF file that Cura saved). It reads the settings of each object of the project:

- **Settings of a part.** Cura keeps the settings that you set for one object in the file ("Per Model Settings"). zslice changes each to its own setting, for example `infill_sparse_density` to `project.infill_density`. If all parts that print have the same settings, the settings apply to the whole plate. If the parts have different settings, each part slices with its own settings: its walls, its layer height, its seam, its infill, its support, and the rest. Only the settings that are the same for all parts of the plate stay the plate settings: the temperatures, the fan and the cooling, the retraction and the travel, the first layer height, the skirt, and the brim. A part setting of that kind gets a note. Your overrides go over the plate settings.
- **Modifier volumes.** An object that is a Cura "infill mesh" ("Modify settings for infill of other models") does not print. It belongs to the part that it overlaps, and moves with it. Inside it, the part gets the infill of the volume: its pattern, density, angles, speed, and flow. A volume with no walls and no top and bottom layers (0 in Cura) removes the skin of the part inside it too, so only its infill prints there. This is how a speaker grille works: a plate, and a window volume with an open infill. The walls of the part along its outline stay. Where two volumes overlap, the one with the higher `infill_mesh_order` wins. A volume has the settings of your profile and its own, as in Cura, and not the settings of the part.
- **Other volume types.** Cura cutting meshes, anti overhang meshes, and support meshes do not print. zslice does not support them yet.

The part page lists the settings of the part and of its volumes, each with the zslice setting that it becomes, or why zslice does not use it (for example a Cura formula, or a setting that zslice does not have). The 3D view draws each volume as thin purple rings. "Save the plate as 3MF" keeps the settings and the volumes. The command line tool slices a Cura project too, and prints a note for each setting that it does not use:

```sh
zslice slice grille.3mf -o grille.gcode
```

Some infill settings are made for parts like a grille:

- `project.infill_angles`: a list of angles, one for each layer in turn ("Infill Line Directions" in Cura). "45,45,45,135,135,135" prints 3 layers at 45 degrees, then 3 at 135 degrees. zslice measures the angle from the X axis, and Cura from the Y axis: zslice changes the angles of a Cura file for you.
- `project.infill_stack`: the lines and zigzag patterns keep one direction on all layers, so the lines of each layer lie on the lines below and make vertical walls. Honeycomb then prints each cell wall once. Grid, triangles, trihexagon, and honeycomb stack on all layers in each case, also on the first layer.
- `project.infill_flow`: the flow of the sparse infill ("Infill Flow" in Cura).
- The `trihexagon` pattern: three line directions that make triangles and hexagons (as in Cura).

## Compare with Cura

If you also print with Cura, "Compare with Cura…" in the menu shows your zslice settings next to the settings of the printer that is active in Cura. zslice reads the Cura files on this computer, and it does not change them:

- The newest Cura version folder in `~/.config/cura` and `~/.local/share/cura`, for example `5.14`.
- The printer that `cura.cfg` names as `active_machine`, its extruder, and all layers of their stacks: your changes, the quality changes, the intent, the quality, the material, the variant, the machine changes, and the definition.
- The files of Cura itself, in `/opt/ultimaker-cura/share/cura/resources` or `/usr/share/cura/resources`. Set `ZSLICE_CURA_RESOURCES` for another folder.

Each row has the zslice setting, its group (Printer, Filament, or This print), the value in zslice, the value of Cura, and the Cura key that gives it. The mapping is the same as in `zslice import cura` (see [profiles](profiles.md)). By default the list has only the settings that differ. Turn on "Show all mapped settings" to see all of them.

- **Use** sets the Cura value in zslice: in the printer, in the filament, or for this print. Undo takes it back.
- **Use all** sets each value that differs. It does not change the names of the printer and the filament, or the start and end G-code: a printer with Klipper often has its own macros there.
- A speed shows as a ratio and in mm/s. zslice keeps a speed as a ratio of `machine.max_speed`, and the Cura value is the ratio that gives the mm/s of Cura with your max speed now. The max speed of Cura is the highest print speed of the Cura profile. "Use all" sets the max speed first, so the speeds stay the same as in Cura.
- A Cura value that is a formula (it starts with "=") shows with "Show all mapped settings", but zslice cannot take it.
- "Reload" reads the Cura files again, for example after you change a setting in Cura.

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

## Smooth the sloped tops

A sloped top surface prints as a stair of thin layers. Slope smoothing fills the steps. After each layer, the nozzle goes back along the edge of the layer, over the narrow ledge of the layer below, and lays a small bead in the corner of each step. The bead has the volume of the empty triangle there. The nozzle height can change along the bead, between the two layers, so the G-code of these beads has a Z on each move. In the previews, these beads are teal.

```sh
zslice slice part.stl -o part.gcode -s project.slope_smoothing=true
```

- Only ledges from `slope_smoothing_min_width` to `slope_smoothing_max_width` line widths get a bead (0.3 to 2 by default). With 0.2 mm layers and 0.5 mm lines, that is a slope from about 11 to 53 degrees. A wider ledge is a flat top: the skin covers it.
- The nozzle must not touch the layer that it just printed. `machine.nozzle_tip_radius` (the flat face around the hole) and `machine.nozzle_cone_angle` describe your nozzle. Where the nozzle has no room to go down into the corner, it stays at the top of the layer, and the plastic fills the corner under the flat tip. A nozzle with a small tip goes lower.
- `project.slope_smoothing_flow` scales the plastic, and `project.slope_smoothing_speed` sets the speed.
- It adds time: about 7 % on a Benchy (a travel, a retraction, and two Z moves for each bead).

## Iron the sloped steps

Slope ironing goes over the same steps after the smoothing beads, with a very small flow (10 % of a normal line). At each point, the nozzle tip is at the height of the filled step, so the hot tip makes the bead tops flat. It makes `project.slope_ironing_passes` passes across each ledge (2 by default). In the previews, these lines are lime.

```sh
zslice slice part.stl -o part.gcode -s project.slope_smoothing=true -s project.slope_ironing=true
```

It uses the same ledges and the same nozzle settings as slope smoothing. `project.slope_ironing_flow` and `project.slope_ironing_speed` control it. It adds about 10 % to the time of a Benchy, and both together about 15 %.

## Where the part goes on the bed

zslice moves the part so that its bottom is at z = 0. The X and Y come from `project.placement`:

- `auto` (the default): the X and Y of the file, if the part is fully on the bed there. If it is not (for example, a part modeled around the origin), zslice moves the center of the part to the center of the bed (`machine.bed_size_x` / 2, `machine.bed_size_y` / 2).
- `file`: always the X and Y of the file.
- `center`: always the center of the bed.

The X and Y of a file are bed coordinates: 0, 0 is the front left corner of the bed. If the G-code origin of your printer is somewhere else (for example the bed center), set `machine.origin_x` and `machine.origin_y` to the G-code position of the front left corner. For a printer with the origin at the bed center, they are minus half the bed size. The Cura import sets them from `machine_center_is_zero`.
