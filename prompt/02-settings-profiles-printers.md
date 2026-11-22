# 02. Settings, profiles, and the printer library

## Goal

Build the settings model, the TOML profiles with inheritance, the formulas, the settings for some layers, the Cura importer, the import of the profiles of other slicers, and the printer library of more than 1000 printers. At the end, the command line slices with `-m`, `-f`, `-p`, and `-s`, and a printer of the library gives a machine profile.

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
10. `src/import_profile.zig`: the profile of another slicer. It reads a PrusaSlicer or OrcaSlicer `.ini` (also a config bundle, and the config block at the end of a G-code file), an OrcaSlicer or Bambu Studio `.json` preset, the settings of a 3MF project of these slicers, and a Cura `.curaprofile`. The report lists each value that zslice set, each clamp, and each key with no zslice setting. `zs_app_profile_import` applies the values as one undo step, and `zs_app_profile_import_report` gives the report. `zslice import <file> [-o dir]` writes the report and the profiles. The conversions are in its header:
    - A list value (one for each extruder) gives its first value.
    - A percentage resolves against its own base in the file first.
    - A speed in mm/s becomes a ratio of `machine.max_speed`, after the printer limits of the file.
    - Each value goes into the limits of its setting.
11. The qualities. The core lists the built-in qualities from the finest to the coarsest: Fine, Standard, Strong, Draft, Coarse. Each name starts with a capital. `zs_quality_summary` gives one line of the main points of a quality: the layer height first, then what differs from Standard ("0.1 mm layers · 3 walls · slower walls · ironed tops"). The menus show that line in small text under the name.
12. Up to 16 nozzles. `machine.nozzles` is 1 to 16, and `filament.nozzle` is 0 to 15. Each nozzle after the first has the settings `machine.nozzle.k.*`: the diameter, the line width, the speeds, the acceleration, the retraction, the tool offset, the reach, the standby, and the preheat. A value of 0 is the value of the first nozzle, so a print with the defaults gives the same G-code. A profile writes them as dotted keys (`nozzle.1.diameter = 0.6`), and the TOML parser reads a dotted key as one key. The old `machine.nozzle2_*` names load into nozzle 1 (`settings.moved_settings`). `zs_setting_info` gives the nozzle of each setting. A shell shows the section of nozzle k only for a printer with more than k nozzles, and leaves its settings out of a search. The nozzle choice of a filament lists Main and 2nd for two nozzles, and T0 to Tn for more.
13. Tool changers: `machine.tool_numbers` is `filament` (default: Tn is the filament, for an AMS, an MMU, the X2D, and the H2D) or `nozzle` (Tn is the nozzle of the filament, for a printer with a hot end for each filament). `machine.standby_delta` sets the temperature of a waiting nozzle (a filament with `standby_temp` waits at that temperature). `machine.preheat_time` heats the next nozzle that many seconds before a change in the middle of a layer. Two filaments on one nozzle change with M600 (part 03).
14. The Speed section (`src/app/speed.zig`, `zs_speed_get`): the print settings that change the time of a slice, each with its measured gain and cost. The Faster slicing switch sets `project.fast_offsets` on and `project.resolution` to 0.01 mm. Its state comes from the two options (`zs_app_speed_state`: off, on, or custom). The engine options that change no G-code (`engine.threads`, `engine.draft_slices`, `engine.auto_simulate`) are app preferences. Each shell keeps them and gives them to each plate that becomes active.
15. The printer library has a T line for each model with a hot end for each extruder: the change G-code, the standby and the preheat of the ooze prevention of the default print profile, and the diameter and the offset of each nozzle. 177 models have one. Their machine profile has `nozzles`, `filament_change = tool`, and `tool_numbers = nozzle`. The field `change` is "t" for a model with a Prusa MMU, so its profile has `filament_change = tool`. The format is in the header of `src/printers.zig`.

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
- The printer owns its travel retraction too: `machine.retract_min_travel`, `z_hop`, `z_hop_only_crossing`, `retract_wipe`, `retract_wipe_distance`, and `retract_layer_change`. The library has these values for 896 of 1181 models, from their OrcaSlicer, PrusaSlicer, and Cura profiles. The Bambu Lab models have the values of the Bambu Studio presets: a 0.4 mm lift (Auto Lift), a 2 mm wipe, a retraction at each layer change, and a shortest retracted travel of 1 mm. A saved Bambu Lab printer with no travel keys gets these values at the load.
- The X2D profile has the values of its second nozzle (a bowden extruder): at most 200 mm/s, 1000 mm/s², and a 2 mm retraction at 20 mm/s.
- `project.combing_mode` (part 03) replaces the switch `project.combing`. An old `combing = true` or `false` loads as `all` or `off`.
- `filament.pressure_advance` is a layer setting. The calibration tower (part 07) needs it.
- `project.resolution` (0.005 mm) is the outline tolerance. It was `engine.resolution`. It changes the G-code, so the project keeps it and the slice is the same on each computer. The old name still sets the value, and `zs_profile_moved` counts it in a saved text. The draft slice keeps its own 0.05 mm in the settings of the slice only.
- `engine.draft_slices` (on) and `engine.auto_simulate` (on): off gives no draft slice during an edit, and no simulation after each slice.
- A setting of a region of a body (part 05) is one of `settings.region_settings`: the filament, the infill pattern, density, angles, and stack, the infill flow and speed, and the infill acceleration. The other rows say why (`zs_setting_region_note`).
- The search finds the filament first for "color", "colour", "extruder", "material", and "tool".
- A variable with a number index in the G-code of the library (`first_layer_temperature[1]`) stays as it is. The core gives the value of that slot or nozzle. `printer_library.py` writes the OrcaSlicer test `idle_temperature == 0` as `is_nil(idle_temperature[...])`.
- The library tool gives the Prusa models what their sources lack: CoreXY for the XL and the CORE One, i3 for the MK and MINI printers, and 330 mm of height for the CORE One L HF of OrcaSlicer.

