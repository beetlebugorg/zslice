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

- Support structures, for overhangs and bridges.
- [x] Ironing on top surfaces (`project.ironing`).
- [x] Profiles. Machine, filament, and project profiles are separate files. Load order: machine, then filament, then project, then overrides. An override can change any field, for example `filament.nozzle_temp=230` for one project. Later: overrides for each object in a project.
- [x] Profile format: TOML (a subset: comments, `key = value`, strings, numbers, booleans, multi-line strings), with a small parser in zslice. `extends = "name"` loads a base profile first. Example: a brand PLA profile, and a gray PLA profile that extends it and changes one value.
- Profile importers. Read Cura profiles (and other slicers) and convert them into zslice machine, filament, and project profiles. The printdeck TAZ profile (`printdeck/profiles/taz-workhorse-se`) is the first test case.
- 3MF load.

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

## Feature parity with PrusaSlicer and Cura

The goal is the features that people use in PrusaSlicer and Cura. zslice designs each one again, and does not copy their code or always their method. The order is by how often a print needs the feature.

### Print quality and strength
- [x] Walls, top and bottom skin, sparse infill (lines, grid)
- [x] Ironing
- [x] Support: grid support with interface layers, XY and Z gaps, everywhere or bed only
- [x] Support: tree support, support blockers and enforcers (marks in the 3D view), bridges without support (support_style bridge)
- [x] Skirt and brim
- [x] Bridges: find them, print them with their own direction, speed, flow, and fan
- [ ] Overhang walls: slower speed and more fan for overhang
- [x] Seam placement: sharpest corner (hidden), rear, nearest, random
- [x] Gap fill and thin walls with a variable line width: Arachne walls, ported from CuraEngine (`project.wall_generator = arachne`)
- [x] Infill patterns: gyroid, cubic, triangles, concentric
- [ ] Infill patterns: honeycomb, adaptive cubic
- [x] Infill patterns: lightning
- [x] Top and bottom patterns: monotonic, concentric
- [x] Infill only where needed, and denser infill under top surfaces
- [ ] Wall order (inner first or outer first) and extra walls on alternate layers
- [ ] Fuzzy skin
- [ ] Spiral vase mode
- [ ] Variable layer height (adaptive and by hand)
- [x] Size compensation: XY offset, hole offset, elephant foot, shrinkage
- [ ] Polyholes

### Motion and extrusion
- [x] Avoid crossing walls (combing) on travel
- [x] Retraction on layer change, z hop only for a travel that crosses an edge
- [ ] Wipe on retraction: a small swirl toward the inside of the part while it retracts, as a person wipes a drip
- [ ] Coasting
- [x] Acceleration and jerk control for each feature; a time estimate with acceleration
- [ ] Arc fitting (G2/G3)
- [ ] Pressure advance and input shaper calibration prints
- [x] Cooling: minimum layer time, fan boost on short layers, slow down for small layers
- [ ] Firmware flavors: Marlin, Klipper, RepRapFirmware, Bambu, with exclude-object labels

### Models and plate
- [x] More than one object on the plate, with automatic arrangement
- [x] 3MF load (parts at their places, components, units, zip64; items that overlap stay one part) and 3MF plate save (Ctrl+S)
- [ ] OBJ and STEP load
- [x] Rotate, scale, place on face ("Put this side on the bed")
- [ ] Mirror, cut
- [x] Modifiers (per-region settings), and settings for each object
- [ ] Mesh repair
- [ ] Sequential printing (one object at a time)
- [ ] Multi-material and more than one tool head: a filament (and color) for each part or region, tool changes with the start and end G-code of each tool, a wipe tower, an ooze shield, painted regions (the library has dual-extruder printers)
- [x] Sliced layer preview in 3D, with speed, flow, and feature views

### Profiles and workflow
- [x] Machine, filament, and project profiles in TOML, with `extends` and overrides (command line)
- [x] The app keeps its settings after a restart (~/.config/zslice/{machine,filament,project}.toml, only the changes from the defaults)
- [x] Profiles in the app: pick, edit, and save profiles, through the C API with a resolver callback
- [x] Import of Cura profile stacks (the printdeck layout with cura.json)
- [ ] Import of PrusaSlicer and OrcaSlicer profiles, and of a Cura profile export (.curaprofile)
- [x] Shrinkage compensation and XY offsets for outlines, holes, and the first layer (imported from the printdeck rolls)
- [x] A printer profile library
- [x] Send to printer: printdeck, OctoPrint, Moonraker
- [ ] Calibration prints: temperature tower, flow, retraction, pressure advance

