# Comparison with CuraEngine

`tools/compare_cura.py` slices a corpus of STL files with zslice and
with CuraEngine. It compares the results. Use it to find the files where
zslice fails, is slow, uses much memory, or gives a print that is far
from the Cura print.

CuraEngine is a test oracle. The script runs the CuraEngine program. No
Cura code is in zslice. See `REFERENCES.md`.

## Run it

```sh
zig build -Doptimize=ReleaseFast
python3 -I tools/compare_cura.py run zig-out/bin/zslice ~/cura-compare
python3 -I tools/compare_cura.py summary ~/cura-compare
python3 -I tools/compare_cura.py check model.stl
```

Options of `run`:

- `--root DIR`: the folder to search for STL files. The default is
  `the corpus folder`.
- `--jobs N`: the number of files to slice at the same time. The default
  is 3. Each slicer runs with one thread at nice level 10, so the
  desktop stays responsive.
- `--timeout S`: the time limit of one slice, in seconds. The default is
  120.
- `--limit N`: slice only N files. Use it for a quick test.
- `--rescan`: make a new list of the files.

The script needs CuraEngine in `/opt/ultimaker-cura` (the Cura AppImage,
extracted) and the TAZ Workhorse SE definitions in
`the corpus folder/printdeck/profiles/taz-workhorse-se`.

## The corpus

The script finds each `.stl` file under the root folder. It skips
`.git`, `node_modules`, `.zig-cache`, `zig-out`, and the `zslice-*`
worktrees. Many files are copies, in worktrees, build folders, and
caches. The script keeps one path for each sha1 of the content. It
prefers a path that git tracks in a main checkout. The list goes in
`<out>/corpus.tsv`, and the next run uses it again.

## The settings

The two slicers get the same main settings:

- The TAZ Workhorse SE: a 0.5 mm nozzle and 2.85 mm filament. zslice
  gets the machine profile from `zslice import cura`.
- A bed of 2000 x 2000 x 2000 mm, so that each part fits. The part goes
  to the center of the bed.
- Layer height 0.2 mm, first layer 0.3 mm.
- 2 walls, 0.8 mm top (4 layers), 0.6 mm bottom (3 layers).
- 20 % grid infill. No support. A skirt of 1 loop, 3 mm from the part.
- The same speeds: outer wall 30 mm/s, inner wall 48 mm/s, skin 42 mm/s,
  infill 60 mm/s, first layer 18 mm/s, travel 150 mm/s.
- A minimum layer time of 6 s.
- Each slicer process runs at nice level 10, with an address space limit
  of 3 GB.
- One thread for each slicer.

CuraEngine on the command line does not compute the settings that have a
`value` expression in the definitions. It uses the `default_value`. For
example, `initial_bottom_layers` is 6 and `infill_sparse_thickness` is
0.1 mm. So the script gives each derived setting that changes the print
with the value that Cura computes. See `CURA_SETTINGS` in the script.

Both slicers get a very high acceleration and corner speed, so that the
time estimates compare without the two acceleration models.

Some differences stay, because the two slicers do different things:

- Cura prints a solid infill line pattern under each skin
  (`skin_support`) and one concentric line around each skin area
  (`skin_outline_count`).
- Cura expands the skin areas into the infill
  (`expand_skins_expand_distance`).
- Cura travels inside the part (combing), so its travel moves are
  longer.

## The results

`<out>/results.csv` has one row for each unique file. The columns with
`z_` are for zslice, the columns with `c_` are for CuraEngine:

- `status`: ok, error (exit code 1 to 127), crash (a signal), timeout,
  or oom (out of memory at the 3 GB cap).
- `wall_s` and `cpu_s`: the wall time and the CPU time of the slice.
  Other programs on the computer change the wall time.
- `peak_mb`: the peak resident memory of the slicer process. The value
  includes the Python process before the `exec`, so 8 to 12 MB is the
  lowest value.
- `layers`, `filament_m`, `time_s`: from the G-code header.
- `fil_*`: the filament of each `;TYPE:` in the G-code, in m. Only moves
  in X or Y with extrusion count. Retracts and the start G-code do not
  count.
- `error`: the last error lines of the slicer.

The script writes each row when the file is done. A new run skips the
files that are in `results.csv` already. At the end, the script writes
`<out>/summary.md`.

`check` prints the facts of a mesh: the triangle count, the size, the
degenerate triangles, the open edges, the non-manifold edges, the edges
of flipped triangles, and the count of connected parts.

## Results of 2026-11-16

The corpus was `the corpus folder`: 10,263 STL files, 3,508 unique files.
zslice was at commit 779ccdd. CuraEngine was version 5.14.0.

The run had these conditions:

- About the first 1,900 files ran with 6 jobs and no nice level. The
  next files ran with 3 jobs at nice level 10. Other programs also used
  the CPU. So the wall times are noisy. The CPU times are better for a
  comparison.
- The last 4 files ran with the 3 GB memory cap. Before the cap, some
  zslice slices used more than 3 GB and have the status ok.
