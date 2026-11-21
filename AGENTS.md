# Agent instructions

## Goals

zslice is a slicer written from scratch in Zig. The goals are:

1. A clean API for embedding, in Zig and in C.
2. WebAssembly support.
3. A modern code base.
4. High performance.
5. Low memory use.
6. Advanced slicing features, for example ironing.
7. Code that teaches how a slicer works. Each module explains its algorithm in its header comment.

## The app

The app has one core (`src/app.zig`, `include/zslice-app.h`) and one native shell for each platform (`linux/` GTK4 first). Read `docs/app/README.md` before you change a shell. App logic goes in the core. A shell only draws widgets, reads and writes files, and moves events to its UI thread.

## Licenses and references

zslice is licensed under AGPL-3.0-or-later. The main slicer engines (CuraEngine, PrusaSlicer, Slic3r, OrcaSlicer, Bambu Studio, SuperSlicer) use AGPL-3.0.

Follow these rules for all work:

1. Record each reference. A reference is any source that the work uses: an idea, an algorithm, a setting and its meaning, a paper, a file format, a convention, data, another project, or code. Credit each source: each idea, data, or code taken from another project gets an entry in `docs/references/`, on the page of its source or area. The entry says what zslice uses, from where (a link, and a commit, a tag, or a version), its license, and where it lives in zslice. Read `docs/references/README.md` for the form of an entry. `python3 -I docs/build.py` checks the fields and the paths.
2. Name the reference in the header comment of each source file that uses it. Point to its page in `docs/references/`.
3. Obey the license of each dependency and each source that zslice copies or ports. Before you copy or port code, check that its license is compatible with AGPL-3.0-or-later. Keep its copyright notice in the file.
4. Put the license text of each dependency whose code goes into a zslice binary or wasm file in `licenses/`. List it in `docs/references/libraries.md` under "Code in the binaries".
5. Do not add a dependency or copy code with an unknown license, or with a license that is incompatible with AGPL-3.0. Ask first.
6. The Zig standard library has ports of code from other projects. The file header of each port names its source. Before you call a std function that is new to zslice, read the header of its file. If it names a source that is not in `docs/references/`, add the source and its license text before the call. Known ports in zslice binaries: musl (math), Go (`std.fmt.parseFloat`, `std.math.pow`), and ARM optimized-routines (`std.math.acos`).

## Writing

Write comments, docs, and commit messages in short, plain sentences. Use one idea per sentence, active voice, and present tense. Do not use em dashes.

## Documentation

The docs have three parts. Keep each part current with the code.

- `docs/user/`: for people who slice with zslice.
- `docs/embedding/`: for developers who use the library.
- `docs/internals/`: for developers who change or extend the library.

After a change to `src/settings.zig`, run `python3 -I tools/settings_doc.py > docs/user/settings.md`. Each setting needs a `///` doc comment.

Each source file starts with a `//!` comment that explains its algorithm in plain words.

## Checks

Run `zig build test` before each commit. The tests must pass.

Before a change to geometry or slicing code is done, also run the corpus: `python3 -I tools/corpus.py zig-out/bin/zslice ../printdeck report.tsv`. Each file must slice with status `ok`.
