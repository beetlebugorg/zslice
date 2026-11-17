/* printer-picker.h: the window that adds a printer.
 *
 * Two steps:
 *   1. Choose: a search (as you type), the brands, the models of the
 *      printer library (zs_printers_* in zslice-app.h) with their key
 *      facts, a drawing of the build volume, and the printers that the
 *      search of the network finds (net/discovery.h). A printer on the
 *      network fills the connection; when it tells its model or its bed,
 *      the model is selected.
 *   2. Set up: the name, the nozzle, the filament diameter, the bed, and
 *      the connection, with a test of the connection.
 * "Add printer" adds a printer (prefs/printers.h) with the machine profile
 * of the model, and makes it the current printer.
 *
 * At the first start (zg_printers_first_start), the window welcomes the
 * user, and the printer it sets up replaces the default "My printer".
 *
 * Test hooks: ZSLICE_PICKER=1 opens the window at the start. With it,
 * ZSLICE_PICKER_QUERY=text types a search, ZSLICE_PICKER_MODEL=id selects a
 * model, ZSLICE_PICKER_FOUND=n selects printer n of the network when the
 * search ends, ZSLICE_PICKER_STEP=2 goes to the second step, and
 * ZSLICE_PICKER_STEP=add adds the printer at once.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

G_BEGIN_DECLS

/* Opens the picker over `parent`. `welcome`: the first start. */
void zg_printer_picker_show(GtkWindow *parent, ZgModel *model, gboolean welcome);

/* The test hooks and the first start: opens the picker if the environment
 * or the first start asks for it. Call once after the window shows. */
void zg_printer_picker_startup(GtkWindow *parent, ZgModel *model);

G_END_DECLS
