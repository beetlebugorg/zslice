# zslice

<img width="720" src="docs/img/hero.webp" alt="The zslice web app: a 3DBenchy, sliced, in the colors of its features">

zslice is a slicer for FDM 3D printers, written from scratch in Zig. It shows the print as the plastic forms it, before you print. It runs in your browser: **[open zslice.beetlebug.org](https://zslice.beetlebug.org/)**. No install is necessary, and your files stay on your computer.

> **zslice is an experimental slicer.** It has three goals:
> - **Very fast slicing:** a change of a setting shows in the view at once, at 60 frames a second.
> - **New ways to use a slicer:** trials of new UI and UX models, for example the slice as the whole UI, a click on a line to see why it prints as it does, and direct edits in the 3D view.
> - **Feature ideas:** for example a physical simulation of the plastic, so that the real sag of the filament shows before you print, fitted to measured test prints.
>
> Expect changes and rough edges. Check each print in the view before you send it to a printer.

## The best of it

### Speed

<img align="right" width="360" src="docs/img/line-card.webp" alt="A click on a line of the 3DBenchy: the card of the line, with its speed, flow, and the settings that change it">

The view runs at 60 frames a second, and a slice keeps up with your edits. On a 3DBenchy (8 cores):

- A full slice: about 0.3 s.
- A change of a speed, the fan, a temperature, or the flow: about 15 ms. The paths stay; only the G-code is made again.
- A change of the infill: about 30 ms. A change of the walls: about 0.2 s.
- A drag of a part, a tree branch, or a setting slider shows the result as you move.

zslice keeps the work of the last slice, and makes again only what a change touches. A new change stops a slice that runs in under 15 ms.

<br clear="right">

### The print as it forms

<img align="left" width="360" src="docs/img/sim-forms.webp" alt="A bridge 80 mm long prints and sags. Then a slab prints over the air on each side of a post, and its plastic falls in strands">

zslice simulates the plastic as it leaves the nozzle. It cools with the fan, and it sags or falls where no plastic holds it. A bridge sags. A slab over the air falls in strands, and the next layers print on them. The physics is fitted to measured test prints, and it runs after each slice.

<br clear="left">

### Parts with real physics

<img align="right" width="360" src="docs/img/fall.webp" alt="A board stands on its thin edge. A turn tips it, and it falls over onto its wide face">

A part that cannot stand falls over onto a face, as on a real bed. A brim holds a tall part up. With the Grab tool, pick a part up and move it. Let go, and it rests flat.

<br clear="right">

### A support editor

<img align="left" width="360" src="docs/img/support-tree.webp" alt="Tree support under a shelf, with the nodes of the trees as dots to drag">

Click an overhang to put support under it. Drag the dots of tree support to move the branches. Change a support from grid to tree or a pad with one click. zslice keeps each branch within the rules.

<br clear="left">

### Colors and two nozzles

<img align="right" width="360" src="docs/img/colors.webp" alt="A 3DBenchy in grey with its support in red: the support prints with a filament of its own">

Give a part, some layers, or a painted face a filament of its own. Print the support in its own filament, so it breaks away. Take the filaments that a printer has loaded with one click. On a printer with two nozzles, such as the Bambu Lab X2D, each filament has its nozzle. See [Print in colors](docs/user/filaments.md).

<br clear="right">

All features: [The best features](docs/user/features.md).

## Start

- **In your browser:** open [zslice.beetlebug.org](https://zslice.beetlebug.org/), and read [Your first print](docs/user/getting-started.md).
- **From the source:** zslice needs Zig 0.16.

```sh
zig build test                          # run the tests
zig build -Doptimize=ReleaseFast        # the command line tool: zig-out/bin/zslice
zig build web                           # the web app: zig-out/web/app
zslice slice part.stl -o part.gcode     # slice a part
```

The Linux app (GTK 4) and the macOS app (SwiftUI and Metal) are in `linux/` and `macos/`. See [Web, Linux, and Mac](docs/user/apps.md).

## Links

- [The documentation](https://zslice.beetlebug.org/docs.html): the guide, the settings, and the internals.
- [Embedding](docs/embedding/overview.md): the library from Zig, C, and JavaScript.
- [How a slicer works](docs/internals/how-slicing-works.md), [Architecture](docs/internals/architecture.md), and [Contributing](docs/internals/contributing.md).
- [The roadmap](ROADMAP.md), and [Privacy](PRIVACY.md): no analytics, no cookies.

## License

AGPL-3.0-or-later. See `LICENSE`. The sources that zslice uses, and the licenses of the code in its binaries, are in `REFERENCES.md`.

The pictures show a slice of [3DBenchy](https://www.3dbenchy.com/) by Creative Tools, licensed under CC BY-ND 4.0. The model is not in this repository.
