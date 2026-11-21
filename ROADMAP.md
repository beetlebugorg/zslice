# Roadmap

## Milestone 1: the core, from end to end

- [x] Integer geometry and a flat polygon store
- [x] Polygon booleans (planar arrangement and winding numbers)
- [x] Polygon offset
- [x] STL load (binary and ASCII) with vertex welding
- [x] Mesh slicing with chain repair for open meshes
- [x] Settings in three parts: machine, filament, and project
- [x] Line infill (scanline)
- [x] Layer plan: walls, top and bottom skin, sparse infill, path order
- [x] G-code output
- [x] Engine: two passes, multi-thread, batched output for low memory
- [x] C API, wasm build, and a JS wrapper
- [x] Command line tool with an SVG layer preview
- [x] Documentation: user guide, embedding guides (Zig, C, JS), internals (pipeline, architecture, contributing)
- [x] Corpus test: all STL files tracked in printdeck slice with no error

## Milestone 2

- [x] Support structures, for overhangs and bridges (grid and tree support).
- [x] Ironing on top surfaces (`project.ironing`).
- [x] Profiles. Machine, filament, and project profiles are separate files. Load order: machine, then filament, then project, then overrides. An override can change any field, for example `filament.nozzle_temp=230` for one project. Later: overrides for each object in a project.
- [x] Profile format: TOML (a subset: comments, `key = value`, strings, numbers, booleans, multi-line strings), with a small parser in zslice. `extends = "name"` loads a base profile first. Example: a brand PLA profile, and a gray PLA profile that extends it and changes one value.
- [x] Profile importers: Cura profile stacks (the printdeck TAZ profile `printdeck/profiles/taz-workhorse-se` is the first test case). PrusaSlicer and OrcaSlicer profiles are still open (see below).
- [x] 3MF load.

## Done in November 2026

- [x] The web app on WebAssembly (zslice.beetlebug.org): the same window as the GTK app, the 2D view, the Selected page, the context menu, a resizable panel, and the plate kept across a refresh
- [x] Printer onboarding: a library of 1181 printers from Cura, Cura LulzBot Edition, PrusaSlicer, and OrcaSlicer, a picker with search, network search (printdeck, OctoPrint, Moonraker, PrusaLink), and the bed model of 830 printers in the 3D view
- [x] A history of changes: a timeline with a badge for each kind of change, a History tab, a click goes back to a change, a double click edits it, undo of one change, and marks on the layer slider for the changes of some layers
- [x] Tools: Select, Move, and Measure; a measure tape that snaps to the ends of the lines and to the centers of circles; the measurements of a selected line (segment, edge, path, radius)
- [x] Retractless top and bottom skin: the pieces of the skin join into few paths along the walls
- [x] Gap fill, and bridges for skin and for walls
- [x] Smart placement that counts the islands of an orientation (a part on a 45 degree edge)
- [x] Infill ribs: a line in each narrow infill area that a sparse infill misses
- [x] A Cura-like camera: a left or right drag orbits with the bed level; a touchpad pans with two fingers and zooms with a pinch
- [x] A privacy page: no analytics, no cookies, nothing loaded from other sites

## Done from November 17 to November 21, 2026

