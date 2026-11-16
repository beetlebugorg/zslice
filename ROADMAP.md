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
- Ironing on top surfaces.
- Profiles. Machine, filament, and project profiles are separate files. Load order: machine, then filament, then project, then overrides. An override can change any field, for example `filament.nozzle_temp=230` for one project. Later: overrides for each object in a project.
- Profile format: TOML (a subset: comments, `key = value`, strings, numbers, booleans, multi-line strings), with a small parser in zslice. `extends = "name"` loads a base profile first. Example: a brand PLA profile, and a gray PLA profile that extends it and changes one value.
- Profile importers. Read Cura profiles (and other slicers) and convert them into zslice machine, filament, and project profiles. The printdeck TAZ profile (`printdeck/profiles/taz-workhorse-se`) is the first test case.
- 3MF load.

## Ideas to test

- Zigzag walls. Replace the inner walls with one path that goes back and forth across the wall band, around the part. The goal is a stronger wall. The outer wall stays a loop for a good surface. Test: print test bars with loop walls and with zigzag walls, and break them.
- Speed from limits. The project sets a speed ratio for each feature, and the engine computes the speed from the limits of the machine and the filament. This is in milestone 1. Next: add the acceleration limits.
