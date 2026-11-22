# References and licenses

zslice is licensed under AGPL-3.0-or-later. See `LICENSE`. These pages list each source that zslice uses: each idea, each piece of data, and each piece of code that comes from another project.

Open the [reference explorer](explore.md) to filter the entries by kind, by source, and by the area of zslice, or to search them.

## The rule

Each idea, data, or code that zslice uses from another project gets an entry here. Credit each source. The entry says:

1. What zslice uses: an idea, a method, a setting and its meaning, data, a format, or code.
2. From where: the project or the paper, with a link, and a commit, a tag, or a version for a repository.
3. The license of the source.
4. Where it lives in zslice: the files, and the setting or the function where that helps.

Also name the source in the header comment of each zslice file that uses it, and point to the page of the entry. Before you copy or port code, check that its license is compatible with AGPL-3.0-or-later, keep its copyright notice in the file, and put its license text in `licenses/`. The full rules are in `AGENTS.md` and in [Contributing](../internals/contributing.md).

zslice has ports of the code of CuraEngine (see [Cura](cura.md)) and boost::polygon (see [Libraries and tools](libraries.md)). It copies no other code. The other sources gave ideas, methods, formats, or data. Each zslice file that uses a source names it in its header comment.

## The pages

| Page | What it has |
|---|---|
| [Libraries and tools](libraries.md) | The code in the binaries and its licenses, the libraries that the shells link, the projects of the same author, and the test tools. |
| [Cura and CuraEngine](cura.md) | The Arachne port, the Cura profile formats, the settings and the methods that come from Cura. |
| [OrcaSlicer](orcaslicer.md) | The settings and the test tools that come from OrcaSlicer. |
| [PrusaSlicer and Slic3r](prusaslicer.md) | The flow model, the paint format, the multi-material segmentation, and other ideas. |
| [Bambu Studio and Bambu Lab](bambu-studio.md) | The printer facts, the G-code templates, and the LAN mode. |
| [Slicer techniques](slicer-techniques.md) | The methods that many slicers share. |
| [Printer data](printer-data.md) | The printer library and the bed models. |
| [Firmware and G-code](klipper-marlin-firmware.md) | Klipper, Marlin, RepRapFirmware, grbl, and the G-code variables. |
| [Fonts](fonts.md) | Inter and the OpenType format. |
| [Papers and algorithms](papers-and-algorithms.md) | Geometry, sorting, and other general techniques. |
| [Physics and materials](physics-and-materials.md) | The print simulation, the bond, and the material data. |
| [Formats and protocols](formats-and-protocols.md) | File formats, network protocols, and printer APIs. |
| [Printables](printables.md) | The API of the list of files of a model, its terms, and the projects that showed its fields. |
| [Thingiverse](thingiverse.md) | The address of a thing, its ZIP file, and why zslice does not call its API. |

## The form of an entry

Each entry is a level 3 heading, a `ref` block with fields, and the text of the entry. The docs build reads the fields, and makes the explorer from them.

```
### Lightning infill

` ` `ref
kind: idea
source: Cura
license: AGPL-3.0
link: https://github.com/Ultimaker/Cura/releases/tag/4.12.0
version: Cura 4.12
files: src/lightning.zig
area: infill
summary: The idea of the pattern: branches only under the top surfaces.
` ` `
```

(Write the fence as three backticks with no spaces.)

The fields:

| Field | Value |
|---|---|
| `kind` | One of `idea`, `code`, `data`, `font`, `paper`, `format`, `tool`, `setting`. A `setting` is a setting of another slicer that zslice has with the same meaning. |
| `source` | The project, the company, or the authors. Separate more than one with commas. Use `General` for a general technique. |
| `license` | The license of the source, or the kind of the source (for example `Paper`). |
| `link` | The address of the source. |
| `version` | The commit, the tag, or the version that zslice read. |
| `files` | The files and folders of zslice that use the source, separated by commas. Each path must exist: the docs build checks it. |
| `area` | One of `slicing`, `walls`, `infill`, `support`, `gcode`, `printers`, `plate`, `physics`, `files`, `network`, `fonts`, `ui`, `build`. |
| `summary` | One sentence: what zslice uses, or how zslice uses it. |
| `texts` | The license texts in `licenses/`, if any. |

`kind`, `source`, `license`, `files`, `area`, and `summary` are necessary. `python3 -I docs/build.py` stops with an error for an entry with no such field, or with a path that does not exist.
