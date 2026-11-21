# Profiles

A profile is a text file with settings. zslice has three kinds of profile, one for each owner of the settings:

| Kind | What it describes | Example |
|---|---|---|
| machine | Your printer | `my-printer.toml` |
| filament | A filament | `acme-pla.toml` |
| project | What you want for a part | `fine.toml` |

## Use profiles

```sh
zslice slice part.stl -m my-printer -f acme-pla-gray -p fine -o part.gcode
```

zslice applies the settings in this order. Each step replaces the values of the steps before it:

1. The defaults.
2. The machine profile (`-m`).
3. The filament profile (`-f`).
4. The project profile (`-p`).
5. Each `-s group.name=value` on the command line.

`zslice profiles` lists the built-in profiles. To convert Cura profiles, see [Import from Cura](#import-from-cura).

## Write a profile

A profile is TOML: one `key = value` on each line, and `#` for comments. The keys are the setting names of the group, without the group name. The [settings reference](settings.md) lists them.

```toml
# filament/acme-pla.toml
extends = "generic-pla"
name = "Acme PLA"
nozzle_temp = 205
bed_temp = 55
```

Values:

| Setting kind | Example |
|---|---|
| Number | `nozzle_temp = 205` |
| True or false | `ironing = true` |
| Choice | `infill_pattern = "grid"` |
| Text | `name = "Acme PLA"` |
| Text with more lines | `start_gcode = """` then the lines, then `"""` |

To start a new profile from the current values, with a comment on each setting:

```sh
zslice profile filament -f generic-pla -o acme-pla.toml
```

Then delete the lines that you do not change, so that the base profile gives them.

## Inheritance: extends

`extends = "name"` loads another profile of the same kind first. The keys of this file then replace its values. Use it for a family of profiles:

```toml
# filament/acme-pla-gray.toml
# Acme gray PLA needs 15 degrees more than the other Acme colors.
extends = "acme-pla"
name = "Acme PLA Gray"
nozzle_temp = 220
```

A chain of `extends` can be 8 profiles long, and it cannot loop back to a profile in the chain.

## Override another group

A table changes settings of another group. Use it in a project that needs one change to the filament or the machine:

```toml
# project/smooth-top.toml
extends = "fine"

[filament]
nozzle_temp = 225
```

The tables are `[machine]`, `[filament]`, `[project]`, and `[engine]`.

## Where zslice finds profiles

For a name (not a path), zslice looks in this order:

1. Next to the profile file that names it (for `extends`).
2. `./profiles/<kind>/<name>.toml`
3. `~/.config/zslice/profiles/<kind>/<name>.toml` (or `$XDG_CONFIG_HOME/zslice/...`)
4. The built-in profiles.
5. For a machine: the printer library. `zslice printers` lists the id of each printer, for example `-m creality-ender-3`.

A value with a `/` or a `.toml` ending is a path: `-f ./acme-pla.toml`. A relative path in `extends` is relative to the file that names it.

## Start and end G-code

`machine.start_gcode` and `machine.end_gcode` are texts with variables. zslice puts the value of each variable in its place:

```toml
start_gcode = """
M140 S{bed_temp}
G28
M190 S{bed_temp}
M109 S{first_layer_nozzle_temp}
"""
```

The variables of zslice are in the [settings reference](settings.md) (`machine.start_gcode`). The variables and the scripts of Cura, PrusaSlicer, OrcaSlicer, and Bambu Studio also work, so a start G-code from these slicers needs no change:

| Slicer | Examples |
|---|---|
| Cura | `{material_print_temperature_layer_0}`, `{material_bed_temperature, 0}`, `{machine_width / 2}`, `{if material_bed_temperature > 60}` ... `{else}` ... `{endif}` |
| PrusaSlicer | `[first_layer_temperature]`, `{first_layer_temperature[0]}`, `{print_bed_max[0]*0.8}`, `{if is_nil(idle_temperature[0])}`, `{local x = 2}` |
| OrcaSlicer and Bambu Studio | `[nozzle_temperature_initial_layer]`, `[bed_temperature_initial_layer_single]`, `{adaptive_bed_mesh_min[0]}`, `{if filament_type[0] =~ /PET.*/}` |

zslice prints with one extruder: a list variable such as `first_layer_temperature[1]` has the value of that extruder. Some variables have no zslice value, for example a time of day, a pressure advance value, or the plate type of a Bambu Lab printer. A line with such a variable becomes a comment, so the printer does not get a wrong value:

```
; zslice: no value for pressure_advance: SET_PRESSURE_ADVANCE ADVANCE=[pressure_advance]
```

A condition with such a variable is false, and a comment tells it. On RepRapFirmware, the expressions of the firmware (`{move.axes[0].min}`) stay in the G-code.

If the start G-code does not heat the nozzle or the bed, zslice heats them before it. A start G-code can set another temperature, for example 170 °C to probe the bed. The first layer then sets the temperature of the filament and waits for it.

## Import from Cura

`zslice import cura` converts a Cura profile stack to zslice profiles:

```sh
zslice import cura printdeck/profiles/taz-workhorse-se -o profiles
```

The stack folder has the layout of the printdeck profiles: a `cura.json` that names the machine definition, the machine changes, the quality profiles, and the materials (see `printdeck/profiles/README.md`). A quality profile can also name a `material`, an `intent`, and the `user` changes, and the machine a `variant`. Each layer of a quality profile can have an `_extruder` layer too, for example `quality_changes_extruder`. The output folder gets:

- `machine/<definition>.toml`: the printer, from the definition chain and the machine changes.
- `filament/<material>.toml`: one for each material.
- `project/<profile>.toml`: one for each quality profile.

What the import does:

| Cura | zslice |
|---|---|
| A percentage (infill, fan) | A ratio |
| A speed in mm/s | A ratio of `machine.max_speed`. The import sets `max_speed` to the highest print speed of the quality profiles, so the speeds stay the same. A comment keeps the mm/s value. |
| A per-profile travel speed, retraction, or cooling value | A `[machine]` or `[filament]` table in the project profile |
| G-code variables, for example `{material_bed_temperature_layer_0}` | The same text: zslice reads the Cura variables (see [Start and end G-code](#start-and-end-g-code)) |
| A value that is an expression (it starts with `=`) | Not imported |
| The settings of a material for other printers (`<machine>` blocks) | Not imported |
| `speed_wall`, `speed_print` | The value of the wall speeds and the other speeds that the profile does not set, as the Cura formulas give them |
| `cool_fan_full_layer` (with `cool_fan_speed_0` at 0) | `filament.fan_off_layers` 1 and `filament.fan_ramp_layers` n - 2: the same fan speed on each layer as Cura |
| `top_bottom_pattern` and `skin_monotonic` | `project.skin_pattern` (`lines`, `monotonic`, or `concentric`) |
| `z_seam_type` and `z_seam_corner` | `project.seam` and `project.seam_corner` |
| `material_shrinkage_percentage_xy` and `_z` (100.3) | `filament.shrinkage_xy` and `shrinkage_z` (1.003) |

Each Cura setting that has no zslice setting yet is in a comment at the end of the profile. Read these comments: they show what the import did not keep. [Cura and OrcaSlicer settings](setting-coverage.md) lists each Cura setting and each OrcaSlicer setting, and the zslice setting that does the same.

## Errors

zslice names the profile and the line:

```
filament profile "acme-pla.toml", line 4: unknown setting (UnknownSetting)
```

| Message | Cause |
|---|---|
| unknown setting | The key is not a setting of the group. Check the spelling in the [settings reference](settings.md). |
| the value has the wrong type | A number has quotes, or a choice is not one of the choices. |
| no profile with this name | The `extends` name, or the `-m`, `-f`, or `-p` name, is not in a search location. |
| the extends chain loops back | Two profiles extend each other. |
| a text value needs quotes | Put text in quotes: `name = "Acme"`. |
