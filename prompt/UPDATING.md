# Keep the prompt folder current

Each push to main includes the update of this folder for the commits that it brings, in the same push. A merge to main follows the same rule. Do not wait for a batch of merges.

## Steps

1. Find the commit that last changed this folder: `git log -1 --format=%h -- prompt/README.md`.
2. List the commits that the push brings to main, from that commit to the tip of the branch:

   ```sh
   git fetch origin
   git log --reverse --format='%h %s' <commit>..<branch>
   ```

3. For each commit, find the parts that it touches. Use the table below. Read the body of each commit whose subject starts with "Fix", "Keep", "Do not", "Never", "Stop", "Refuse", or has "only": these are corrections, and they become lessons.
4. Read the changed docs and module headers (`git diff --stat <commit>..<branch> -- docs src include`). Link to a doc when it states the behavior. Write in a part only what the docs leave out: the order, the numbers to match, the lessons, and the acceptance checks.
5. Update each part that the commits touch:
   - Add a new feature to the "Build" list of its part.
   - Add a new number or rule to "Numbers and rules that matter".
   - Add a correction to "Lessons", with the fault and the fix in one or two sentences.
   - Add or change an acceptance check.
   - Remove a statement that the code no longer supports.
6. Add a new part only for a new area of the app. Give it the next number, and add it to the list in `README.md`.
7. Change the top of `README.md` to `Describes: main through "<subject of the last code commit>", <date>.`
8. Add one line to `CHANGELOG.md`: the date, the subject of the last code commit, and the parts that changed.
9. Check each statement against the code or the docs of that commit. When you cannot check a statement, say so in the sentence, or leave it out.
10. Put the update in the last code commit of the branch with `git commit --amend`. Do not make a separate commit for the prompt or for a pointer to a commit. The release notes must list only changes that a user can see.

## Where each area lives

| Path | Part |
|---|---|
| `src/geom.zig`, `clip.zig`, `offset.zig`, `mesh.zig`, `slicer.zig`, `engine.zig`, `parallel.zig`, `scratch.zig`, `main.zig` | 01 |
| `src/settings.zig`, `profile.zig`, `toml.zig`, `expr.zig`, `import_cura.zig`, `printers.zig`, `bed.zig`, `src/app/setting_*.zig`, `src/app/speed.zig`, `tools/printer_library.py` | 02 |
| `src/gcode*.zig`, `motion.zig`, `flow.zig`, `render/cpu.zig` | 03 |
| `src/layer.zig`, `infill.zig`, `lightning.zig`, `support*.zig`, `tree_support.zig`, `slope.zig`, `gapfill.zig`, `gaps.zig`, `islands.zig`, `arachne/`, `voronoi*.zig` | 04 |
| `src/filaments.zig`, `paint*.zig`, `field.zig`, `label.zig`, `font.zig`, `src/app/filament_slots.zig`, `src/app/labels.zig`, `src/tower.zig`, `src/body_region.zig` | 05 |
| `src/physics.zig`, `rigid.zig`, `bond.zig`, `print_sim.zig`, `src/app/sim_*.zig`, `tools/calib/` | 06 |
| `src/app.zig`, `src/app/` (other files), `src/plate*.zig`, `orient.zig`, `cut.zig`, `part_snap.zig`, `model_import.zig`, `src/c_api*`, `include/` | 07 |
| `src/render/` | 08 |
| `web/` | 09 |
| `linux/` | 10 |
| `macos/` | 11 |
| `windows/`, `src/render/d3d12.zig` | 12 |
| `src/bambu.zig`, `mqtt.zig`, `rtsp.zig`, `discovery.zig`, `src/app/printer_*.zig`, `src/app/farm.zig`, `tools/farm_sim/`, the network code of each shell | 13 |
| `src/app/session.zig`, `src/app/project_file.zig`, `src/project.zig`, `yaml.zig`, `threemf.zig`, `zipfile.zig`, the session code of each shell | 14 |
| `docs/build.py`, `docs/references/`, `.github/`, `packaging/`, `assets/icon/`, `tools/icons.sh` | 15 |
| `bench` in `src/main.zig`, `stream.zig`, `dexel.zig`, the memo in `layer.zig`, any commit with a time in its body | 16 |
| `AGENTS.md`, `README.md`, `ROADMAP.md`, `PRIVACY.md`, `LICENSE` | 00 |

## Style

Write each file in short, plain sentences. One idea per sentence. Active voice. Present tense. Give instructions as commands. Use lists for steps and sets. Do not use metaphors or idioms.
