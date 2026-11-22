/* model-import.h: import a model from a model page or a ZIP file.
 *
 * The user pastes the address of a Printables model or a Thingiverse
 * thing. zslice calls no API of a site: the window says how to get the ZIP
 * file of the model, and opens the page in the browser. The user then
 * opens the ZIP file. A window lists the files of the ZIP file, with a
 * check box for each file that zslice loads, and asks. The list is the
 * question before the load. On Load, the window adds the checked files as
 * parts on a new plate, and puts the parts that do not fit on more
 * plates. It never starts a print. The rules are in the core (zs_import_*
 * in zslice.h). See docs/internals/model-import.md.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "zslice.h"

/* Asks for the address of a model page. text: an address to show in the
 * field, or NULL (the field then takes an address from the clipboard). */
void zg_model_import_ask(GtkWindow *window, const char *text);
/* Says how to get the ZIP file of a model page, with a button that opens
 * the page (a zslice:// link to a page comes here). */
void zg_model_import_page(GtkWindow *window, const zs_import_page *page);
/* Lists the files of a ZIP file. */
void zg_model_import_zip(GtkWindow *window, const char *name, GBytes *bytes);
/* Stops the import that runs (the app quits). */
void zg_model_import_cancel(void);