- The Cura skirt had 3 layers (the Cura default). The script now sets
  `skirt_height=1`.

| | ok | error | timeout | oom | CPU s (sum) | wall s (median) | peak MB (median) | peak MB (max) | over 1 GB |
|---|---|---|---|---|---|---|---|---|---|
| zslice | 3,500 | 3 | 2 | 3 | 2,626 | 0.21 | 28 | 5,848 | 36 files |
| CuraEngine | 3,500 | 2 | 6 | 0 | 5,823 | 0.62 | 28 | 543 | 0 files |

On the 3,497 files where both slicers are ok, zslice is faster on 3,221
files. The median ratio zslice / Cura is 1.000 for the layer count,
0.874 for the filament, and 0.882 for the time estimate.

Filament of each feature type, sum over these files:

| type | zslice (m) | CuraEngine (m) | ratio |
|---|---|---|---|
| WALL-OUTER | 3,491 | 3,479 | 1.003 |
| WALL-INNER | 2,832 | 2,946 | 0.961 |
| SKIN | 1,971 | 2,446 | 0.806 |
| FILL | 17,023 | 18,807 | 0.905 |
| SKIRT | 15 | 34 | 0.454 |

The walls agree. The skin and infill differences come mostly from the
Cura features in "The settings" (skin support, skin outline, skin
expansion). The skirt difference comes from the 3-layer Cura skirt.

### Problems in zslice

1. Memory grows with the layer count. 36 files use more than 1 GB in
   zslice. The largest CuraEngine peak is 543 MB. For example,
   `a part of the corpus` is a closed pole of 628
   triangles, 590 mm tall. It uses 1,822 MB at 0.2 mm layers (2,950
   layers) and 917 MB at 0.4 mm layers (1,475 layers). That is about 0.6
   MB for each layer of a 18 mm wide part. The time also grows faster
   than the layer count: 17.2 s against 5.9 s. The likely cause is that
   zslice keeps the data of all layers until the end of the slice.
2. Out of memory at 3 GB, or more than 120 s:
   - `a part of the corpus` (647,555
     triangles): oom. In a run without the cap, it had 8.7 GB resident
     before the run was stopped.
   - `a part of the corpus` (1,637,156 triangles):
     oom after 4 s. CuraEngine: ok in 12.6 s, 251 MB.
   - `a part of the corpus` (523,748 triangles): oom
     after 2.5 s.
   - `a part of the corpus` and
     `a part of the corpus` (74,634 and
     78,990 triangles): timeout at 7.8 GB and 6.7 GB. The y_bed_01 mesh
     has 55 parts, 256 open edges, 258 non-manifold edges, and 54
     degenerate triangles. CuraEngine also has a timeout on these.
   - `a part of the corpus` (74,634
     triangles, the same assembly): ok, but 69 s and 5.8 GB.
3. Open meshes are slow.
   `a part of the corpus`
   has 2,636 triangles and 2,386 open edges. zslice needs 45 s and 3.4
   GB. CuraEngine needs 17 s and 271 MB.
4. Non-manifold and multi-part meshes are slow.
   `a part of the corpus`
   (38,800 triangles, 38 parts, 3,192 non-manifold edges) needs 2.5 s in
   zslice and 0.14 s in CuraEngine.
   `a part of the corpus` (5,124 triangles,
   50 closed parts on 438 x 542 mm) needs 10.5 s in zslice and 1.1 s in
   CuraEngine.
5. A second wall in a thin part is slow.
   `a part of the corpus` has 1,000
   triangles: 10 cables 1.5 mm wide, 29 layers. zslice needs 4 to 7 s
   and 674 MB. With `project.wall_count=1` it needs 0.5 s. With
   `project.wall_count=0` it needs 16 ms. The infill and the skin are
   not the cause. The likely cause is the inset of a loop that collapses
   (`src/offset.zig`).
6. zslice prints no lines for a part that is thinner than a line. For
   example, `a part of the corpus` is a plate
   0.23 mm thick, tilted 15 degrees. CuraEngine prints one thin outer
   wall on each of the 801 layers (1.08 m). zslice prints only the skirt
   (0.006 m). 66 files have less than half of the Cura filament, and
   most are labels, plates, and sheets of this kind.
7. Empty layers at the bottom. In
   `a part of the corpus` the first 76 layers (15
   mm) have no extrusion in zslice, so the print starts in the air.
   CuraEngine removes empty first layers (`remove_empty_first_layers`)
   and has 407 layers against 483.
8. One extra layer at the top. zslice has one more layer than Cura on
   303 files, and never fewer. The likely cause is a top face at the z
   of a cut plane. For example,
   `a part of the corpus` is 0.4 mm tall. The middle
   of layer 2 is at z = 0.4 mm. zslice has 2 layers and Cura has 1.
9. A part that is lower than the first cut plane gives the error
   `EmptyMesh`. For example,
   `a part of the corpus` is 0.1 mm tall.
   CuraEngine writes a file with 0 layers.

The CuraEngine failures that zslice slices: one crash
(`a part of the corpus`, in the support step) and
timeouts on the large assemblies.
