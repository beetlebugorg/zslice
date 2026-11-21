# Keep the prompt folder current

Update this folder when features land on main. Do one update for a batch of merges.

## Steps

1. Read the commit at the top of `README.md` ("Describes: main at commit ...").
2. Fetch main, and list the commits since that commit:

   ```sh
   git fetch origin
   git log --reverse --format='%h %s' <commit>..origin/main
   ```

3. For each commit, find the parts that it touches. Use the table below. Read the body of each commit whose subject starts with "Fix", "Keep", "Do not", "Never", "Stop", "Refuse", or has "only": these are corrections, and they become lessons.
4. Read the changed docs and module headers (`git diff --stat <commit>..origin/main -- docs src include`). Link to a doc when it states the behavior. Write in a part only what the docs leave out: the order, the numbers to match, the lessons, and the acceptance checks.
5. Update each part that the commits touch:
   - Add a new feature to the "Build" list of its part.
   - Add a new number or rule to "Numbers and rules that matter".
   - Add a correction to "Lessons", with the fault and the fix in one or two sentences.
   - Add or change an acceptance check.
   - Remove a statement that the code no longer supports.
6. Add a new part only for a new area of the app. Give it the next number, and add it to the list in `README.md`.
7. Change the commit and the date at the top of `README.md` to the last commit of main that you read.
8. Add one line to `CHANGELOG.md`: the date, the main commit, and the parts that changed.
9. Check each statement against the code or the docs of that commit. When you cannot check a statement, say so in the sentence, or leave it out.
10. Commit on a branch, and open a pull request.

## Where each area lives

| Path | Part |
|---|---|
| `src/geom.zig`, `clip.zig`, `offset.zig`, `mesh.zig`, `slicer.zig`, `engine.zig`, `parallel.zig`, `scratch.zig`, `main.zig` | 01 |
| `src/settings.zig`, `profile.zig`, `toml.zig`, `expr.zig`, `import_cura.zig`, `printers.zig`, `bed.zig`, `src/app/setting_*.zig`, `tools/printer_library.py` | 02 |
| `src/gcode*.zig`, `motion.zig`, `flow.zig`, `render/cpu.zig` | 03 |
| `src/layer.zig`, `infill.zig`, `lightning.zig`, `support*.zig`, `tree_support.zig`, `slope.zig`, `gapfill.zig`, `gaps.zig`, `islands.zig`, `arachne/`, `voronoi*.zig` | 04 |
| `src/filaments.zig`, `paint*.zig`, `field.zig`, `label.zig`, `font.zig`, `src/app/filament_slots.zig`, `src/app/labels.zig` | 05 |
| `src/physics.zig`, `rigid.zig`, `bond.zig`, `print_sim.zig`, `src/app/sim_*.zig`, `tools/calib/` | 06 |
| `src/app.zig`, `src/app/` (other files), `src/plate*.zig`, `orient.zig`, `cut.zig`, `src/c_api*`, `include/` | 07 |
| `src/render/` | 08 |
| `web/` | 09 |
| `linux/` | 10 |
| `macos/` | 11 |
| `windows/`, `src/render/d3d12.zig` | 12 |
| `src/bambu.zig`, `mqtt.zig`, `rtsp.zig`, `discovery.zig`, `src/app/printer_*.zig`, `src/app/farm.zig`, `tools/farm_sim/`, the network code of each shell | 13 |
| `src/app/session.zig`, `src/app/project_file.zig`, `src/project.zig`, `yaml.zig`, `threemf.zig`, `zipfile.zig`, the session code of each shell | 14 |
| `docs/build.py`, `docs/references/`, `.github/`, `packaging/` | 15 |
| `bench` in `src/main.zig`, `stream.zig`, `dexel.zig`, the memo in `layer.zig`, any commit with a time in its body | 16 |
| `AGENTS.md`, `README.md`, `ROADMAP.md`, `PRIVACY.md`, `LICENSE` | 00 |

## Style

Write each file in short, plain sentences. One idea per sentence. Active voice. Present tense. Give instructions as commands. Use lists for steps and sets. Do not use metaphors or idioms.
