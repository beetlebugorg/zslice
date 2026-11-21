# The print simulation

zslice can simulate the plastic of a slice: it comes out of the nozzle, rests where the bed or an earlier layer holds it, and hangs or falls where no plastic holds it. It cools with the fan and sets. The next layers print on the shape that formed. So a bridge sags, an overhang droops, and a slab with no support falls in strands, and the layers after it print on the strands.

To see it in the app, read [The print as it forms](../user/print-as-it-forms.md). The code is in `src/print_sim.zig` (the model) and `src/app/sim_print.zig` (the toolpaths in and out). The sources are in [Physics and materials](../references/physics-and-materials.md).

## Use it

- Zig: `App.simulatePrint()` runs it on the last slice and returns its numbers. Then `App.allToolpaths()` gives the paths as the plastic set, until `App.showSimulated(false)` or the next slice.
- C: `zs_app_simulate_print(app, &stats)`, then `zs_view_load(view, app)` to draw it. The stats give the failed masses, the first failed layer, the largest drop, and the plastic that the simulation used. `zs_app_sim_stats` gives them again with no new simulation, and `zs_app_sim_layer` gives the largest drop and the failed masses of each layer. `zs_app_show_simulated(app, 0)` shows the slice again, and `zs_app_show_simulated(app, 1)` the simulation.
- After each slice: with `App.auto_simulate` (C: `zs_app_set_auto_simulate`), the simulation runs on the thread of the slice, in pieces with a check of the cancel flag, so a change stops it at once. `ZS_EVENT_SIMULATED` tells the shell, and `zs_app_sim_adopt` (or `zs_app_show_simulated(app, 1)`) shows it. A shell with no threads (the web worker) runs it in pieces: `zs_app_sim_begin`, then `zs_app_sim_advance` between its messages. The Linux app and the web app do this after each slice, and their colors menu switches between the simulated plastic and the plan.
- `zslice bench part.stl --only sim --runs 1` measures it (see [The command line](../user/command-line.md)).

A path whose plastic set where it printed keeps its points. A path with plastic that moved gets a point for each mass, with a nozzle z (`point_z`) and a bead area (`point_area`) for each point. A view draws such a bead down to the top of the layer under the path. Plastic that fell under that layer keeps the bead height of its path, and each link spans the z of its two ends, so a strand that hangs or falls is one continuous bead (`src/render/view.zig`).

The toolpaths of the simulation also keep, for each such point, the place where the nozzle laid the plastic (`point_from`) and the print time when it set (`point_set_time`). A replay draws the toolhead on the planned path. The plastic leaves the nozzle there, and falls to the place where it set as from rest: the share of the way grows as the square of the share of the time.

## The model

