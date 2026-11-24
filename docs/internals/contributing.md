# Contributing

## Rules

Read `AGENTS.md` at the root of the repo. It has the rules for all contributors, people and agents:

- The goals of the project.
- Licenses and references: credit each source. Each idea, data, or code that you take from another project gets an entry in [the references](../references/README.md): what you took, from where (a link and a commit or a version), its license, and where it lives in zslice. Name the source in the header comment of the file too.
- The writing style for comments and docs.
- The checks before a commit.

## Set up

```sh
zig version          # must be 0.16.x
zig build test       # the unit tests
zig build -Doptimize=ReleaseFast
```

## Tests

There are three kinds of tests.

### Unit tests

Each source file has `test` blocks at the end. `zig build test` runs all of them, with the leak-checking allocator. A test that leaks memory fails.

A good test for geometry code checks a number that you can compute by hand, for example an area:

```zig
test "shrink a square" {
    var sq = try square(gpa, 10_000);        // 10 mm x 10 mm
    var r = try offset(gpa, sq, -1000, .{});  // in by 1 mm
    try testing.expectApproxEqAbs(@as(f64, 64.0), r.areaMm2(), 1e-6);  // 8 x 8
}
```

When you fix a bug, add a test that fails without the fix. Name the bug in a comment.

### The corpus

`tools/corpus.py` slices each STL file in a folder (in a git repo, only the tracked files) and reports the failures, the time, and the peak memory:

```sh
zig build -Doptimize=ReleaseFast
python3 -I tools/corpus.py zig-out/bin/zslice ../printdeck report.tsv
```

Run it before you finish a change to the geometry or slicing code. Each file must slice with status `ok`.

A change that must keep the G-code also compares the hash of the G-code of each corpus file. Make the table with the build before the change, and again with the build after it. `diff` must print nothing:

```sh
python3 -I tools/corpus_hash.py zig-out/bin/zslice ../printdeck hash-before.tsv 2
python3 -I tools/corpus_hash.py zig-out/bin/zslice ../printdeck hash-after.tsv 2
diff hash-before.tsv hash-after.tsv
```

### The slice verifier

`zig build verify` runs `zslice verify --quick` in a ReleaseFast build: the sweep of the settings of the demo part, and 3 seeds of 40 random edits. It fails if a slice with kept work differs from a full slice. The CI runs it after the tests. Run it after each change to a key, a memo, or a kept stream. See [The slice verifier](code-quality.md#the-slice-verifier).

### Look at the output

A test can pass while the output is wrong. Look at the layers:

```sh
zslice preview part.stl --layer 20 -o layer20.svg
rsvg-convert -w 900 layer20.svg -o layer20.png   # optional: a PNG
```

Check a bottom layer (all skin), a middle layer (walls and sparse infill), a layer just under a top surface (skin), and the top layer.

## Add a setting

1. Add a field with a default value to the correct struct in `src/settings.zig`: `Machine`, `Filament`, `Project`, or `EngineOptions`. Choose the struct by the owner of the value (see [The command line](../user/command-line.md#the-three-groups)).
2. Add a `///` doc comment that says what the setting does and its unit.
3. If the value has limits, check them in `Settings.resolve`.
4. If code uses a derived value, compute it once in `resolve` and add it to `Resolved`.
5. Use the value in the stage.
6. If the value can change per layer, read it from the settings of the layer, and add its name to `settings.layer_settings` (see [Settings for some layers](layer-settings.md)).
7. Run `python3 -I tools/settings_doc.py > docs/user/settings.md`.

`Settings.set`, the C API, the wasm API, and the command line get the new setting with no more code. They use comptime reflection on the struct. Supported field types: `f64`, `u32` (and other integers), `bool`, enums, and `[]const u8`.

## Add a feature type

A feature is a kind of path, for example a wall, infill, or ironing. To add one (for example `support`):

1. Add it to `Feature` in `src/settings.zig`.
2. Add its speed ratio to `Project` and to `Resolved.speed`.
3. Make its paths in `layer.plan`, and add them with `addOrdered` at the correct place in the print order. Ironing is a short example: see step 6 in `layer.zig`.
4. Give it a `;TYPE:` name in `gcode.typeName`. Use the CuraEngine name if one exists, so that G-code viewers know it.
5. Give it a color in `svg.color`.
6. Add a test in `layer.zig` that checks the new paths.

The compiler finds each `switch` on `Feature` that does not handle the new value.

## Add an infill pattern

1. Add the pattern name to `InfillPattern` in `src/settings.zig`, and describe it in the doc comment of `infill_pattern`.
2. Write the fill function in `src/infill.zig`, or in a new file for a large pattern. Input: the region (closed polygons, material on the left), the spacing, and the layer index. Output: a `geom.Paths` of open polylines.
3. Call it from the `switch (p.infill_pattern)` in `layer.plan`.
4. Add a test that fills a square and checks the total line length times the spacing against the area (see "diagonal lines cover the square").
5. Look at a preview.

Rules for a pattern:

- The lines of one layer should be on top of the lines of the layer below, or cross them. Compute the lines from a fixed grid in bed coordinates, and not from the bounds of the region.
- The output must be the same on each run and on each thread. Do not use a random seed that changes.

## Change the geometry code

`clip.zig` and `offset.zig` are the base of each stage. A bug there shows up as a missing wall or a filled hole in some layers of some parts.

- Keep the conventions in [Architecture](architecture.md#conventions).
- Use the exact integer functions for each decision. Use floating point only to make a new point.
- Add a test with the shape that failed. Real failures often come from thin features and curves with many short edges.
- Run the corpus.

## Commits

- One change for each commit.
- The subject says what changed, in under 72 characters.
- The body says why, if the reason is not clear from the subject.
