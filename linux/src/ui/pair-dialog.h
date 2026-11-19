/* pair-dialog.h: connect zslice to a printdeck or an OctoPrint printer in
 * one step.
 *
 * The dialog starts the App Keys flow at once (zg_link_request_key): the
 * printer asks "Allow zslice?" on its touch screen (printdeck) or in its
 * web page (OctoPrint). The dialog says so, counts down the 2 minutes, and
 * has Cancel. After Allow, the key goes to the printer (app.ini). A
 * printdeck that drives more than one printer lists them
 * (/slicer/printer.json): the user picks the ones to add, and each one
 * gets the key of the deck and the path of its API under the deck. After
 * Deny or the timeout, the dialog says so and offers Try again.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

G_BEGIN_DECLS

/* Opens the dialog for the printer `printer_id`. `done` runs after a key
 * came (TRUE) or the dialog closed with none (FALSE), or is NULL. */
void zg_pair_dialog_show(GtkWindow *parent, ZgModel *model, const char *printer_id, void (*done)(gboolean ok, gpointer data),
                         gpointer data);

G_END_DECLS
