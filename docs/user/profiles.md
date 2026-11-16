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

`zslice profiles` lists the built-in profiles.

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

A value with a `/` or a `.toml` ending is a path: `-f ./acme-pla.toml`. A relative path in `extends` is relative to the file that names it.

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