## App

- [x] App core (`src/app.zig`, `include/zslice-app.h`): model, settings with descriptions, background slice with progress and cancel, layer paths for the preview, G-code export, license list
- [x] Linux shell: GTK4 (`linux/`): open (button, drop, command line), settings panel from core data, slice after each change, layer preview with zoom and pan, export, licenses
- [x] 3D view of the toolpaths: Vulkan renderer in the core, Wayland subsurface in the GTK shell
- [x] 3D view: beads with the real cross section and round ends, the deposited width, the cooled size, the filament color with PLA-like light, 4x MSAA
- [x] 3D view: CAD mouse (orbit, pan, free rotation, zoom to the pointer), smooth zoom and reset, no tilt limit
- [ ] 3D view: X11, the model mesh before the slice, a level of detail for beads smaller than a pixel
- [ ] 3D view, physics not modeled yet: the seam blob, sag on overhangs and bridges, stringing, corner rounding by acceleration
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
- [ ] 3MF: changes for each part (now the changes are for the whole plate)
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
- [ ] Ironing in the preview: the ironed top skin looks flat; the inspector shows what ironing costs in time
- [x] Plate: more than one part (open or drop many STLs), Shift+click to select a part, Shift+drag to move it, Shift+wheel to turn it, a part page, and "Arrange the plate" (rows, the largest first)
- [x] Plate: a best placement that turns each part for less support, and lay flat
- [x] Printer library: 1080 printers of 187 brands from Cura, PrusaSlicer, and OrcaSlicer (`tools/printer_library.py`, `src/printers.zig`); the printer picker with search, brands, a drawing of the build volume, and the key facts, at the first start and from the printer menu (GTK and web)
- [x] Printers on the network: mDNS for OctoPrint, printdeck, Moonraker, and PrusaLink (`src/discovery.zig`), the kind from `/api/version`, the bed from Klipper
- [ ] Printer library: the start G-code of the definitions with scripts (`{if}`, expressions: about 40 % of the models get the zslice start G-code now), more than one extruder, the bed shape of round beds in the plate and the 3D view, the heated bed and chamber in the G-code
- [ ] Printer discovery: Bambu Lab in LAN mode (SSDP), Elegoo (SDCP), Creality, and Duet; the model of a printdeck or OctoPrint printer (it needs the API key)
- [ ] Printers: a shared place for printers and their connections (printdeck remote, OctoPrint, Moonraker), and print monitoring
- [x] Replay: a nozzle marker, and the time estimate with acceleration (the replay is as exact as the time estimate)
- [ ] Projects from GitHub: open a repo with a `printdeck.yml`, slice all its parts onto plates, and a print workflow that walks through the plates and keeps the status across a restart
- [ ] Debug prints: "Print this layer" (one layer alone on the bed), and a range of about 10 layers laid flat side by side, to compare a print with the preview
- [ ] Check the G-code of each printer of the library: slice a test part with each profile and test the start and end G-code
- [x] The web app: Gaps (the red cells in both views, the count, and the gap page with Apply and This layer)
- [x] The web app: Check (the list of issues; a click shows the layer and the line)
- [x] The web app: undo and redo (Ctrl+Z, Ctrl+Shift+Z), and the History tab
- [x] The web app: the timeline bar
- [ ] The web app: the tools and the measure tape (the native app has them)
- [ ] macOS and iOS shell: SwiftUI (`apple/`)
- [ ] Windows shell: Win32 C++ (`windows/`)
- [ ] Android shell: Kotlin (`android/`)

## Performance

- [x] The polygon boolean was O(n^2) for long edges. It now finds crossings with a grid and winding numbers by a walk over the faces.
- The support column pass (`support.zig` step 2) runs on one thread. The slowest corpus file with support takes 11 s on 2 threads. Split the layers into bands that run in parallel, or use a coarser area for the carry.
- Clip open lines (infill, ironing) with a direct method, not with the scanline of a region.
- Pass one scratch arena for each layer to the boolean and offset calls.

## Ideas to test

- Zigzag walls. Replace the inner walls with one path that goes back and forth across the wall band, around the part. The goal is a stronger wall. The outer wall stays a loop for a good surface. Test: print test bars with loop walls and with zigzag walls, and break them.
- Speed from limits. The project sets a speed ratio for each feature, and the engine computes the speed from the limits of the machine and the filament. This is in milestone 1. Next: add the acceleration limits.
