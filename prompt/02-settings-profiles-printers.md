# 02. Settings, profiles, and the printer library

## Goal

Build the settings model, the TOML profiles with inheritance, the formulas, the settings for some layers, the Cura importer, and the printer library of more than 1000 printers. At the end, the command line slices with `-m`, `-f`, `-p`, and `-s`, and a printer of the library gives a machine profile.

## Read first

- [The settings reference](../docs/user/settings.md): each setting, its unit, its default, and whether it can change per layer. Treat it as the spec. Match the names, the choices, and the defaults.
- [Profiles](../docs/user/profiles.md), [Formulas and rules](../docs/user/expert.md), [Change a setting](../docs/user/change-settings.md).
- [Settings for some layers](../docs/internals/layer-settings.md).
- [Cura and OrcaSlicer settings](../docs/user/setting-coverage.md): the map of each outside setting to a zslice setting.
- [Printer data](../docs/references/printer-data.md), [Cura](../docs/references/cura.md), [PrusaSlicer](../docs/references/prusaslicer.md), [OrcaSlicer](../docs/references/orcaslicer.md).

## Build

1. `src/settings.zig`: four groups. `machine` (facts of the printer), `filament` (facts of the material), `project` (what the user wants), and `engine` (options that do not change the print). `Settings.set("group.name", "text")` uses comptime reflection, so each new field reaches the C API, wasm, and the command line with no more code.
2. Each field has a `///` doc comment. `tools/settings_doc.py` writes `docs/user/settings.md` and `src/settings_meta.zig` (the section and help of each setting). A test checks that each setting has an entry.
3. `src/toml.zig` and `src/profile.zig`: a TOML subset. `extends = "name"` loads a base of the same group first (a chain of 8 at most, no loops). A `[filament]` table in a project overrides one value of another group. The load order is machine, filament, project, then the overrides of the user. The core gets base profiles from a `Resolver` of the caller. The built-in profiles in `src/profiles/` are the last place to look.
4. `src/expr.zig`: formulas such as `= {line_width} * 2`.
5. Overrides by z range: a setting marked "per layer" can change for some layers of a part.
6. `src/import_cura.zig`: a Cura stack (the machine definition with its `inherits` chain, the machine changes, the quality, the quality changes, and the `.fdm_material`). The printdeck layout with `cura.json` is the first test case. `src/cura_compare.zig` shows each Cura setting next to its zslice setting.
7. `tools/printer_library.py` writes `src/printers/library.txt` from the definitions of Cura, Cura LulzBot Edition, PrusaSlicer, and OrcaSlicer. The format is in the header of `src/printers.zig`. Native builds embed the file. The wasm module does not: the web app loads it when the picker opens.
8. `tools/printer_beds.py` converts the bed models (`src/printers/beds/`, read by `src/bed.zig`).
9. `src/app/setting_info.zig`, `setting_text.zig`, `setting_search.zig`: the description, the text, and the search of each setting, made at compile time. A shell builds its panel from these and lists no setting itself.

## Numbers and rules that matter

- A project sets a speed ratio (0 to 1) for each feature, in place of mm/s. The engine gets the speed from the limits of the machine and the filament. One project then gives correct speeds on a slow and a fast printer, and with PLA and TPU.
- Units: mm, mm/s, mm³/s, °C. A ratio is 0 to 1. The UI shows a ratio as a percent: 0.5 shows as 50.
- A line width of 0 is "auto": the width comes from the nozzle.
- A number shows with no more digits than it needs (`%.6g`). Back to the core, a percent is divided by 100.
- The search scores: start of the label 40, start of a word of the label 30, inside the label 20, the name 14, the section 12, the help text 3. Project settings +2, engine settings -2, common settings +4. Words of other slicers ("perimeters", "feedrate") find the zslice setting.
- Each number setting has a usual range (a slider, a warning outside it) and hard limits (an error).
- Slider steps follow what people use: 0.01 mm for a layer height, 5 degrees for a temperature, with a tick at the default.
- The printer owns its accelerations: `outer_wall_accel`, `inner_wall_accel`, `skin_accel`, `infill_accel`, `travel_accel`, `first_layer_accel`. 0 means the `max_accel` of the printer. Print settings stay when the printer changes. Each printer keeps the filament that was last used with it.
- `machine.max_speed` in a library profile is a print speed. It is different from the firmware limit (see `printers.zig`).
- The app keeps only the changes from the defaults, in `~/.config/zslice/{machine,filament,project}.toml`.

## Lessons

- The accelerations were print settings first. They moved to the printer, with a migration of saved values, old projects, and sessions to the printer of the plate.
- Keep the filament diameter when the material changes.
- Keep the quality profile and the global settings of a Cura stack as levels of one cascade.
- Keep the vendor G-code of each printer in the library, and the popular printers in the core.
- A multiline value (G-code) shows its first line and " …" in a row. This is the only short form of a value. A label never ends in "…".

## Acceptance checks

1. `zslice slice part.stl -m <printer> -f <filament> -p <project> -s project.wall_count=3` uses each layer in the right order.
2. A filament that `extends` another changes one value, and the rest come from the base.
3. `zslice printers` lists more than 1000 printers of more than 180 brands. `-m <id>` loads one.
4. `zslice import cura <folder>` converts the printdeck TAZ stack, and the slice matches the Cura settings in `cura_compare`.
5. `docs/user/settings.md` is the output of `tools/settings_doc.py` with no diff.
6. A new field in `settings.zig` shows in the panel of each app with no shell code.
