# Calibration prints for the print simulation

These parts measure how the plastic sags and droops on a real printer. The measured values go into `sheet.csv`, next to the values that the print simulation (`src/print_sim.zig`) predicts. Then the physics of the simulation is fitted to the data.

## The parts

The parts are in `parts/`. `gen.py` makes them; each number is raised text on the part.

| File | What it is | What it measures |
|---|---|---|
| `overhang.stl` | A comb of 11 fins on a back wall. The underside of each fin leans out from vertical at 30, 35, ... 80 degrees. The fin tip is 2.0 mm thick. | Droop and the rough underside of an overhang. |
| `bridges.stl` | Six bridges, spans 10, 20, 30, 40, 60, and 80 mm. The deck is 1.6 mm thick, on piers 8 mm high. | Bridge sag, and loose strands. |
| `ledges.stl` | Three posts, each with a slab of 1.6 mm that sticks out 5, 10, or 20 mm over air. | Where a slab over air turns into strands. |

About 1 h 45 min and 20 g of PLA in all (overhang 45 min, bridges 48 min, ledges 12 min).

## Print them

- Printer: LulzBot TAZ Workhorse SE, 0.5 mm nozzle.
- Plastic: PLA.
- Profile: PLA 0.20 Standard (0.2 mm layers).
- Support: **off**. Brim: off (the skirt is fine).
- Fan: 100 % after the first layers, and 100 % on bridges.
- Speeds: as in the profile (outer wall 25 mm/s, inner wall 40, skin 35, infill 55, bridge walls 20).

Print `overhang.stl` and `bridges.stl` together on one plate. Print `ledges.stl` alone, after them: if its slabs fall, the strands cannot get caught on the other parts. Write down the slicer, the nozzle temperature, and the room temperature.

## Measure them

Fill in the `measured` column of `sheet.csv`. Take a photo of the underside of each part, from the side, with a ruler in the photo.

- **Overhang, tip thickness.** Put the calipers on the end of each fin, from the top to the lowest point of the underside. The model is 2.0 mm. A droop makes it thicker.
- **Overhang, underside.** Look at the underside of each fin and give it a grade: 0 smooth, 1 a little rough, 2 rough or drooped, 3 loose strands. The first angle with a grade of 1 or more is the most important value.
- **Bridge, deck thickness at the middle.** Put the calipers across the deck at the middle of the span, from the top to the lowest point under it. The model is 1.6 mm. The sag is the thickness less 1.6 mm. A straight edge on the top shows if the top is flat.
- **Bridge, loose strands.** Look under the deck: do strands hang loose from it?
- **Ledge, tip thickness.** Put the calipers on the slab, 1 mm from its end. The model is 1.6 mm.
- **Ledge, height of the tip bottom.** Put the depth rod of the calipers on the bed (or the table) and measure up to the bottom of the slab at its end. The model is 8.0 mm.
- **Ledge, falls in strands.** Is the slab a slab, or a mess of strands?

If a value cannot be measured (the part fell in strands), write `strands` and add a note.

## Make the predictions

The predicted column comes from the simulation. To make it again after a change of the physics:

```sh
zig build -Doptimize=ReleaseFast
python3 -I tools/calib/gen.py tools/calib/parts
P=path/to/profiles   # zslice import cura <the TAZ Cura stack> -o $P
for f in overhang bridges ledges; do
  zig-out/bin/zslice bench tools/calib/parts/$f.stl \
    -m $P/machine/lulzbot-taz-workhorse-se.toml -f $P/filament/roll-1.toml \
    -p $P/project/pla-0.20-standard.toml \
    --only sim --runs 1 -o tools/calib/parts/$f.masses.csv
done
python3 -I tools/calib/predict.py tools/calib/parts --sheet tools/calib/sheet.csv \
  --label "sim $(git rev-parse --short HEAD)"
```

`predict.py` writes the predicted column of `sheet.csv` again. It keeps the measured column and the notes.
