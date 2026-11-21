# Bambu Studio and Bambu Lab

The data, the G-code templates, and the formats that zslice uses from Bambu Studio (AGPL-3.0) and the Bambu Lab printers.

## Data in the binaries

### Bambu Lab X2D project settings and G-code layout

```ref
kind: data
source: Bambu Studio
license: AGPL-3.0
files: src/bambu.zig, src/gcode.zig
area: printers
summary: The keys guide `gcode.Emitter.bambuBlocks` and `src/bambu.zig`. The G-code templates of this file are the same as those of the presets of Bambu Studio (next line).
```

The whole project_settings.config of the Bambu Lab X2D (in `src/printers/bambu/bambu-lab-x2d-project.json`, the base of the project settings of an X2D file), its G-code config block (`src/printers/bambu/bambu-lab-x2d-config.txt`), the layout of its G-code (the header, config, and executable blocks, `; MACHINE_START_GCODE_END`, `; MACHINE_END_GCODE_START`, `M981`), and the keys of its slice_info.config: a .gcode.3mf that Bambu Studio 02.09.01.70 wrote for the X2D (the user's file, 19 November 2026)

**License:** AGPL-3.0 (the license of Bambu Studio and its profiles)

**Text:** `LICENSE`

**Notes:** The keys guide `gcode.Emitter.bambuBlocks` and `src/bambu.zig`. The G-code templates of this file are the same as those of the presets of Bambu Studio (next line).

### Bambu Lab X2D values of the second nozzle

```ref
kind: data
source: Bambu Studio
license: AGPL-3.0
files: src/printers.zig, src/settings.zig
area: printers
summary: The machine profile of the X2D in the printer library gets the values of extruder 2 that differ from extruder 1.
```

The per-extruder lists of the X2D project settings (see the entry before): `print_extruder_id` (the extruder of each extruder variant), and for the first variant of extruder 2 (Bowden Standard) `retraction_length` (2 mm, 0.8 mm on extruder 1), `retraction_speed` (20 mm/s, 30 mm/s on extruder 1), `default_acceleration` (1000 mm/s², 10000 on extruder 1), and the fastest of `outer_wall_speed`, `inner_wall_speed`, `sparse_infill_speed`, `internal_solid_infill_speed`, and `top_surface_speed` (200 mm/s). Bambu Studio keeps the values of each extruder variant in these lists; zslice keeps a speed ratio and limits for the second nozzle.

**License:** AGPL-3.0 (the license of Bambu Studio and its profiles)

**Text:** `LICENSE`

**Notes:** `printers.secondNozzle` reads the lists from the embedded project settings. `Library.profileText` writes `machine.nozzle2_max_speed`, `nozzle2_max_accel`, `nozzle2_retract_length`, and `nozzle2_retract_speed` for the X2D.

### Bambu Lab printer facts and G-code templates

```ref
kind: data
source: Bambu Studio
license: AGPL-3.0
link: https://github.com/bambulab/BambuStudio
version: commit 8e524a39d4c4cd0541801c1c46d2f77debb0bf1d
files: tools/bambu_facts.py, src/printers/bambu.txt, src/gcode_vars.zig
area: printers
summary: The facts and the G-code templates of the Bambu Lab printers, as data and as embedded templates.
```

The facts and the G-code templates of the Bambu Lab printers: model_id (the model code, for example N6 for the X2D) of the machine models; nozzle_diameter, extruder_printable_area, extruder_printable_height, extruder_type, default_nozzle_volume_type, retract_length_toolchange, hotend_heating_rate, hotend_cooling_rate, retraction_distances_when_cut, and long_retractions_when_cut of the 0.4 nozzle presets; and their machine_start_gcode, machine_end_gcode, layer_change_gcode, and change_filament_gcode (each in a preset "<preset> template <key>"), in `resources/profiles/BBL/machine` of Bambu Studio, https://github.com/bambulab/BambuStudio, commit `8e524a39d4c4cd0541801c1c46d2f77debb0bf1d` (17 November 2026)

**License:** AGPL-3.0 (the license of the Bambu Studio repository)

**Text:** `LICENSE`

**Notes:** `tools/bambu_facts.py` reads them into `src/printers/bambu.txt` (as data) and writes the templates as they are into `src/printers/bambu/<id>-start.gcode`, `-end.gcode`, `-layer.gcode`, and `src/printers/change/<id>.gcode`. `printers.bambu` gives the facts: the profile of a printer with two nozzles gets the reach of each nozzle, its .gcode.3mf gets printer_model_id and printer_model, and `src/gcode_vars.zig` gives the values of the presets to the templates. `printers.bambuTemplate` and `printers.changeGcode` embed the templates in all binaries, the wasm module too.

## Algorithms, formats, and conventions

### Bambu Lab filament change

```ref
kind: format
source: Bambu Studio
license: AGPL-3.0
link: https://github.com/bambulab/BambuStudio
files: src/gcode_vars.zig, src/filaments.zig, src/gcode.zig
area: gcode
summary: The variables of a change G-code.
```

The filament change of Bambu Lab printers: the `change_filament_gcode` of the machine presets (for example `Bambu Lab X2D 0.4 nozzle template change_filament_gcode.json` in the BBL profiles of Bambu Studio, https://github.com/bambulab/BambuStudio, `resources/profiles/BBL/machine`), and its placeholders (`next_filament_id`, `flush_length`, `old_filament_temp`, `new_filament_temp`, `toolchange_count`, `x_after_toolchange`, `old_retract_length_toolchange`, `new_retract_length_toolchange`, `new_extruder_retracted_length`, as `GCode::set_extruder` of Bambu Studio sets them); the flushing volumes and their multiplier, as the Bambu Lab wiki describes them ("Reduce wasting during filament change", https://wiki.bambulab.com/en/software/bambu-studio/reduce-wasting-during-filament-change)

**License:** AGPL-3.0 (the profiles, as data: the names of the placeholders, no code); the wiki is a public document

**Used in:** `src/gcode_vars.zig`, `src/filaments.zig`, `src/gcode.zig`

**How zslice uses it:** The variables of a change G-code. The rule that a change from a dark color to a light color flushes more; zslice has its own simple formula for the volume (see `src/filaments.zig`).

### Prime tower of a Bambu Lab change

```ref
kind: idea
source: Bambu Studio
license: AGPL-3.0
version: Bambu Studio 02.09.01.70
files: src/gcode.zig, src/plate_job.zig, src/render/view.zig
area: gcode
summary: The order of a change (change, flush, prime and wipe on a tower at the z of the layer, then the part), the prime volume, the grid layers of the tower, the idle nozzle of a head with two nozzles, and the reheat after the cooling before the tower.
```

The prime tower and the filament change of Bambu Studio, as a .gcode.3mf of the user's X2D shows them (Bambu Studio 02.09.01.70, two filaments on two nozzles, 19 November 2026):

- The order of a change: the old filament prints its tower layer ("CP TOOLCHANGE START"), the change G-code (M620, T, M621) flushes into the chute, the nozzle goes to the tower at the z of the layer, a short line and a wipe, then the prime rows ("CP_TOOLCHANGE_WIPE"), a 2 mm wipe back along the last row with the retraction, then the part.
- The prime of the new filament on the tower: `filament_prime_volume` = 45 mm³.
- A switch of the nozzles flushes nothing (`L0` in M620.10): each nozzle holds its own filament. The flush matrix of a nozzle counts only the changes in that nozzle.
- The tower grows on each layer (`wipe_tower_no_sparse_layers` = 0). A layer with no change prints its walls and a sparse grid ("CP EMPTY GRID") of lines across the rows, about 9 mm apart.
- The change G-code sets the new nozzle `filament_cooling_before_tower` (10 °C) below its temperature (M620.15 C). After the first lines on the tower, the slicer sets the print temperature again ("M104 ... ;Wipe tower reheat before wipe").
- The idle nozzle of a head with two nozzles: M104 T (the firmware index of the nozzle, `physical_extruder_map`) to `filament_preheat_temperature_delta` (10 °C) below its temperature when the print uses it again soon ("Multi extruder pre heating"), or off for a long wait.

**License:** AGPL-3.0 (the method and the values, no code)

**Used in:** `src/gcode.zig` (`Emitter.changeTool`, `towerPurge`, `towerFinish`, `towerWipe`, `tower_prime_mm3`, `idle_nozzle_delta`, `grid_gap`), `src/plate_job.zig` (`PlateJob.towers`), `src/render/view.zig` (`View.loadTower`)

**How zslice uses it:** The same order of a change, the prime of 45 mm³, no flush at a switch of the nozzles, a tower that grows on each layer up to its last change with a grid of lines at most 5 mm apart, the print temperature after M620.15, and the idle nozzle at 10 °C below its temperature (zslice does not turn it off: it does not know the time to the next use).

### Bambu Lab LAN mode

```ref
kind: format
source: Bambu Lab
license: Public documents and tools; the formats and messages, no code
files: src/discovery.zig, src/bambu.zig, src/app/printer_status.zig, macos/Sources/ZSlice/Core/Bambu.swift, linux/src/net/bambu-link.c, linux/src/ui/camera-view.c, macos/Sources/ZSlice/Core/Camera.swift
area: network
summary: zslice finds Bambu printers on the network, writes the file they print, and makes the messages that start a print and read its status.
```

The LAN mode of Bambu Lab printers: the SSDP packets on UDP port 2021 (`DevModel.bambu.com`, `DevName.bambu.com`, `USN`), the `.gcode.3mf` layout (`Metadata/plate_1.gcode` and its `.md5`), the FTPS upload (port 990, user `bblp`, the access code), and the MQTT topics and messages (`device/<serial>/request`, `project_file`, `pushall`, the `print` report fields), as the Bambu Lab wiki and open source LAN tools describe them (for example the Home Assistant integration ha-bambulab, MIT)

**License:** Public documents and tools; the formats and messages, no code

**Used in:** `src/discovery.zig`, `src/bambu.zig`, `src/app/printer_status.zig`, `macos/Sources/ZSlice/Core/Bambu.swift`, `linux/src/net/bambu-link.c`, `linux/src/ui/camera-view.c`, `macos/Sources/ZSlice/Core/Camera.swift`

**How zslice uses it:** zslice finds Bambu printers on the network, writes the file they print, and makes the messages that start a print and read its status. The temperatures (`nozzle_temper`, `bed_temper`, `chamber_temper`, the targets, and the packed `device.extruder.info[].temp` of the printers with two nozzles, as ha-bambulab reads it). The camera: RTSP over TLS on port 322 at `/streaming/live/1` (X1, H2, P2S, X2D, with "LAN Only Liveview" on), or JPEG frames over TLS on port 6000 after an 80-byte login (P1, A1), as ha-bambulab (MIT) and open-bambu-networking (https://github.com/ClusterM/open-bambu-networking) describe them. Status and RTSPS camera read from a real X2D in November 2026; the upload and the start are not yet tested with a real printer.

### Bambu Lab AMS trays and the AMS mapping

```ref
kind: format
source: Bambu Lab
license: Public documents and tools; the formats and messages, no code
link: https://github.com/ClusterM/open-bambu-networking
files: src/app/printer_status.zig, src/app/printer_filaments.zig, src/bambu.zig, src/gcode.zig, src/gcode_vars.zig
area: network
summary: The spools of the AMS in a report, the tray of each filament in the start message, and the first filament that the start G-code loads.
```

The trays of a Bambu Lab report: `print.ams.ams[]` (each AMS unit, `id`) with its `tray[]` (`id`, `tray_type`, `tray_color` as RRGGBBAA, `tray_info_idx`), the external spool `vt_tray` (id 254), and `vir_slot` on the printers with two nozzles (255 the main nozzle, 254 the second), as ha-bambulab (MIT) reads them. The tray of each filament in the `project_file` message: `ams_mapping` (the AMS unit times 4 and the tray; -1 for a filament with no tray and for an external spool) and `ams_mapping2` (`ams_id` and `slot_id` of each filament; 255 and 255 for none), as the network plugin of Bambu Studio sends them (open-bambu-networking, print_job.cpp) and as the printdeck deck sends them (deck/internal/bambu/bambu.go, with the note of bambuddy on the external spool). The start G-code of Bambu Studio loads `initial_no_support_filament_id`, the first filament of the print.

**License:** Public documents and tools; the formats and messages, no code

**Used in:** `src/app/printer_status.zig`, `src/app/printer_filaments.zig`, `src/bambu.zig`, `src/gcode.zig`, `src/gcode_vars.zig`

**How zslice uses it:** zslice reads the trays of a report (and the same list from a printdeck), makes the filaments of the plate the same, and writes the tray of each filament in the start message of the macOS app (`zs_bambu_start_packet_trays`). The start G-code loads the first filament of the print. An X2D stopped a zslice file in PREPARE with "Failed to get AMS mapping table" (21 November 2026): the file loaded filament 1, and the deck mapped only filament 4. zslice has not yet read the trays from a real printer; the printdeck deck reads them from the X2D.

## G-code names and settings

### Bambu Studio feature names and plate files

```ref
kind: format
source: Bambu Studio
license: AGPL-3.0
link: https://github.com/bambulab/BambuStudio
files: src/gcode.zig, src/bambu.zig, src/settings.zig
area: gcode
summary: The feature names of Bambu G-code (`; FEATURE:`), the time format, `plate_1.json`, and the bed type names (`curr_bed_type`).
```

Bambu Studio names each feature with `; FEATURE: ` and a name of its own, writes the time as "1h 12m 43s", writes `Metadata/plate_1.json` with the box of the parts, and names the bed types (`curr_bed_type`: "Cool Plate", "Engineering Plate", "High Temp Plate", "Textured PEI Plate", "SuperTack Plate"). OrcaSlicer has the same bed type names. zslice writes the same names in a file for a Bambu Lab printer (`src/gcode.zig`, `src/bambu.zig`, `BedType.studioName` in `src/settings.zig`). The names only; no code is copied.