- [x] The Paint tool: paint the faces of a part with a filament, a smart select, painted 3MF files, and a root of a painted feature that grows into the part (web, GTK, Mac)
- [x] Filaments: the filaments of the plate, the spools loaded in the printer (printdeck and Bambu Lab AMS), a filament for the support
- [x] Labels: text, lines, bars, rings, and dial ticks on the surface of a part, in a filament of their own, with a TrueType reader and the Inter font (web, GTK, Mac)
- [x] Cut a part with a level plane and pegs, split a part into its bodies, and copy, cut, and paste of each kind of object
- [x] Projects: save and open all plates as one project file, many copies of a part over plates, the sum of the time and cost of all plates
- [x] The Support tool: support areas that add or block support, an overhang under the pointer that gets support in one click, and an editor of the support trees
- [x] Physics: a part that cannot stand falls over, a Grab tool, the bond of the first layer to the bed
- [x] Print as it forms: a simulation of the plastic of the print, calibrated with measured prints
- [x] Bambu Lab printers: LAN discovery, MQTT, the .gcode.3mf file of Bambu Studio for each model, the cameras, two-nozzle printers
- [x] The Printers page: printers, jobs, cameras, and a send of each plate of a project
- [x] Signed G-code files, and a pinned certificate for each printer
- [x] An embeddable G-code viewer for web pages, in the npm package
- [x] An exact restore of the session after a reload or a quit
- [x] Thumbnails in the G-code for the printer screen
- [x] Edits of single lines: delete one, change its plastic, or add a drop of plastic
- [x] Fuzz tests of the readers of outside files and packets
- [x] The core as a Windows library (MSVC)

## Feature parity with PrusaSlicer and Cura

The goal is the features that people use in PrusaSlicer and Cura. zslice designs each one again, and does not copy their code or always their method. The order is by how often a print needs the feature.

### Print quality and strength
- [x] Walls, top and bottom skin, sparse infill (lines, grid)
- [x] Ironing
- [x] Support: grid support with interface layers, XY and Z gaps, everywhere or bed only
- [x] Support: tree support, support blockers and enforcers (marks in the 3D view), bridges without support (support_style bridge)
- [x] Skirt and brim
- [x] Bridges: find them, print them with their own direction, speed, flow, and fan
- [x] Overhang walls: slower speed and more fan for the parts of a wall over air (`project.overhang_wall_speed`, `project.overhang_wall_fan`); a wall a whole line over air prints as a bridge
- [x] Seam placement: sharpest corner (hidden), rear, nearest, random
- [x] Gap fill and thin walls with a variable line width: Arachne walls, ported from CuraEngine (`project.wall_generator = arachne`)
- [x] Infill patterns: gyroid, cubic, triangles, concentric
- [x] Infill patterns: honeycomb, zigzag, flow
- [ ] Infill patterns: adaptive cubic
- [x] Infill patterns: lightning
- [x] Top and bottom patterns: monotonic, concentric
- [x] Infill only where needed, and denser infill under top surfaces
- [x] Wall order (inner first or outer first, `project.wall_order`) and an extra wall on alternate layers (`project.alternate_extra_wall`)
- [x] Fuzzy skin (`project.fuzzy_skin`: the outer walls, or only the outside)
- [x] Spiral vase mode (`project.spiral_vase`)
- [x] Variable layer height by hand: a layer height for some layers (an override by z range)
- [ ] Variable layer height: adaptive (from the slope of the surface)
- [x] Size compensation: XY offset, hole offset, elephant foot, shrinkage
- [ ] Polyholes

### Motion and extrusion
- [x] Avoid crossing walls (combing) on travel
- [x] Retraction on layer change, z hop only for a travel that crosses an edge
- [x] Wipe on retraction: a small arc inside the part while it retracts (`project.retract_wipe`), and a wipe along the start of a closed outer wall (`project.outer_wall_wipe`)
- [ ] Coasting
- [x] Acceleration and jerk control for each feature; a time estimate with acceleration
- [ ] Arc fitting (G2/G3)
- [x] Pressure advance for each filament (`filament.pressure_advance`: M900, SET_PRESSURE_ADVANCE, M572)
- [ ] Pressure advance and input shaper calibration prints
- [x] Cooling: minimum layer time, fan boost on short layers, slow down for small layers
- [x] Firmware flavors: Marlin, Klipper, RepRapFirmware, Repetier; Bambu Lab .gcode.3mf files with the header, the config blocks, and the slice info of Bambu Studio
- [ ] Exclude-object labels (Klipper EXCLUDE_OBJECT, M486)

