# zslice and other slicers

zslice is a new slicer, written from scratch. Cura, PrusaSlicer, OrcaSlicer, and Bambu Studio are mature slicers with many years of work and large teams. This page says what zslice does that they do not, what they have that zslice does not have yet, and how the main features compare.

The other slicers change with each release. If a line here is out of date, open an issue.

## What makes zslice different

- **Click a line, see why.** Click any line of the preview. zslice tells you what the line is, its planned speed and its real speed after acceleration and cooling, its flow, and the settings that change it, with the reason for each number ("the layer is short, so it slows down to cool"). The other slicers show colors for speed or flow; they do not explain a line.
- **Fast enough to slice while you drag.** A 3DBenchy slices in about a third of a second. A change of a setting slices only what the change needs, so the preview updates while you drag a slider.
- **In your browser, with your files on your computer.** The web app at [zslice.beetlebug.org](https://zslice.beetlebug.org/) is the same core, compiled to WebAssembly. It slices in the browser: no install, no account, and no upload. See [Privacy](../../PRIVACY.md).
- **Find the gaps.** zslice shows the areas that should be solid and that no line covers, and for each gap the settings that can close it, with the value to try.
- **A check before you print.** Overhangs with no support, bridges and their span, islands that start in the air, lines over the flow of the hot end, layers too short to cool, and layers with many retractions, each in plain words with the setting to change.
- **A history of changes.** A list of each change in words. Click a change to see the print as it was, double-click to edit it there, or undo one change and keep the later ones.
- **Measure the print.** A measure tape on the sliced lines that snaps to the ends of the lines and to the centers of holes, and the length and the radius of a selected line.
- **Retractless top and bottom skin.** The pieces of the skin join along the walls into few paths, so the nozzle travels and retracts less over the top surfaces.
- **A library first.** The core is a library with a C API and a WebAssembly build. The GTK app and the web app are thin shells over it, so other apps can embed the slicer.
- **Code that teaches.** Each module explains its algorithm in its header comment, so the code is also a book about how a slicer works.

## What zslice does not have yet

- Adaptive layer height. zslice has a layer height for a range of layers.
- Painted supports and seams. zslice paints filaments on the model.
- Arc fitting (G2 and G3), and calibration prints (flow, pressure advance, temperature).
- OBJ and STEP files. A cut of a part is only in the macOS app.
- Resin (SLA) printers.
- Plugins, and a cloud service for the printers of a team.

See the [roadmap](../../ROADMAP.md) for the plan.

## The main features

"Yes" means that the slicer has the feature in its main release. "Some" means a part of it, or a plugin.

| Feature | zslice | Cura | PrusaSlicer | OrcaSlicer | Bambu Studio |
|---|---|---|---|---|---|
| Explains each line of the preview (real speed, why) | Yes | No | No | No | No |
| Slices again while a slider moves | Yes | No | No | No | No |
| Runs in a web browser, files stay local | Yes | No | No | No | No |
| Gaps view with settings that close each gap | Yes | No | No | No | No |
| History of changes in words | Yes | No | No | No | No |
| Embeddable library with a C API | Yes | Some (CuraEngine program) | No | No | No |
| Variable line width walls (Arachne) | Yes | Yes | Yes | Yes | Yes |
| Tree support | Yes | Yes | Yes | Yes | Yes |
| Support blockers and enforcers | Yes (marks) | Yes | Yes (painted) | Yes (painted) | Yes (painted) |
| Bridges detected and printed as bridges | Yes | Yes | Yes | Yes | Yes |
| Ironing | Yes | Yes | Yes | Yes | Yes |
| Settings for each part, modifier volumes | Yes | Yes | Yes | Yes | Yes |
| Settings for some layers | Yes | Some | Yes | Yes | Yes |
| Automatic orientation and arrangement | Yes | Some | Yes | Yes | Yes |
| Printer library with bed models | Yes | Yes | Yes | Yes | Bambu printers |
| Send to printer (OctoPrint, Moonraker, own) | Yes | Some | Yes | Yes | Bambu printers |
| Measure tool | On the sliced lines | No | On the model | On the model | On the model |
| Multi-material and color | Yes (paint, labels, two nozzles) | Yes | Yes | Yes | Yes |
| Variable layer height | Some (for a range of layers) | Yes (adaptive) | Yes | Yes | Yes |
| Arc fitting | No | Some | Yes | Yes | Yes |
| Calibration prints | No | Some | Some | Yes | Yes |
| Resin printers | No | No | Yes | No | No |
| License | AGPL-3.0 | LGPL-3.0 | AGPL-3.0 | AGPL-3.0 | AGPL-3.0 |

## Testing against CuraEngine

`tools/compare_cura.py` slices a folder of STL files with zslice and with CuraEngine, with the same main settings, and compares the results: failures, time, memory, and the print time and the plastic of each part. CuraEngine is a test oracle (see [Libraries and tools](../references/libraries.md#test-tools)).

```sh
zig build -Doptimize=ReleaseFast
python3 -I tools/compare_cura.py run zig-out/bin/zslice <out folder> --root <folder of STL files>
python3 -I tools/compare_cura.py summary <out folder>
python3 -I tools/compare_cura.py check model.stl
python3 -I tools/compare_cura.py walls zig-out/bin/zslice model.stl <out folder>
```

`walls` compares the walls of one model: the wall paths and volume of each slicer, and the line widths of the Arachne walls. The script needs CuraEngine (the Cura AppImage, extracted) and a Cura printer definition; see the header of the script. Use it to find the parts where zslice fails, is slow, uses much memory, or gives a print far from the Cura print.

## Testing support

`tools/support_check.py` checks the support of a sliced part, and compares the support of zslice, CuraEngine, and OrcaSlicer on the same parts.

```sh
python3 -I tools/support_check.py parts zig-out/scratch/parts
python3 -I tools/support_check.py check model.stl model.gcode --png model.png
python3 -I tools/support_check.py review zig-out/support-review zig-out/scratch/parts --zslice new=zig-out/bin/zslice --cura --orca
```

The check cuts the mesh at each layer and draws the support lines of the G-code into a grid of 0.1 mm cells. An overhang cell is a cell under a face of the mesh that looks down and leans more than 50 degrees from vertical. The check reports the overhang area with no support line within 1.5 mm in the 3 layers under it (unsupported), the support lines with nothing under them (floating), and the support volume. `review` slices each part with grid and tree support, and writes a picture of each slice (front, side, and top view) and an `index.html` with a table. OrcaSlicer needs the profiles `machine.json`, `process.json`, and `filament.json` in `<out folder>/orca`; see the header of the script.
