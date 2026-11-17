/* shortcuts.h: the sheet of the keyboard shortcuts (?), as
 * web/app/shortcuts.js.
 *
 * SHORTCUTS in shortcuts.c is the one table of the keys of the GTK app.
 * The sheet shows it grouped, and an entry at its top filters it. When a
 * key changes (preview.c, view3d.c, window.c, search.c, history.c), change
 * it there too.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

/* Shows the sheet over `parent`, or closes it if it shows. */
void zg_shortcuts_toggle(GtkWindow *parent);
