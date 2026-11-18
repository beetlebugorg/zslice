/* farm-page.h: the Printers page, as the Printers page of the web app
 * (web/app/farm.js). The window shows it over the view, from the Printers
 * button of the header bar, with "Back to the plate".
 *
 * - A tile for each printer with a connection (printdeck, OctoPrint,
 *   Moonraker): its state, its job with the progress and the time left,
 *   and its filament (the printer status of the core). The tiles read
 *   again every 10 s while the page shows.
 * - "Send the plate" on a tile, and "Plates to print": each plate with
 *   parts, with the printers that fit it (the free ones first), and Send.
 *   Each send asks first if the bed is clear, and warns when the printer
 *   looks busy or the plate is sliced for another printer.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_farm_page_new(ZgModel *model);
