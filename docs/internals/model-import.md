# Import a model from a model page

The user pastes the address of a model page. zslice says how to get all the files of the model as one ZIP file, and opens the page in the browser. The user downloads the ZIP file there ("Download all"), and opens it in zslice. zslice lists the files of the ZIP file, and the user checks the files to load. zslice adds them as parts, and puts the parts that do not fit one plate on more plates. It never starts a print.

The rules are in the core: `src/model_import.zig`, the `zs_import_*` calls of `include/zslice.h`, and `zs_set_spill` of `include/zslice-app.h`. The core does no I/O. Each app does the dialog and the load. This page is the contract for each app.

## zslice calls no site API

zslice calls no API of a model site, in any app. It obeys the terms of each site.

| Site | Its API | Why zslice does not call it |
|---|---|---|
| Printables | A private GraphQL API for the pages of the site. | The API has no documentation and no permission for other apps. The terms of the Prusa sites forbid automated extraction and scraping. |
| Thingiverse | The REST API at `https://api.thingiverse.com`. | Each call needs an app token. A token in an open app is not secret. |

The sources and the terms are in [Printables](../references/printables.md) and [Thingiverse](../references/thingiverse.md).

A direct link to one file (an https URL of an STL, 3MF, STEP, or OBJ file, or a `zslice://open?file=` link) is different. The user chose that one file, and zslice downloads it as a browser does. See [Links that open a model](open-links.md).

## The call order

1. `zs_import_page_check(text, &page)` reads the address. It takes `printables.com/model/<id>`, `printables.com/<language>/model/<id>`, and `thingiverse.com/thing:<id>`, with or without `www.` and `https://`. `page.url` is the clean https URL of the page. A `zslice://open?file=` link to a model page also comes here: check `link.url` with `zs_import_page_check` after `zs_link_check`.
2. Show `zs_import_page_text(page.site)`. The text names the site, and tells the user to click "Download all" there and open the ZIP file in zslice. Offer **Open the page** (`page.url`), which opens the page in the browser.
3. For a ZIP file (from **Open** or a drop), `zs_import_list_zip(bytes, len, &list)`. Keep the bytes until the load ends. `ZS_IMPORT_NO_FILES` is a ZIP file with no file that zslice loads.
4. Show the list. This is the question before the load:
   - The title and the note from `zs_import_list_info`. Show `info.note` if it is not "".
   - A heading for each group (`file.kind_label`: 3MF, STL, STEP, OBJ, Other files). The list is in that order.
   - For each file: a check box (off and disabled when `can_load` is 0), the name, the size, the folder, `plates` when it is 2 or more, and `note`.
   - A line with the sum (`zs_import_ready`): the count and the size of the checked files, and "It does not start a print." With a result other than `ZS_IMPORT_OK`, show `zs_import_message` and disable the load button.
   - **Cancel** and **Load**. Cancel has the focus, so Enter does not start a load.
5. `zs_import_check(list, i, on)` follows each check box. The core checks the files to load first: each file that loads, but not a STEP file with an STL, 3MF, or OBJ file of the same name, and not a 3MF file when the model has STL or OBJ files (a model site often has the same parts in both).
6. On **Load**, for each checked file in the order of the list:
   - `zs_import_zip_file(list, bytes, len, i, &out, &out_len)`, then free the bytes with `zs_buffer_free`. Refuse a zslice project (`zs_project_file_is`).
   - A file that fails does not stop the others. Collect a line for each, and show them at the end.
7. Add the files as parts: on a new plate if the active plate has parts, the first file loads the plate, and each other file is a `zs_app_add_stl`. Then `zs_set_spill(set, zs_set_active(set))` puts the parts that do not fit the bed on new plates. Its result is the count of new plates. Never start a print.
8. `zs_import_list_free(list)`.

`zs_import_3mf_plates(bytes, len)` gives the plates of a 3MF file (Bambu Studio and OrcaSlicer projects). The ZIP list fills `plates` with it. The parts of all plates of a 3MF file load on one plate, and `zs_set_spill` spreads them.

The result codes 4 and 9 of `enum zs_import_result` are not used. They were the codes of the site API.

## The apps

| App | Code | State |
|---|---|---|
| Linux (GTK) | `linux/src/ui/model-import.c` (the dialog and the steps), `zg_window_add_import` in `ui/window.c`. The action `app.import-page` (the search, and the menu of the plate). A ZIP file from Open or a drop goes to the list. | The page dialog opens the page. A ZIP file from Open or a drop goes to the list. |
| Web | `web/app/modelimport.js`, and `importZip` and `loadImported` in `web/app/app.js`. The worker call `spill`. | The page dialog opens the page. A ZIP file from Open or a drop goes to the list. |
| macOS | `macos/Sources/ZSlice/Views/ModelImport.swift`. File > Import from a Model Page, the file menu, and the search open it. A ZIP file from Open, Add Models, a drop, or Open With goes to the list. | The page sheet opens the page. A ZIP file goes to the list. |
| Windows | `windows/src/app/MainWindow.ModelImport.cpp`. The search and the bed menu open it. A ZIP file from Open, a drop, or Open With goes to the list. | The page dialog opens the page. A ZIP file goes to the list. |

For tests of the GTK app: `ZSLICE_ACTION="app.import-page('<address>')"` opens the dialog with the address after the first slice, and `ZSLICE_IMPORT_LIST=1` presses **Continue** at once. For a ZIP file, `ZSLICE_IMPORT_YES=1` presses **Load** and logs the result.

## Tests

- `zig build test`: `src/model_import.zig` (the addresses, the text for a page, the checks, the ZIP lists, and the plates of a 3MF file), `src/c_api/import.zig`, and the spill of `src/app/plate_set.zig`.
- `node web/app/test-node.mjs`: the page check, the text for a page, a ZIP list, a file of it, and the spill through the wasm module.