1. **Masses.** Each path is a chain of masses at equal spacing, about half a bead width. A mass comes out at the time that the nozzle passes its point. Its mass is the density times the bead area times its share of the path. The total is the plastic of the slice.
2. **Support.** A height field keeps the top of the solid plastic in cells of 0.1 mm. The field has tiles of 32 x 32 cells, and only the tiles with plastic use memory. A new mass is solid at once if the bed or an earlier layer is under its bead (within the reach of the strand: out of the nozzle the plastic is a round strand of the bead area, so it reaches past the bottom of the bead by its diameter less the bead height, about 0.13 mm for a bead of 0.45 x 0.2 mm). A mass beside a bead of its own layer, at its height, is also solid, up to 2 beads out from plastic that an earlier layer holds. So the end of a bridge line welds to the wall, but a skin over air does not grow from line to line. Else the mass is soft.
3. **Strands.** A path that starts at the end of the path before it, with no retraction, is the same strand. The slicer splits a wall into pieces over air and on plastic, and the nozzle prints them as one line.
4. **Heat.** A soft mass cools by Newton's law with the time of a lumped bead: tau = rho c (A / P) / h. The heat transfer h is about 80 W/(m² K) in still air. The fan adds the forced convection of a thin cylinder (Hilpert). At full fan a bead of 0.45 x 0.2 mm cools with tau of about 0.3 s, and in still air with tau of about 2 s. The plastic cools toward the air around it: `machine.chamber_temp` (the room, or a heated chamber), and warmer near a hot bed (`filament.bed_temp`), in a layer of about 3 mm (the scale L Ra^(-1/4) of natural convection over a hot plate). The air speed of the fans at the bead is `machine.part_fan_air`. The machine profiles of the printer library set both for the families in `printers.cooling_families` (from the fans and the enclosure of each family; the air speeds are estimates from the size of the fans).
5. **Viscosity.** Each plastic has the law of its melt (`print_sim.Material`, from `filament.material`): PLA 3546 Pa s at 200 °C with Arrhenius 80.6 kJ/mol, and ABS 13 250 Pa s at 200 °C with WLF (both measured by Colón Quintana 2021); PETG 3844 Pa s at 220 °C (a patent), with the temperature law of PLA as an estimate. A type with no data gets the nearest plastic: ASA and HIPS get ABS, PET and PCTG get PETG, and others get PLA. Near the glass point the WLF law with the universal constants holds. A soft mass sets where it is when its viscosity passes 1e6 Pa s (PLA at about 98 °C, ABS at about 158 °C).
6. **Runs held at both ends.** The soft masses between two held masses (a solid mass, or the newest mass, which the nozzle holds) hang as a catenary of their arc length. The catenary follows the route in plan where the nozzle laid them. The route must be about straight (within half a bead of the line between the ends): nothing holds a turn, so a run with a turn swings and falls (7). The tension of a catenary is a times the weight for each mm, so the stress is rho g a. The hot plastic creeps under it at the rate stress / (3 viscosity). Near the taut limit the slack follows a closed form, so the step can be large. As the plastic cools, the creep stops.
7. **Runs held at one end, or none.** They swing and fall with position based dynamics. A run held at one end keeps its links by "follow the leader" from the held end, in one pass. A run that fell and is then held at both ends uses Gauss-Seidel passes and long-range attachments.
8. **Contact.** A soft mass that comes down onto the bed or solid plastic sets there. It rests on the highest plastic under its bead, so it does not fall through a gap between two beads.
9. **Failure.** A mass that sets more than 1.5 mm under its place failed (Yang et al. 2021 measured 1 to 1.5 mm of sag in the deck of a 35 mm bridge at the limit of a good print). The layers on it have nothing under them, so they fall onto it and fail too.
10. **Sleep.** A hanging run between two solid masses sleeps while its creep moves it less than 0.5 µm in a step, at the creep of its hottest mass: its masses stay where they are, as a body at rest in a rigid body engine. A change of the run wakes it. The step is 10 ms while no strand swings or falls (the hanging shape has a closed form), and 2 ms with substeps of 1 ms for the strands that fall.
11. **Time.** The time jumps over the times with no free soft mass. Most of a print has none.

## Numbers

A bridge of 20 mm between two posts, PLA at 210 °C, 15 mm/s:

| Case | Sag |
|---|---|
| Full fan | 0.66 mm |
| No fan | 2.09 mm |
| Full fan, 230 °C | 0.93 mm |
| Full fan, 5 mm span | 0.16 mm |

A 3DBenchy (585 778 masses), on one core: about 1.5 s, with 7 MB of memory more than the slice. On its side with no support: 2.2 s and 10 MB. Upside down with no support: 2.9 s and 8 MB.

## Calibration

`src/app/sim_calib.zig` slices test parts and checks the drop of the plastic against measured values: overhang fins of 30, 45, 60, and 80 degrees, bridges of 5, 20, 35, and 60 mm, and a slab 25 mm over air. The parts of `tools/calib/` print the same tests on a real printer, with a sheet for the measured values and the values that the simulation predicts.

| Test | Measured on real prints | Simulation |
|---|---|---|
| Overhang 45° | prints clean (the 45° rule) | 0.01 mm |
| Overhang 60° | keeps its shape to 65° | 0.42 mm |
| Overhang 80° | droops much more | fails |
| Bridge 5 mm | no visible sag | 0.13 mm |
| Bridge 20 mm | almost no visible sag (below 33 mm) | 0.73 mm |
| Bridge 35 mm | about 1 mm | 1.25 mm |
| Bridge 60 mm | loose strands (past 37 mm) | fails |
| Slab 25 mm over air | falls in strands | fails from its first layer |

## Limits

- A strand has no bending stiffness. A hot strand that hangs from one end hangs straight down. A set strand does not hold the hot strand after it to its direction, so the sag of a long bridge adds up along it: a 20 mm bridge sags more than on a real print.
- Soft masses do not touch each other. They touch only the bed and the solid plastic.
- The height field has one top for each cell. A strand that falls under an overhang rests on top of it.
- A mass that sets does not move again. A set strand does not bend later under the weight of the layers on it. A strand that the nozzle draws off an edge into air and that sets there is a rigid rod: later layers lie on it.
- The materials with data are PLA, ABS, and PETG. The heat capacity, the conductivity, and the temperature law of PETG are the values of PLA.
