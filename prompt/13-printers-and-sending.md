# 13. Printers and sending

## Goal

Find printers on the network, pair with them, read their state and their spools, play their cameras, and send each plate to them, signed. Support Printdeck (one deck drives many printers), OctoPrint, Moonraker, PrusaLink, USB serial (Linux), and Bambu Lab printers in LAN mode, with the `.gcode.3mf` file of Bambu Studio. Add the Printers page and the farm. The core makes every packet and parses every reply. Each shell owns its sockets.

## Read first

- [Send to a printer](../docs/user/printers.md), [A print farm](../docs/user/farm.md), [Print in colors](../docs/user/filaments.md#use-the-filaments-of-the-printer).
- [The macOS app internals](../docs/internals/macos.md), sections "Printers", "Keys and decks", "Bambu Lab", "Cameras", and "The farm": the most complete description of the link rules.
- [The Windows app internals](../docs/internals/windows.md), section "Printers".
- [Formats and protocols](../docs/references/formats-and-protocols.md): OctoPrint REST and App Keys, mDNS and DNS-SD, the service types, Moonraker, webcams, MJPEG, the printdeck API, FTPS and MQTT, RTSP and H.264.
- [Bambu Studio](../docs/references/bambu-studio.md): the file layout, the report fields, and the AMS mapping.
- The headers of `src/bambu.zig`, `src/mqtt.zig`, `src/rtsp.zig`, `src/discovery.zig`, `src/app/printer_status.zig`, `src/app/printer_filaments.zig`, `src/app/farm.zig`.

## Build

1. Discovery (`src/discovery.zig`): one mDNS query for the PTR records of `_octoprint._tcp`, `_moonraker._tcp`, and `_prusalink._tcp` to 224.0.0.251:5353. If an answer has the PTR record alone, ask for SRV, TXT, and A. Then `GET /api/version` tells printdeck and PrusaLink from OctoPrint, and the Klipper toolhead tells the bed size. Bambu Lab printers in LAN mode answer SSDP. A browser cannot send mDNS: the web app asks for an address.
2. Status (`src/app/printer_status.zig`): the app GETs each path of `paths(kind)` and feeds each reply to the core. OctoPrint: `/api/printer`, `/api/printerprofiles`, `/api/job`. Printdeck: `/api/printer` and `/api/plugin/printdeck` (the material, the rolls, the limits, the job). Moonraker: `/printer/objects/query`. Bambu Lab: each MQTT report.
3. Spools (`src/app/printer_filaments.zig`): a printdeck lists `filaments` with slot, tray, nozzle (main or aux), material, color, and idx. A Bambu report lists its AMS trays. The plate gets the count, the material, the profile, the color, and the nozzle of each. The web app reads them again each 20 s, the GTK app each 5 s. The Mac follows the spools of the printer of the plate each 10 s, and when the plate gets another printer (`zs_app_filaments_from_printer` with flag 2), with a note that says what changed. A filament set by hand shows a hand, and it stays. A print on a Bambu Lab printer sends the tray of each filament (`zs_app_ams_mapping`).
4. Keys: OctoPrint App Keys (`requestKey`): the printer asks "Allow zslice?", within 2 minutes. A printdeck asks on its screen. Show the key id on both sides.
5. A send: sign the G-code (part 03), post it, and count it as sent only when the printer answers that it stored the file. Any other answer is an error with the address and the start of the answer.
6. Bambu Lab LAN (`src/bambu.zig`, `src/mqtt.zig`):
   - Upload over FTPS: implicit TLS on port 990, user `bblp`, the access code as the password, to the root folder, a name that ends in `.gcode.3mf`.
   - MQTT 3.1.1 over TLS on port 8883, the same login. Subscribe to `device/<serial>/report`. Publish to `device/<serial>/request`.
   - The file: `Metadata/plate_1.gcode` and its MD5 in `plate_1.gcode.md5`, `slice_info.config` (with `<layer_filament_lists>`), `project_settings.config` (the settings of Bambu Studio for the model), `plate_1.json` (the plate type, the filaments, the nozzle), and `filament_sequence.json`. The model part is empty.
   - The AMS mapping of a print start: `ams_mapping` (the AMS unit times 4 plus the tray; -1 for a filament with no tray) and `ams_mapping2` (`ams_id` and `slot_id`; 255 and 255 for none; 254 is the external spool). A plate of filament 4 only on a printer with tray 3 gives `"ams_mapping":[-1,-1,-1,3]`.
   - The certificate has no authority. Trust it at the first connection, keep its SHA-256, and send the access code only to that certificate after that.
   - Cameras: P1 and A1 send JPEG frames on port 6000. X1, H2, P2S, and X2D send RTSP over TLS on port 322 with H.264 (`src/rtsp.zig`).
7. Printdeck pairing and the deck root (see the lesson): pair and list the printers at the root of the deck (`/slicer/printer.json`). Each added printer gets the root of the deck and its own path as its address, its name on the deck, the key of the deck, and the profile of its model.
8. The Printers page: a card for each printer with its camera, state, job, temperatures, and roll. A camera plays only while its card is on the screen. The plates of the project are at the top, each with a printer to send it to.
9. The farm (`src/app/farm.zig`): printers, orders, jobs, proposals of sends, and events. The farm never sends by itself: a send is a proposal that the user confirms. `tools/farm_sim/` simulates printdecks.

## Rules that matter

- **A print starts only after a fresh yes to "Is the bed of X clear?".** Never from a timer or a retry. A printdeck starts prints from the slicer by default. With its setting "Start prints from the slicer" off, it waits for a press on the deck; the app says which one happened.
- **The API key stays on its printer.** A request with the key follows no redirect to another origin (the web app refuses redirects; the GTK app and the Mac drop the key header on a redirect to another origin; Windows follows no redirect and uses no proxy).
- **Check the target of each send to a deck.** Read `printer.json` at the root of the deck. Match names by their words (lower case, split at each character that is not a letter or digit): "Bambu Lab X2D" names "X2D". Stop the send when the address leads to another printer of the deck.
- An address of a printdeck can have a secure name (`https://….d.printdeck.beetlebug.org`), which works from the web app in any browser. The link tries the address that answered last, then https, then http. A refused certificate stops, with no fall back to http.
- Each printer keeps its own printer settings and the last filament used with it.
- Secrets live outside the repository: the Keychain on the Mac, DPAPI on Windows, IndexedDB in a browser, and files readable only by the user on Linux.

## Lessons

- **Pair at the root of the deck.** The list of the printers of a deck came back 404 after a pairing. The saved address was of one printer (`.../printers/<id>/`), so the app asked for `.../printers/<id>/slicer/printer.json`, which does not exist. A pairing at that address also gave a key for that printer only, and the list refuses such a key. Pair and list at the root of the deck.
- **Refuse a send that may reach another printer.** A queued print for the X2D went to the TAZ. An address of the deck itself, on a deck of two or more printers, with no saved deck name and a name that does not name the first printer, now stops the send with a message.
- **Load the first filament of the print** in the start G-code (part 03). The X2D failed in PREPARE with "Failed to get AMS mapping table" when the start G-code loaded a filament with no tray.
- **Name only a used filament for each nozzle** in the X2D start G-code (part 03). A print of filaments 3 and 4 on the main nozzle stopped 37 s in with HMS errors, because the start G-code named filament 4 for the second nozzle.
- Repair an address saved with a printer path twice (`.../printers/x2d/printers/x2d`).
- A model hint of one word matches no library model: "TAZ" alone matched a TAZ 6 for a TAZ Workhorse.
- Keep the project paths inside the repository, and limit the size of MQTT packets.
- Fuzz the readers of outside files and packets (`src/fuzz.zig`): zip, STL, YAML, TOML, formulas, start G-code, G-code import, MQTT and the Bambu camera, discovery, 3MF, Cura stacks, fonts, and labels. Each reader returns a value or an error. It must not panic, read out of bounds, or leak.

## A note on the X2D

The X2D work is recent. The git log has a series of fixes that match the file of Bambu Studio 02.09 (hotend keys, templates, `slice_info.config`, the layer change, the end of the start G-code). Later fixes name only a used filament for each nozzle, prime and wipe on the tower before the part, keep the idle nozzle 10 °C under its temperature, and use the travel retraction of Bambu Studio. This folder does not confirm that a two-nozzle print from zslice completes on a real X2D. Test it on the printer before you call the part done.

## Acceptance checks

1. `meson test` (Linux), `node web/app/test-link.mjs` (web), `windows/test/net_link.cpp` (Windows), and `macos/tools/fake_bambu.py` (Mac) pass against local stubs.
2. A pairing with a deck of two printers lists both, with the key of the deck, and a send to each reaches the printer that the user picked.
3. The `.gcode.3mf` of each Bambu model has the files and fields of the file of Bambu Studio for that model. The X2D is the hard case: see the note above.
4. A fake deck at its own address, named "Bambu Lab X2D", stops the send. "taz workhorse" goes to the TAZ.
5. `zig build test` runs the fuzz tests of the readers with no panic.
