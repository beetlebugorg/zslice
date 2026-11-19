# A print farm

All your printers on one page: their state, their jobs, and the plates still to print.

**Printers** in the header (or in the main menu) opens the page over the view. **‹ Back to the plate** closes it. The tiles read the printers again every 10 seconds.

## The tiles

- Each printer with a connection has a tile: its state, its job with the time left, and the filament in it.
- **Send the plate** on a tile sends the active plate to that printer.

## Plates to print

- The list has each plate with parts, with its time and its plastic.
- Its menu lists the printers that fit the plate, the free printers first. A busy printer says when it is free: "busy, free in 1 h 5 min".
- A printer with a bed smaller than the plate is not in the menu.
- A plate that you sent has a check mark, and the printer and the time.

Each send asks first: "Is the bed clear?". It also warns when the printer looks busy, or when the plate is sliced for another printer.

**Tip:** To try a farm on one computer, run the farm simulator of the source tree: [tools/farm_sim](../../tools/farm_sim/README.md).

The macOS app adds a queue, a summary of the farm, and notifications. See [The macOS app](macos.md#a-farm).

## Where to go next

- → [Send to a printer](printers.md): add a printer and its connection.
- → [printdeck projects](projects.md): a repository of parts to print.