## Lessons

- The accelerations were print settings first. They moved to the printer, with a migration of saved values, old projects, and sessions to the printer of the plate.
- **The travel retraction moved to the printer.** The X2D sliced with no z hop, no wipe, and no retraction at a layer change. The nozzle dragged over the tops of the support and strung between the support islands. The old project names still load and move to the printer, as the accelerations did. The profile import maps the travel keys of other slicers to the machine settings, and the avoid-crossing keys to `project.combing_mode`.
- **Save the settings again after a load that moved keys.** An older saved text can hold settings that now belong to another group. The core loads each value into its new group. Each shell then saves the groups once (the Windows app did not at first).
- **The quality menus need an order and a hint.** They listed the qualities in the order of the built-in files, in small letters, with no hint of what each sets. The core now gives the order and the summary line, so each app shows the same.
- Keep the filament diameter when the material changes.
- Keep the quality profile and the global settings of a Cura stack as levels of one cascade.
- Keep the vendor G-code of each printer in the library, and the popular printers in the core.
- **Write the idle temperature test as `is_nil`.** The CORE One presets of OrcaSlicer test `idle_temperature == 0` for a filament with no idle temperature. In zslice that value is nil, so the line that sets the nozzle to 100 °C during the bed heat-up became a comment.
- **A Prusa MMU changes with a tool change.** A plate of two filaments on an MMU printer paused with M600 at each change, twice a layer. PrusaSlicer writes T0 and T1 for these printers, and the firmware unloads and loads the filament.
- **Keep the outline tolerance in the project.** It changes the G-code, so as an engine option it made other G-code on another computer.
- A multiline value (G-code) shows its first line and " …" in a row. This is the only short form of a value. A label never ends in "…".

## Acceptance checks

1. `zslice slice part.stl -m <printer> -f <filament> -p <project> -s project.wall_count=3` uses each layer in the right order.
2. A filament that `extends` another changes one value, and the rest come from the base.
3. `zslice printers` lists more than 1000 printers of more than 180 brands. `-m <id>` loads one.
4. `zslice import cura <folder>` converts the printdeck TAZ stack, and the slice matches the Cura settings in `cura_compare`.
5. `docs/user/settings.md` is the output of `tools/settings_doc.py` with no diff.
6. A new field in `settings.zig` shows in the panel of each app with no shell code.
7. `zslice import` of a PrusaSlicer `.ini` writes a report with each value set, each clamp, and each unknown key.
8. A print of one nozzle, of the X2D, and of the H2D gives the same G-code as before the settings of each nozzle, except the list of the settings at the end of the file. An old text with `nozzle2_*` values loads them into nozzle 1.
9. Each app lists the qualities in the order Fine, Standard, Strong, Draft, Coarse, with the same summary lines.
10. The test "each Prusa model of the library prints two filaments with its checks" passes (`src/plate_job.zig`, part 03).
11. The Faster slicing switch shows custom after a change of one of its options.
