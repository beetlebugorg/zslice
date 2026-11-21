/* open-link.h: a zslice://open?file=<URL> link given to the app.
 *
 * The app gets a link from the desktop (x-scheme-handler/zslice in the
 * .desktop file) as a GApplication "open". The link asks first: a dialog
 * shows the file name and the site. After a yes, the file downloads
 * (net/model-download) and opens on a new plate if the active plate has
 * parts. A link never opens a zslice project, and never starts a print.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

/* Checks the link, asks the user, and downloads the file. */
void zg_open_link(GtkWindow *window, const char *uri);
/* Stops a download that runs (at the end of the app). */
void zg_open_link_cancel(void);
