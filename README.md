# zslice

![The zslice web app: a 3DBenchy, sliced, in the colors of its features](docs/img/hero.webp)

zslice is a slicer for FDM 3D printers, written from scratch in Zig. It shows the print as the plastic forms it, before you print. It runs in your browser: **[open zslice.beetlebug.org](https://zslice.beetlebug.org/)**. No install is necessary, and your files stay on your computer.

## The best of it

### The print as it forms

![A bridge 80 mm long prints and sags. Then a slab prints over the air on each side of a post, and its plastic falls in strands](docs/img/sim-forms.webp)

zslice simulates the plastic as it leaves the nozzle. It cools with the fan, and it sags or falls where no plastic holds it. A bridge sags. A slab over the air falls in strands, and the next layers print on them.

### Parts with real physics

![A board stands on its thin edge. A turn tips it, and it falls over onto its wide face](docs/img/fall.webp)

A part that cannot stand falls over onto a face, as on a real bed. With the Grab tool, pick a part up and move it. Let go, and it rests flat.

### A support editor

![Tree support under a shelf, with the nodes of the trees as dots to drag](docs/img/support-tree.webp)

Click an overhang to put support under it. Drag the dots of tree support to move the branches. zslice keeps each branch within the rules.

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
