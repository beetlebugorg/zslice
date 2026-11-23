# A prompt that could build zslice

Describes: main at commit `d38ca557` ("Count every tool that a USB print heats in the GTK app"), 2026-11-23.

## Read this first

This folder is **not** the prompt that built zslice.

zslice came from many sessions of conversation between its author and AI coding agents. The work had many corrections, many test prints, and many changes of plan. No single prompt exists for it.

This folder is an AI's best guess at a prompt that **could** build an app like zslice today. An AI wrote it from the code, the docs, and the git history of the repository. It tells a coding agent what to build, in what order, which numbers and rules matter, and which lessons cost the most to learn. It can be wrong. Where it and the code differ, the code is correct.

## The files

| File | What it has |
|---|---|
| `README.md` | This page. |
| `00-brief.md` | The product on one page: the goals, the values, the licenses, and the hard rules. |
| `01-core-geometry-and-pipeline.md` to `16-performance.md` | The parts. Each part is one stage of the build, as a prompt for one session. |
| `CHANGELOG.md` | One line for each update of this folder. |
| `UPDATING.md` | How to keep this folder current. |

The parts, in build order:

1. `01-core-geometry-and-pipeline.md`: integer geometry, booleans, offsets, mesh load, slicing, the engine.
2. `02-settings-profiles-printers.md`: the settings, the TOML profiles, the Cura import, the printer library.
3. `03-gcode-and-flavors.md`: the G-code emitter, the firmware flavors, the start and end G-code, signing.
4. `04-print-features.md`: walls, skin, infill, support, bridges, seams, Arachne, and the newer features.
5. `05-multi-material.md`: filaments, paint, labels, prime towers, and the flush.
6. `06-physics.md`: parts that fall and settle, the bond to the bed, and the print as it forms.
7. `07-app-core-and-c-api.md`: the app core, the plate set, the undo list, and the C API.
8. `08-view.md`: the 3D view: beads, light levels, picks, the camera, plates, signs, and decals.
9. `09-web-app.md`: the web app on WebAssembly and WebGL2.
10. `10-linux-app.md`: the GTK 4 and Vulkan app.
11. `11-mac-app.md`: the SwiftUI and Metal app.
12. `12-windows-app.md`: the WinUI 3 and Direct3D 12 app.
13. `13-printers-and-sending.md`: Printdeck, OctoPrint, Moonraker, Bambu Lab LAN, the farm.
14. `14-sessions-and-projects.md`: the session restore, project files, and printdeck.yml projects.
15. `15-docs-ci-release.md`: the docs site, the references, CI, releases, and the Homebrew tap.
16. `16-performance.md`: the speed work and its numbers.

The order follows the dependencies. The core comes first. The app core and the view come before the shells. The shells come before the printer links, because each shell owns its network code. Part 16 lists work that also happens during the earlier parts: read it before part 1, and apply it at the end.

## How the parts use the docs

The repository docs already describe most behavior in detail. A part links to them, and does not copy them. A part adds only what the docs leave out:

- the build order and the scope of the stage;
- the numbers and the rules that a rebuild must match;
- the decisions that came from corrections (the "Lessons" section of each part);
- the acceptance checks.

Some docs are older than the code in places. A part names each such place that it found. The code, `docs/user/keys.md`, and `docs/user/settings.md` are the most current.

The main links:

- [The settings reference](../docs/user/settings.md): each setting, its unit, and its default.
- [The user guide](../docs/user/): what each feature does for a user.
- [The internals](../docs/internals/): the architecture, the algorithms, and each shell.
- [The references](../docs/references/): each borrowed idea, format, and library, with its license.
- [The app contract](../docs/app/README.md): the rule of the core and the shells.
- [The roadmap](../ROADMAP.md): what is done and what is open.

## How to use it

1. Give the whole folder, and the docs it links to, to a coding agent.
2. Start a new session for each part.
3. Give the agent `00-brief.md` and one part, in order.
4. Do not start the next part until the acceptance checks of the part pass.
5. Keep the lessons of each part. Each lesson is a fault that happened once.

## How it stays current

The folder describes one commit. The commit and the date are at the top of this page. Each push and each merge to main includes the update of this folder for its commits. The update follows the steps in `UPDATING.md`, and adds a line to `CHANGELOG.md`.
