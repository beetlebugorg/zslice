# 00. The brief

Give this page to the agent with each part.

## The product

Build zslice: a slicer for FDM 3D printers, written from scratch in Zig 0.17. It shows the print as the plastic forms it, before you print. It runs in a browser on WebAssembly, and as a native app on Linux, macOS, and Windows. A command line tool and a C library come from the same core. The README and the docs name the web app and the three native apps side by side in their first lines.

zslice is an experimental slicer. It has three goals ([README](../README.md)):

- **Very fast slicing.** A change of a setting shows in the view at once, at 60 frames a second.
- **New ways to use a slicer.** The slice is the whole UI. A click on a line says why it prints as it does. Edits happen directly in the 3D view.
- **Feature ideas.** For example, a physical simulation of the plastic, fitted to measured test prints, so that the real sag shows before you print.

## The vision

The owner of zslice gave these aims. Use them to choose between two designs.

- **Dig into how a print prints.** Each line has its real values and the reasons for them.
- **Tweak with surgical precision.** Change one line, one body on some layers, one face, or one layer range.
- **Trust that it prints as shown.** The view shows the cooled bead, the sag, and the fall. Physics decides what the view shows.
- **60 frames a second.** The view and the slicing both keep up with a drag.
- **Instant start, and an exact session restore.** After a reload or a quit, the app comes back as it was: the plates, the camera, the pages, and the last frame.
- **Real-time feedback.** Each editing tool updates the view as you drag.

## The engineering goals

From [AGENTS.md](../AGENTS.md):

1. A clean API for embedding, in Zig and in C.
2. WebAssembly support.
3. A modern code base.
4. High performance.
5. Low memory use.
6. Advanced slicing features, for example ironing.
7. Code that teaches how a slicer works. Each module explains its algorithm in its header comment (`//!`).

## The architecture in one paragraph

One Zig core has all logic: the slicer (`src/`), the app core (`src/app.zig`, `src/app/`), and the 3D view (`src/render/`). Each platform has a native shell, and only the core is shared ([the app contract](../docs/app/README.md)). A shell draws native widgets, reads and writes files, and moves core events to its UI thread. The core does no file I/O and no network I/O. The shells are: web (JavaScript, WebGL2, a Web Worker), Linux (GTK 4 in C, Vulkan from the core), macOS (SwiftUI and AppKit, Metal), and Windows (WinUI 3 in C++/WinRT, Direct3D 12 from the core).

## Values

- **Privacy.** No analytics, no tracking, no cookies, no ads. The web app loads no file from other sites, and sends models, settings, and G-code to no server. It connects only where the user tells it to. See [PRIVACY.md](../PRIVACY.md).
- **Credit for every borrowed idea.** Each idea, algorithm, setting meaning, format, data set, or code from another source gets an entry in [docs/references/](../docs/references/README.md). The header comment of each source file names its references. `python3 -I docs/build.py` checks the fields and the paths of each entry.
- **Avoid active patents.** Do not use a method that an active patent covers. This rule comes from the owner. The repository has no page for it today. Note an ended patent in its reference entry, as `docs/references/papers-and-algorithms.md` does for marching cubes.
- **Design again.** zslice designs each feature of PrusaSlicer and Cura again. It does not copy their code, or always their method ([the roadmap](../ROADMAP.md)). A port, such as Arachne from CuraEngine, is a deliberate choice with its license kept.

## Licenses

- zslice is AGPL-3.0-or-later. CuraEngine, PrusaSlicer, Slic3r, OrcaSlicer, Bambu Studio, and SuperSlicer also use AGPL-3.0.
- Before you copy or port code, check that its license is compatible with AGPL-3.0-or-later. Keep its copyright notice.
- Put the license text of each dependency in a zslice binary or wasm file in `licenses/`. List it in `docs/references/libraries.md` under "Code in the binaries".
- The Zig standard library has ports from other projects (musl, Go, ARM optimized-routines). Read the header of a std file before the first call to it. Add its source to the references if it is new.
- The phone and watch apps of the owner (in another repository) are MIT. They must not link zslice, because zslice is AGPL. This rule comes from the owner. The zslice repository does not state it.

## Hard rules

1. **Exact G-code for unchanged settings.** A refactor, a speed-up, or a new feature that is off must give the same G-code, byte for byte. Check the corpus and the 3DBenchy before and after. A new feature with a switch gives the old G-code when the switch is off (for example `project.fast_offsets`).
2. **The same output for each thread count.** The work of each item depends only on its index and on data that does not change during the pass. A test in `engine.zig` checks this.
3. **Tests.** Run `zig build test` before each commit. After a change to geometry or slicing code, also run the corpus: `python3 -I tools/corpus.py zig-out/bin/zslice ../printdeck report.tsv`. Each file must slice with status `ok`.
4. **Docs.** Keep the three doc parts current: `docs/user/`, `docs/embedding/`, `docs/internals/`. After a change to `src/settings.zig`, run `python3 -I tools/settings_doc.py > docs/user/settings.md`. Each setting needs a `///` doc comment. A setting with the meaning of a Cura or OrcaSlicer setting gets a line in `tools/setting_coverage_cura.txt` or `tools/setting_coverage_orca.txt`.
5. **Measure.** Measure each speed change in wasm and native, on one thread and on all threads.
6. **No secrets in the repository.** Access codes, API keys, and signing keys stay in the files of the user. They never go into the source, the docs, or a log.
7. **Fresh confirmation to start a print.** A print starts only after a fresh click of the user, after the question "Is the bed clear?". Never start a print from a timer or a retry. A `zslice://` link opens a model and never starts a print.

## Writing

- Comments, docs, and commit messages use short, plain sentences. One idea per sentence. Active voice. Present tense. No em dashes.
- A commit subject is under 72 characters, in the imperative ("Keep the camera put when a slice comes back"). The body is wrapped at 72. It says what changed and why, and the one fact a reviewer needs.
- No attribution trailers and no session links in commits.
- UI labels: never cut a label with "…". A label with too little room wraps at the ends of words, or the text gets smaller.

## How to work

- Build in the order of the parts. Each part ends with acceptance checks.
- Put each decision in the core, so that each shell behaves the same.
- Test each UI change in the real app with its test hooks (`ZSLICE_*` variables, `window.zslice`), and look at a screenshot.
- When the owner corrects a behavior, write the correction in the code comment, the docs, and the commit body. The lessons in these parts came from such corrections.
- Each push and each merge to main includes the update of the `prompt/` folder for its commits ([UPDATING.md](UPDATING.md)). This rule comes from the owner (2026-11-22).
