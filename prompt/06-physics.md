# 06. Physics: parts that fall, the bond to the bed, and the print as it forms

## Goal

Make the plate obey physics. A part that cannot stand falls over onto a face, as on a real bed. A brim holds a tall part up. The Grab tool picks a part up and lets it go. After each slice, a simulation of the plastic shows sagged bridges, drooped overhangs, and strands that fall where no plastic holds them. The physics is fitted to measured test prints.

## Read first

- [The print simulation](../docs/internals/print-sim.md): the model, the numbers, the calibration table, and the limits. Treat its tables as acceptance values.
- [The print as it forms](../docs/user/print-as-it-forms.md) and [Place the parts](../docs/user/parts.md).
- [Physics and materials](../docs/references/physics-and-materials.md): every constant and its source.
- The headers of `src/physics.zig`, `src/rigid.zig`, `src/bond.zig`, `src/print_sim.zig`, `src/app/sim_print.zig`, and `src/app/sim_calib.zig`.

## Build

1. `src/physics.zig`: the center of mass from the signed tetrahedra of the closed mesh. The foot is the convex hull of the lowest points (within 0.05 mm). A part whose center of mass is past its foot rolls over the edge until it rests. Supports under a part add to its foot.
2. `src/rigid.zig`: a rigid-body engine for the fall that the view shows. Mass properties by the method of Eberly. Contact points from 642 even directions (an icosphere). Sequential impulses (Catto) with friction and a Baumgarte push. A fixed step of 1/240 s, so a run is the same on each machine. A body sleeps after 0.3 s of low speed. One static plane (the bed).
3. `src/bond.zig`: the bond of the first layer and the brim. The nozzle pushes at the top of the part. Test 72 directions on the bed. Bond strength: 0.3 N/mm² for PLA and ABS on PEI, 0.45 N/mm² for PETG.
4. Settle parts in the core. A part dropped or turned on the plate settles before the slice. A thrown part stops at the edge of the bed.
5. `src/print_sim.zig`: the model in eleven steps (masses, a height field of 0.1 mm cells in 32 x 32 tiles, strands, heat by Newton's law with forced convection, viscosity laws per material, catenaries for runs held at both ends, position based dynamics for free runs, contact, failure at 1.5 mm of drop, sleep, and time jumps).
6. `src/app/sim_print.zig`: the simulation on the toolpaths of a slice. A path whose plastic moved gets a z and a bead area for each point, so the view draws a strand as one continuous bead.
7. Run the simulation after each slice on the slice thread, in pieces with a cancel check (`zs_app_set_auto_simulate`, `ZS_EVENT_SIMULATED`). A shell with no threads runs it in pieces between its messages (`zs_app_sim_begin`, `zs_app_sim_advance`). `zs_app_sim_work` gives the progress of the simulation on the slice thread, for the work bar of the view (part 08). A draft slice starts no simulation.
8. The Check lists the failed plastic.

## Numbers and rules that matter

- Materials with data: PLA 3546 Pa s at 200 °C (Arrhenius 80.6 kJ/mol), ABS 13 250 Pa s at 200 °C (WLF), PETG 3844 Pa s at 220 °C. Other types map to the nearest plastic.
- A mass sets when its viscosity passes 1e6 Pa s (PLA at about 98 °C).
- A bead of 0.45 x 0.2 mm cools with tau about 0.3 s at full fan, about 2 s in still air.
- A 20 mm bridge, PLA at 210 °C, 15 mm/s: 0.66 mm sag at full fan, 2.09 mm with no fan.
- A 3DBenchy (585 778 masses) simulates in about 1.5 s on one core, with 7 MB more memory than the slice.
- The calibration tests: overhangs of 30, 45, 60, and 80 degrees; bridges of 5, 20, 35, and 60 mm; a slab 25 mm over air. `tools/calib/` has the parts to print the same tests.

## Lessons

- Stop the print sim within a step when a slice starts. A new change must stop it at once.
- A part with edited trees stands only on the trees that hold it.
- Read only the top of a cell in the floor test of the sim.
- Fix the test of a slab over air for the bead contact: a mass beside a bead of its own layer is solid only up to 2 beads out from plastic that an earlier layer holds. So a bridge line welds to the wall, and a skin over air does not grow from line to line.

## Acceptance checks

1. A board that stands on its thin edge falls onto its wide face after a turn.
2. The bond test of a tall part gives whether it stands with the brim, whether it stands with no brim, and the margin.
3. The calibration tests in `sim_calib.zig` pass with the values of the table in the print simulation page.
4. `zslice bench part.stl --only sim --runs 1` reports the masses, the soft masses, and the time.
5. A slab 25 mm over air fails from its first layer, and the layers on it fail too.
