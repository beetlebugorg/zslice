# 14. Sessions, project files, and printdeck.yml projects

## Goal

Make the app come back exactly as it was after a reload, a quit, or a crash: the plates, the parts, the settings, the edits, the printer of each plate, the camera, the pages, and the last frame, before the first slice. Save all plates as one project file. Open a repository of parts with a `printdeck.yml` from GitHub or from a folder.

## Read first

- The header of `src/app/session.zig`, `src/app/project_file.zig`, and `src/project.zig`.
- [The macOS app internals](../docs/internals/macos.md), section "The session": the most complete statement of the rules.
- [Plates and files](../docs/user/plates.md), [printdeck projects](../docs/user/projects.md), [Privacy](../PRIVACY.md) (what the browser keeps, and the GitHub requests).
- [GitHub REST API and Git LFS pointers](../docs/references/formats-and-protocols.md#github-rest-api-and-git-lfs-pointers).

## Build

1. The session (`zs_session_*`): one file, the same in each app. It has `project.zslice` (the project file of the set), `scene-<i>.bin` (the last beads of each plate, so the view shows the last frame at once), `session.json` (the camera: 8 floats of `zs_view_get_camera`), and `app.txt` (the state of the shell, kept as the shell wrote it).
2. Two steps for a write: `zs_session_snapshot_take` copies the plates and scenes on the UI thread; `zs_session_snapshot_write` makes the bytes on any thread. The core keeps the compressed meshes that did not change.
3. Where each shell keeps it: IndexedDB from the web worker; `session.zslice` in the config folder (`~/.config/zslice/`) on Linux; `Application Support/zslice/session` on the Mac (one `.zss` and one view `.json` for each window, and `index.json` for their order); `%APPDATA%\zslice\session.zslice` on Windows (or in `ZSLICE_STATE_DIR`).
4. At start, read the session, show the last scene of the active plate and the camera at once, then slice. The first slice gets the layer range and the selected part of the session.
5. The project file (`.3mf`): the model of the file is the first plate with parts, so another slicer opens that plate. `Metadata/zslice_project.json` has the format (1), the name, the active plate, and for each plate its name, its file, and its three settings texts. `Metadata/zslice_plate_<n>.3mf` has each plate. Ctrl+S saves it.
6. 3MF load and save (`src/threemf.zig`, `src/zipfile.zig`): parts at their places, components, units, zip64. A part whose build item is a turn about z and a move is read in the frame of its object, and `Plate.addPlaced` gives it the same turn and place. The vertices are the same to the bit as before the save. A "pose" line keeps the 9 values of the pose and the 3 of the scale of each part with a pose or a scale, and `Plate.restorePose` gives the pose back with no change of the mesh. A "lift" line keeps the lift. A 3MF load runs no fall. The undo snapshot reads the same way. `zipfile.directory` reads the central directory with no inflate, and `extract` inflates one entry (the model import reads only the checked files). Parts keep their settings, overrides, paint, labels, and support. Many copies of a part over plates, and the sum of the time and cost of all plates.
7. printdeck.yml projects (`src/project.zig`, `src/yaml.zig`): parse the parts (files, count, printer, profile `<folder>/<profile>` of `profiles/`, material, Cura settings, `alone`, variants). Plan the plates: parts with the same printer, profile, material, and plate settings share a plate. Load each plate with its Cura stack. A plate with no Cura stack is a resin plate, with the status "cannot".
8. A GitHub source in the web app: the commit and the file list from `api.github.com`, the files from `raw.githubusercontent.com` (and `media.githubusercontent.com` for Git LFS). No login, no data of the user. Read only the files that a plate needs. The Windows app reads GitHub in a separate WinHTTP session with no key or token, only over https to a GitHub host, with a limit of 256 MB for each file.
9. The status of each plate: To print, Printing, Printed, Failed. A send sets Printing. The status stays across a reload.

## Rules that matter

- **Write no session until the restore at launch is done.** This rule holds in each app.
- A change during the restore writes once, after the restore.
- A move of the camera never writes the session file. The camera has its own small file or field, written 1 s after the move.
- The session file comes after a change of the plates or a new slice, about 1.5 s after the last one, and not while a slice runs.
- A write goes to a temporary file first, then a rename.
- A change of the list of plates writes the session at once, once the read is done.
- A setting that zslice cannot use in a printdeck.yml stops the load of the plate, with the reason.
- A file or a link from outside the app (a second start, the Finder, a `zslice://` link) opens after the session is back, on a new plate if the active plate has parts.
- A link refuses a zslice project: a project replaces the plates and brings its own printer settings.
- The 3MF line of an edit ends with `zc` (empty for none). An older file has none, and its edits make each level dirty.
- A plate whose parts have overlapping boxes (and no settings or labels of their own) loads with those parts joined (`threemf.joinOverlapping`), also from a zslice file. A new app with `keep_places` false moves a loaded part that does not fit with the gap. So a reload of a 3MF can give other G-code than the state in memory. Not fixed yet.

## Lessons

- **Web: write the session only after the page has read it.** A refresh sometimes came back with an empty plate. The first plate list of the worker counted as a change, and it came while the page still read the session of the last visit. The write of that empty list replaced the saved plates. In a test after the fix, eight reloads in a row came back with the model, sliced.
- **Mac: write no session until the restore at launch is done.** A write during the wait for the window listed the new, empty window, and removed the files of the last run.
- **Linux: write the session on a thread.** The write held the UI thread for 490 to 660 ms with a 3DBenchy.
- Keep the plates in the session after a plate goes away. Keep a removed project plate away after a fast reload. Keep the changes to the plates of a project after a reload.
- Keep project paths inside the repository.
- **Bring parts back in their own frame, with no fall.** A part put down on a side came back different after a reload. The reader put the build transform into the f32 vertices, so the slice of a face near a cut plane changed with the rounding. For a Bittle X shoulder part, the first layer had the whole side before the reload and only a boss of 0.15 mm after it. The 3MF load also ran a fall, which turned the part by 0.52 degrees.
- **Windows: keep the session in the state folder.** A missing backslash put the session in `%APPDATA%zslice`, beside the state folder. The app now moves the old files at the first start.

## Acceptance checks

1. Eight reloads in a row in the web app come back with the model, sliced, and the camera in place.
2. A quit during the restore of the Mac app (`ZSLICE_RESTORE_DELAY`) loses no session.
3. A project file with three plates opens in zslice with all plates, and in another slicer with the first plate.
4. A printdeck.yml with variants and `alone: true` makes the plates that `docs/user/projects.md` describes.
5. A project path that leaves the repository (`../`) is refused.
6. A part lifted or sunk, and turned about X and Y, comes back from a session with the same vertices, angles, and G-code.
7. A region of a body (part 05) stays after a save, a load, and an undo.
14. A filament edit of one line is a "linefil" line in the 3MF overrides, the session, and the undo list: the filament, the layer, the stamp, the part id, the feature, whole or segment, the length, and the points. An older version skips the line.
