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

## Feature parity with PrusaSlicer and Cura

The goal is the features that people use in PrusaSlicer and Cura. zslice designs each one again, and does not copy their code or always their method. The order is by how often a print needs the feature.

### Print quality and strength
- [x] Walls, top and bottom skin, sparse infill (lines, grid)
- [x] Ironing
- [x] Support: grid support with interface layers, XY and Z gaps, everywhere or bed only
- [ ] Support: tree support, support blockers and enforcers, bridges without support
- [x] Skirt and brim
- [ ] Bridges: find them, print them with their own direction, speed, flow, and fan
- [ ] Overhang walls: slower speed and more fan for overhang
- [x] Seam placement: sharpest corner (hidden), rear, nearest, random
- [ ] Gap fill and thin walls (variable line width, like Arachne)
- [x] Infill patterns: gyroid, cubic, triangles, concentric
- [ ] Infill patterns: honeycomb, lightning, adaptive cubic
- [ ] Top and bottom patterns: monotonic, concentric
- [ ] Infill only where needed, and denser infill under top surfaces
- [ ] Wall order (inner first or outer first) and extra walls on alternate layers
- [ ] Fuzzy skin
- [ ] Spiral vase mode
- [ ] Variable layer height (adaptive and by hand)
- [x] Size compensation: XY offset, hole offset, elephant foot, shrinkage
- [ ] Polyholes

### Motion and extrusion
- [ ] Avoid crossing walls (combing) on travel
- [ ] Wipe on retraction, retraction on layer change, z hop only above parts
- [ ] Coasting
- [ ] Acceleration and jerk control for each feature; a time estimate with acceleration
- [ ] Arc fitting (G2/G3)
- [ ] Pressure advance and input shaper calibration prints
- [x] Cooling: minimum layer time, fan boost on short layers, slow down for small layers
- [ ] Firmware flavors: Marlin, Klipper, RepRapFirmware, Bambu, with exclude-object labels

### Models and plate
- [ ] More than one object on the plate, with automatic arrangement
- [ ] 3MF, OBJ, and STEP load; 3MF project save
- [ ] Rotate, scale, mirror, place on face, cut
- [ ] Modifiers (per-region settings), and settings for each object
- [ ] Mesh repair
- [ ] Sequential printing (one object at a time)
- [ ] Multi-material: tool changes, wipe tower, ooze shield, painted regions
- [ ] Sliced layer preview in 3D, with speed, flow, and feature views

### Profiles and workflow
- [x] Machine, filament, and project profiles in TOML, with `extends` and overrides (command line)
- [ ] Profiles in the app: pick, edit, and save profiles, through the C API with a resolver callback
- [x] Import of Cura profile stacks (the printdeck layout with cura.json)
- [ ] Import of PrusaSlicer and OrcaSlicer profiles, and of a Cura profile export (.curaprofile)
- [x] Shrinkage compensation and XY offsets for outlines, holes, and the first layer (imported from the printdeck rolls)
- [ ] A printer profile library
- [ ] Send to printer: printdeck, OctoPrint, Moonraker
- [ ] Calibration prints: temperature tower, flow, retraction, pressure advance

## App

- [x] App core (`src/app.zig`, `include/zslice-app.h`): model, settings with descriptions, background slice with progress and cancel, layer paths for the preview, G-code export, license list
- [x] Linux shell: GTK4 (`linux/`): open (button, drop, command line), settings panel from core data, slice after each change, layer preview with zoom and pan, export, licenses
- [x] 3D view of the toolpaths: Vulkan renderer in the core, Wayland subsurface in the GTK shell
- [x] 3D view: beads with the real cross section and round ends, the deposited width, the cooled size, the filament color with PLA-like light, 4x MSAA
- [ ] 3D view: X11, the model mesh before the slice, pan, a level of detail for beads smaller than a pixel
- [ ] 3D view, physics not modeled yet: the seam blob, sag on overhangs and bridges, stringing, corner rounding by acceleration
- [x] Click a path in the 2D or 3D view to inspect it: its real values with the reasons, and the settings that change it, editable in place
- [ ] Replay: play the print in the 3D view, line by line, at 1x, 2x, 3x (and faster), from the move times of the G-code
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
