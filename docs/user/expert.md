# Formulas and rules

Settings for one part, settings for some layers, formulas, and path rules.

## Settings for one part

1. Select the part.
2. Click **+ Add a setting for this part** on its card. The search shows only the settings that a part can have.
3. Change a setting. The change is for this part only.

A part can have its own walls, layer height, seam, speeds, infill, skin, and support. Some settings are for the whole plate: the temperatures, the fan, the travel, the retraction, the first layer height, the skirt, and the brim. In the web app, the search of a part shows only the settings that a part can have. In the Linux app, these plate settings say "Same for all parts", and a part can also have its own **Quality**.

## Settings for some layers

A change in the long form of a line can be for the whole part, for this layer, for this layer and up, or for this layer and down. For example: slower outer walls for the 10 layers of a thin tower. A changed layer shows a reset button. The [settings reference](settings.md) marks the settings that can change for each layer.

A layer profile changes settings for a range of layers (in the Linux and Mac apps):

1. Right-click a line at the height where the change starts.
2. Pick **New profile from here up** (or **from here down**).
3. Change settings. A change goes only to these layers.
4. Click **Done**.

## Formulas

A setting can follow other settings. On the page of a setting, type a formula in **Formula**, and press Enter.

| Formula | Value |
|---|---|
| `= {line_width} * 2` | Twice the line width |
| `= max({layer_height} * 4, 0.8)` | Four layers, and at least 0.8 mm |
| `= {infill_pattern} == "gyroid" ? 3 : 2` | Three with gyroid infill, else two |

- `{name}` is a setting: its short name (`{layer_height}`) or its full name (`{filament.nozzle_temp}`).
- Operators: `+ - * / %`, `^`, comparisons, `and`, `or`, `not`, and `cond ? a : b`.
- Functions: `min`, `max`, `round(x)` or `round(x, step)`, `floor`, `ceil`, `abs`, `sqrt`, `clamp(x, lo, hi)`, and `lerp(a, b, t)`.
- A plain value removes the formula. A formula with an error turns the field red, and the value stays.

## Path rules

`project.path_rules` changes the speed, the flow, or the fan of the paths that match a formula. Write one rule on each line:

```
speed = {feature} == "outer_wall" and {z} < 5 ? 20 : {speed}
flow = {feature} == "bridge" ? 0.9 : 1
fan = {layer} < 3 ? 0 : {fan}
```

- The variables: `{feature}` (`"outer_wall"`, `"inner_wall"`, `"skin"`, `"infill"`, `"bridge"`, ...), `{layer}` (from 0), `{z}`, `{part}`, `{speed}`, `{width}`, `{height}`, `{length}`, and `{fan}` (0 to 1).
- `speed` sets the speed in mm/s. `flow` multiplies the flow. `fan` sets the fan.
- The rules go in order. A line with an error has no effect. A line that starts with `#` is a note.

## Some settings in detail

| Setting | What it does |
|---|---|
| **Wall order** (`project.wall_order`) | `inner_first` (the default) prints the inner walls, then the outer wall. `outer_first` prints the outer wall first: holes and joints fit better, but an overhang can curl. |
| **Alternate extra wall** (`project.alternate_extra_wall`) | One more wall on each odd layer. The walls interlock with the infill, so the part is stronger across its layers. |
| **Overhang walls** (`project.overhang_wall_speed`, `project.overhang_wall_fan`) | The parts of a wall that hang over air print slower, with more fan. `project.overhang_wall_threshold` sets how far a wall must hang over air: 0.5 is half the line width. Off by default (a speed of 100 % and a fan of 0). |
| **Fuzzy skin** (`project.fuzzy_skin`) | A rough surface: random points along the outer wall, up to half of `project.fuzzy_skin_thickness` to each side, about `project.fuzzy_skin_point_distance` apart. `outside` leaves the holes smooth, so they keep their size. |
| **Spiral vase** (`project.spiral_vase`) | After the bottom layers, only the outer wall prints, and the nozzle rises along it with no seam: a vase with no top and no infill. For a part with one outline on each layer. |
| **Gap fill** (`project.gap_fill`) | One line along the middle of each narrow area. On by default. |
| **Retractless skin** (`project.skin_link_length`) | Prints the skin of each island in few paths: the nozzle goes along the walls to the next zigzag, up to 15 mm. 0 turns it off. |
| **Bridges** (`project.bridges`) | Prints a skin over air across the air, in the direction of the shortest longest line, anchored 1.5 mm into the plastic around it. Slow, with the fan on. |
| **Ironing** (`project.ironing`) | Goes over each top surface again with close lines and a small flow. |
| **Slope smoothing** (`project.slope_smoothing`, experimental) | Lays a small bead in each step of a sloped top. Each point of the bead has its own Z. |
| **Slope ironing** (`project.slope_ironing`) | Irons the filled steps. |
| **Wipe inside the part** (`project.retract_wipe`) | Moves on a small arc inside the part at each retraction. For stringy filament. |
| **Infill anchor** (`project.infill_anchor`) | The infill grid starts at the center of each part. `bed`: one grid for all parts. |
| **Thumbnails** (`machine.thumbnails`) | The sizes of the pictures for the printer screen, for example `300x300,32x32`. |
| **Placement** (`project.placement`) | `auto` keeps the X and Y of the file if the part is on the bed there. `file` and `center` always do one of the two. |

## Compare with Cura

In the Linux app, **Compare with Cura…** (in the search) shows your zslice settings next to the settings of the printer of Cura. **Use** sets one Cura value in zslice, and **Use all** sets each value that differs. See [Profiles](profiles.md) for `zslice import cura`.

## Where the settings stay

The app loads your changes at the next start. The Linux app keeps them in `~/.config/zslice/`: `filament.toml`, `project.toml`, `global.toml`, and a file for each printer in `printers/` (`<id>.toml`, and `<id>.filament.toml` for its filament). Each file has only the settings that differ from the defaults. The web app keeps them in your browser.
