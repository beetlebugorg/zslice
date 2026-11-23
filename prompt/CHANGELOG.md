# Changelog of the prompt folder

One line for each update: the date, the commit that the folder describes, and the parts that changed.

| Date | Commit | Parts changed |
|---|---|---|
| 2026-11-21 | `a22bd40f` | All: the first version (README, 00 to 16, UPDATING, CHANGELOG). |
| 2026-11-22 | `b6af6dca` | README, CHANGELOG, 00 to 16 (all parts): the keys G and E, labels with handles, guides, SVG, and modes, the profile import, calibration prints, one part at a time, the second nozzle and the infill filament, the tower rework, the skin borders, the travel retraction of the printer, the combing modes, the X2D start G-code, one Check count, open links, the draft slice in each app, the lower bound page, and the Windows port. |
| 2026-11-22 | `aab615cd` (`import-fix`, before its merge to main) | README, UPDATING (an update in each push to main, and the new files in the table), CHANGELOG, 00 to 16 (all parts): the transform tool with lift and sink, up to 16 nozzles and tool changers, the Prusa models, the rib wall tower, a filament and infill for a part of some layers, the waste line, the Speed section and the app preferences, `project.resolution`, parts that do not fit, the import from a model page, the pose of a part in a 3MF file, booleans with no split point, the spiral vase fix, the history button, the icon, the deck addresses, and the Windows parity steps. |
| 2026-11-22 | `85ffdcaa` (`no-site-api`, before its merge to main) | CHANGELOG, 07, 09, 10, 13, 15: no app calls the API of a model site (the Printables API is private, and the terms of the Prusa sites forbid automated extraction); a model page gets `zs_import_page_text` and Open the page; the ZIP list stays; the lessons in 07 and 10. |
| 2026-11-22 | `58f58ca0` | README, CHANGELOG, 12: the part settings on the Windows part card, and Export off after a failed slice (the Windows session wrote part 12). |
| 2026-11-22 | `c0a7de63` | README, CHANGELOG, 07, 12: support marks are lines of the plate 3MF, so they are steps of the history and stay in the session (a lesson in 07); the Windows line card edits a support mark (12, by the Windows session). |
| 2026-11-22 | `8674769f` | README, CHANGELOG, 12: the import of a model page and a ZIP file on Windows (12, by the Windows session). |
| 2026-11-22 | `86444aca` | README, CHANGELOG, 12, 13: Windows reads the filaments of the printer through zs_app_filaments_from_printer and follows the spools of the current printer (by the Windows session). |
| 2026-11-22 | `f822fa35` | README, CHANGELOG, 12, 13: Windows watches the current printer in the background (HTTP each 5 s, one Bambu Lab MQTT link, backoff to 300 s, stop after 5 min minimized), by the Windows session; a longer wait in a threaded core test. |
| 2026-11-22 | `aa0b10b1` | README, CHANGELOG, 12: Windows parity 4 (User-Agent on file links, the printer picker counts, fall cancel, Shift+click runs, the part card notes, the test print, the lines a setting changes), by the Windows session. |
| 2026-11-22 | `d108148a` | README, CHANGELOG, 12: Windows history rows open their scope, and copy and paste of labels and layer changes (by the Windows session). |
| 2026-11-22 | `9614b39a` | README, CHANGELOG, 12: Windows clipboard for support areas, setting values, and line reports, in the copy order of the web and GTK apps (by the Windows session). |