### Models and plate
- [x] More than one object on the plate, with automatic arrangement
- [x] 3MF load (parts at their places, components, units, zip64; items that overlap stay one part) and 3MF plate save (Ctrl+S)
- [x] OBJ load (the vertices and the faces, in mm)
- [x] STEP load (AP203, AP214, AP242 B-rep solids: planes, cylinders, cones, spheres, tori, B-spline, extrusion, and revolution faces, made into a mesh within 0.01 mm)
- [ ] STEP: the placements of the parts of an assembly
- [x] Rotate, scale, place on face ("Put this side on the bed")
- [x] Cut: a level plane, with closed caps, and pegs to join the two parts
- [x] Split a part into its separate bodies
- [x] Mirror along the X or Y axis of the bed (web and GTK)
- [x] Modifiers (per-region settings), and settings for each object
- [ ] Mesh repair
- [ ] Sequential printing (one object at a time)
- [x] Multi-material: a filament (and color) for each part, each layer range, the support, and each painted region (the Paint tool and painted 3MF files); filament changes with the change G-code of the printer; the order of the filaments of a layer for the least flush; flush into the hidden infill and support
- [x] Prime towers: one for each family of materials that bond, sized from the purge of each layer, in the 3D view
- [x] Printers with two nozzles (Bambu Lab H2D and X2D): a nozzle for each filament, and checks of the reach of each nozzle
- [ ] An ooze shield
- [x] Sliced layer preview in 3D, with speed, flow, and feature views

### Profiles and workflow
- [x] Machine, filament, and project profiles in TOML, with `extends` and overrides (command line)
- [x] The app keeps its settings after a restart (~/.config/zslice/{machine,filament,project}.toml, only the changes from the defaults)
- [x] Profiles in the app: pick, edit, and save profiles, through the C API with a resolver callback
- [x] Import of Cura profile stacks (the printdeck layout with cura.json)
- [x] A list of each Cura and OrcaSlicer setting with its zslice setting (docs/user/setting-coverage.md)
- [ ] Import of PrusaSlicer and OrcaSlicer profiles, and of a Cura profile export (.curaprofile)
- [x] Shrinkage compensation and XY offsets for outlines, holes, and the first layer (imported from the printdeck rolls)
- [x] A printer profile library
- [x] Send to printer: printdeck, OctoPrint, Moonraker (native; the web app since 0.1.0-beta, and printer.json for a printer that serves the app)
- [x] Send to a Bambu Lab printer in LAN mode (MQTT, the certificate pinned), and through a printdeck
- [x] Signed prints: the core signs and checks G-code files, and the apps pin the certificate of a printer
- [ ] Calibration prints: temperature tower, flow, retraction, pressure advance

## App

