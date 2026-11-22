# Import a model from a model page

The user pastes the address of a model page. zslice lists the files of the model, and the user checks the files to load. zslice then downloads the checked files, adds them as parts, and puts the parts that do not fit one plate on more plates. It never starts a print.

The rules are in the core: `src/model_import.zig`, the `zs_import_*` calls of `include/zslice.h`, and `zs_set_spill` of `include/zslice-app.h`. The core does no I/O. Each app does the network part, the dialog, and the load. This page is the contract for each app. The download of each file follows [Links that open a model](open-links.md).

## What the sites allow

| Site | The list of files | Token | CORS (a page of zslice.beetlebug.org) |
|---|---|---|---|
| Printables | The GraphQL API at `https://api.printables.com/graphql/`: the query of its own model page. | None. The model must be public. | No. The API answers only `https://www.printables.com`. The files (`files.printables.com`) and the previews (`media.printables.com`) send `Access-Control-Allow-Origin: *`. |
| Thingiverse | The REST API at `https://api.thingiverse.com` | An app token for each call. A token in an open app is not secret, so zslice has none. | Yes, but no token. |

The sources and the terms are in [Printables](../references/printables.md) and [Thingiverse](../references/thingiverse.md). The Printables API has no documentation and no terms of its own. The general terms of the Prusa sites forbid scraping and a load that burdens the service. zslice asks only when the user pastes an address, asks for one model, downloads only the files that the user checks, one at a time, and keeps nothing.

So:

- The **native apps** read the list of a Printables model themselves.
- For a **Thingiverse** thing, each app shows `zs_import_message(ZS_IMPORT_NO_API)` and opens the page in the browser. The user downloads the ZIP file of the thing ("Download all files") and opens it in zslice.
- The **web app** cannot call the Printables API. It does the same as for Thingiverse: it opens the page, and the user downloads the ZIP file ("Download all"). The web app has no proxy server.
- Each app opens a **ZIP file** of a model with the same list (`zs_import_list_zip`).

## The call order

1. `zs_import_page_check(text, &page)` reads the address. It takes `printables.com/model/<id>`, `printables.com/<language>/model/<id>`, and `thingiverse.com/thing:<id>`, with or without `www.` and `https://`. `page.url` is the clean https URL of the page. A `zslice://open?file=` link to a model page also comes here: check `link.url` with `zs_import_page_check` after `zs_link_check`.
2. For `ZS_IMPORT_SITE_THINGIVERSE`, `zs_import_files_request` gives `ZS_IMPORT_NO_API`. Show `zs_import_message(ZS_IMPORT_NO_API)`, and offer **Open the page** (`page.url`).
3. For `ZS_IMPORT_SITE_PRINTABLES`:
   1. `zs_link_check_url(zs_import_api_url(page.site), &api)` gives the API URL as a `zs_link`.
   2. Send a POST to it with the body of `zs_import_files_request`, `Content-Type: application/json`, `Accept: application/json`, and `User-Agent:` `zs_import_user_agent()`. Use the checks of a download: resolve the host and check each address (`zs_link_address_public`), check the peer before the TLS handshake, use no proxy, and send no cookie and no credentials. Follow no redirect. Accept only 2xx, and at most `ZS_IMPORT_MAX_ANSWER` bytes.
   3. `zs_import_list_read(&page, json, len, &list)` reads the answer. `ZS_IMPORT_NOT_FOUND` is a model that is not public or does not exist. `ZS_IMPORT_NO_FILES` is a model with no file that zslice loads.
4. For a ZIP file, `zs_import_list_zip(bytes, len, &list)`. Keep the bytes until the load ends.
5. Show the list. This is the question before the download:
   - The title, the author, the license, and the page from `zs_import_list_info`. Show `info.note` if it is not "".
   - A heading for each group (`file.kind_label`: 3MF, STL, STEP, OBJ, Other files). The list is in that order.
   - For each file: a check box (off and disabled when `can_load` is 0), the name, the size, the folder, `plates` when it is 2 or more, and `note`.
   - A preview image for a file with a `preview` URL: check it with `zs_link_check_url`, and GET it with the checks of step 3.2 and the redirects of the core, at most `ZS_IMPORT_MAX_PREVIEW` bytes, one at a time, after the list shows. A preview that fails leaves its place empty.
   - A line with the sum (`zs_import_ready`): the count and the size of the checked files, and "It does not start a print." With a result other than `ZS_IMPORT_OK`, show `zs_import_message` and disable the load button.
   - **Cancel** and **Download and load**. Cancel has the focus, so Enter does not start a download.
6. `zs_import_check(list, i, on)` follows each check box. The core checks the files to load first: each file that loads, but not a STEP file with an STL, 3MF, or OBJ file of the same name, and not a 3MF file when the model has STL or OBJ files (a model site often has the same parts in both).
7. On **Download and load**, for each checked file in the order of the list, one at a time:
   - Printables: POST the body of `zs_import_link_request(list, i)` as in step 3.2. `zs_import_link_read(list, i, json, len, &link)` checks the answer: an https URL on `printables.com` or one of its subdomains, with the name of the file. Download the `zs_link` with steps 1 to 9 of [Links that open a model](open-links.md).
   - A ZIP file: `zs_import_zip_file(list, bytes, len, i, &out, &out_len)`, then free the bytes with `zs_buffer_free`. Refuse a zslice project (`zs_project_file_is`).
   - A file that fails does not stop the others. Collect a line for each, and show them at the end.
8. Add the files as parts: on a new plate if the active plate has parts, the first file loads the plate, and each other file is a `zs_app_add_stl`. Then `zs_set_spill(set, zs_set_active(set))` puts the parts that do not fit the bed on new plates. Its result is the count of new plates. Never start a print.
9. `zs_import_list_free(list)`.

`zs_import_3mf_plates(bytes, len)` gives the plates of a downloaded 3MF file (Bambu Studio and OrcaSlicer projects). A file at a site has `plates` 0 in the list, because the site does not say. The parts of all plates of a 3MF file load on one plate, and `zs_set_spill` spreads them.

## The apps

| App | Code | State |
|---|---|---|
| Linux (GTK) | `linux/src/ui/model-import.c` (the dialog and the steps), `linux/src/net/model-download.c` (`zg_net_request`: the POST and the GET), `zg_window_add_import` in `ui/window.c`. The action `app.import-page` (the search, and the menu of the plate). A ZIP file from Open or a drop goes to the list. | The full list for Printables, with previews. Thingiverse opens the page. |
| Web | `web/app/modelimport.js`, and `importZip` and `loadImported` in `web/app/app.js`. The worker call `spill`. | The page dialog opens the page. A ZIP file from Open or a drop goes to the list. |
| macOS | Not yet. Use the calls in this order. | |
| Windows | Not yet. Use the calls in this order. | |

For tests of the GTK app: `ZSLICE_ACTION="app.import-page('<address>')"` opens the dialog with the address after the first slice, `ZSLICE_IMPORT_LIST=1` lists the files at once, and `ZSLICE_IMPORT_YES=1` also presses **Download and load** and logs the result.

## Tests

- `zig build test`: `src/model_import.zig` (the addresses, the answers of Printables, the checks, the links, the ZIP lists, and the plates of a 3MF file), `src/c_api/import.zig`, and the spill of `src/app/plate_set.zig`.
- `node web/app/test-node.mjs`: the page check, a ZIP list, a file of it, and the spill through the wasm module.