- [x] App core (`src/app.zig`, `include/zslice-app.h`): model, settings with descriptions, background slice with progress and cancel, layer paths for the preview, G-code export, license list
- [x] Linux shell: GTK4 (`linux/`): open (button, drop, command line), settings panel from core data, slice after each change, layer preview with zoom and pan, export, licenses
- [x] 3D view of the toolpaths: Vulkan renderer in the core, Wayland subsurface in the GTK shell
- [x] 3D view: beads with the real cross section and round ends, the deposited width, the cooled size, the filament color with PLA-like light, 4x MSAA
- [x] 3D view: CAD mouse (orbit, pan, free rotation, zoom to the pointer), smooth zoom and reset, no tilt limit
- [x] 3D view: the model mesh (the Paint, Label, and Support tools), light beads for far layers
- [ ] 3D view: X11 in the GTK app (the 3D view needs Wayland)
- [x] Print as it forms: a simulation of the plastic (strands that sag and creep, catenary bridges), fit to measured prints, with the failed plastic in the Check
- [ ] 3D view, physics not modeled yet: the seam blob, stringing, corner rounding by acceleration
- [x] Click a path in the 2D or 3D view to inspect it: its real values with the reasons, and the settings that change it, editable in place
- [x] Replay: play the print in the 3D view, line by line, at 1x, 2x, 3x, 10x, 30x, 100x, from the move times of the G-code
- [x] Live settings: a value goes to the core after a pause in the typing; Up, Down, and a drag on the label step it; units on each value, ratios as percentages; all editors of a setting stay in sync
- [x] A stable UI during a new slice: the inspector updates in place, the tab stays, the status bar keeps its size and dims the old numbers
- [x] Settings browser in columns: sections, then settings, then the help and the lines of the project that the setting changes, highlighted in the preview, with their share of the print time; search; defaults with reset
- [x] Realtime sliders: drag a value (infill density, speeds) and see the slice change as fast as the slicer can go (the layer regions stay between slices; the shell queues values instead of a restart)
- [x] Usual ranges (sliders, a warning out of them) and hard limits (an error) for the number settings
- [x] Focus: the lines that a setting changes are solid, and the other lines are ghosts that do not hide them
- [x] Each setting shows in the preview: lines, or marks (seam blobs, travel moves, retractions), or a note (a test checks it); a section shows the lines of all its settings
- [x] The selection stays on the same kind of line when a new slice moves it (a new skirt distance)
- [x] The preview controls and a thin layer slider float over the view
- [x] Slider steps that people use (0.01 mm for a layer height, 5 degrees for a temperature), with a tick at the default
- [ ] Faster skin regions: a sliding window for the stacked intersection, then SIMD in the boolean
- [x] Machine origin: the G-code position of the front left bed corner (center origin printers, Cura machine_center_is_zero)
- [x] Top and bottom skin patterns: lines, monotonic, concentric; the skin angle and its turn per layer
- [x] Changes for the part (inline): for all its layers, or for some layers (overrides by z range); the Settings page has the defaults for all prints
- [x] 3MF: save the parts with their changes and overrides; with more than one STL, one new 3MF with all of them
- [x] 3MF: changes for each part ("+ Add a setting for this part"); a part with its own settings slices as its own job
- [x] Preferences window: printers (more than one, each with its machine settings), connections (printdeck, OctoPrint, Moonraker, USB serial), a connection test that reads the bed, the nozzle, and the filament of the printer, global app settings (theme, first view, threads)
- [x] Send to the printer (upload, or upload and print), and the state of the printer in the status bar
- [x] Seam mode "hidden" (the default): the most hidden point (inside corners over about 1 mm, the back, not over air; ties to the back, so the seams line up)
- [x] More infill: honeycomb; zigzag (lines joined at the walls, no travel between them); flow (zigzag, twice as dense in a band under the top surfaces)
- [ ] More infill: adaptive cubic; make flow cheaper (the band costs a stacked intersection on the first slice, and memory in the cache)
- [x] Skin expand distance, skin removal width, and solid infill for narrow sparse areas (no gaps between the top skin and the walls)
- [x] Thin walls: a loop with a narrower line in each part thinner than one line width
- [x] Thin walls with a variable line width along the part (`project.wall_generator = arachne`)
- [ ] Arachne walls as the default wall generator, after test prints
- [x] Tree support (support_style = tree): tips on a grid under pads, branches that join and get thicker, thinner in narrow spaces (deep holes)
- [ ] Tree support: faster (1.4 s on the camera arm, grid 0.4 s), branch routing around the part toward the bed, a preview of the branch nodes
- [x] Layer times: in the layer slider (with a mark for a layer that min_layer_time slows down), and a color mode by layer time
- [x] A cooling lap (filament.cooling_mode = lap): a short layer prints at full speed, then the head moves 1 mm over it with the fan at full until the min layer time
- [ ] The cooling lap in the preview and the replay (its moves are not in the toolpaths yet)
- [ ] printdeck web module: the core in wasm, a WebGPU backend for the 3D view, the slicer in the printdeck web UI and cloud
- [ ] Combing: travel inside the part over the infill and the inner walls, with no retraction, and faster
- [x] Preview color modes in 3D: filament, feature, speed, flow, layer time, line width, with the range of the ramp
- [ ] Color modes in the 2D view, and a layer height mode (with variable layer heights)
- [x] Ironing in the preview: an ironed top draws as a flat sheet
- [ ] Ironing in the inspector: what ironing costs in time
- [x] Plate: more than one part (open or drop many STLs), Shift+click to select a part, Shift+drag to move it, Shift+wheel to turn it, a part page, and "Arrange the plate" (rows, the largest first)
- [x] Plate: a best placement that turns each part for less support, and lay flat
- [x] Printer library: 1080 printers of 187 brands from Cura, PrusaSlicer, and OrcaSlicer (`tools/printer_library.py`, `src/printers.zig`); the printer picker with search, brands, a drawing of the build volume, and the key facts, at the first start and from the printer menu (GTK and web)
- [x] Printers on the network: mDNS for OctoPrint, printdeck, Moonraker, and PrusaLink (`src/discovery.zig`), the kind from `/api/version`, the bed from Klipper
- [x] Printer library: the start and end G-code of the definitions with their scripts (the variables, `{if}`, and the expressions of Cura, PrusaSlicer, OrcaSlicer, and Bambu Studio), the vendor G-code, and a check of the G-code of each printer
- [ ] Printer library: more than one extruder for the printers other than Bambu Lab, the bed shape of round beds in the plate
- [x] Printer discovery: Bambu Lab in LAN mode (SSDP); an API key from the printer in one step
- [ ] Printer discovery: Elegoo (SDCP), Creality, and Duet
- [x] Printers: the Printers page (web, GTK, Mac) with the printers, their jobs, their temperatures, and their cameras (RTSP for Bambu Lab); a farm model in the core
- [x] Replay: a nozzle marker, and the time estimate with acceleration (the replay is as exact as the time estimate)
- [x] Projects from GitHub in the web app: open a repo or a folder with a `printdeck.yml`, choose the parts, slice each plate with its Cura profile stack, and keep the status of each plate across a reload
- [x] Projects in the desktop app: the Project tab of the GTK app, the same as the web app, with the project and the status of each plate in `~/.config/zslice/project.json`
- [x] Debug prints: "Print this layer" (one layer, or a range of layers, alone on the bed)
- [ ] Debug prints: a range of about 10 layers laid flat side by side, to compare a print with the preview
- [x] Check the G-code of each printer of the library: slice a test part with each profile and test the start and end G-code
- [x] The web app: Gaps (the red cells in both views, the count, and the gap page with Apply and This layer)
- [x] The web app: Check (the list of issues; a click shows the layer and the line)
- [x] The web app: undo and redo (Ctrl+Z, Ctrl+Shift+Z), and the History tab
- [x] The web app: the timeline bar
- [x] The web app: the tools (Select, Move, Measure) and the measure tape with circles
- [x] macOS shell: Swift and Metal (`macos/`)
- [ ] Windows shell: Win32 C++ (`windows/`); the core builds as a Windows library for MSVC
- [ ] Android shell: Kotlin (`android/`)

## Performance

- [x] The polygon boolean was O(n^2) for long edges. It now finds crossings with a grid and winding numbers by a walk over the faces.
- The support column pass (`support.zig` step 2) runs on one thread. The slowest corpus file with support takes 11 s on 2 threads. Split the layers into bands that run in parallel, or use a coarser area for the carry.
- [x] Clip open lines (infill, ironing) with a direct method (`clip_open.zig`), not with the scanline of a region.
- [x] A pool of scratch arenas for the boolean and offset calls (`scratch.zig`).

## Ideas to test

- Zigzag walls. Replace the inner walls with one path that goes back and forth across the wall band, around the part. The goal is a stronger wall. The outer wall stays a loop for a good surface. Test: print test bars with loop walls and with zigzag walls, and break them.
- Speed from limits. The project sets a speed ratio for each feature, and the engine computes the speed from the limits of the machine and the filament. This is in milestone 1. Next: add the acceleration limits.
