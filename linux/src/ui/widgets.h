/* widgets.h: small widget helpers that the panels share.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

/* A grid with the row and column spacing and the margins of a panel page. */
GtkWidget *zg_grid_new(void);

/* Adds a heading in a new row of `grid`, over the three columns of a
 * setting row. `row` is the next free row, and it goes up by one. A
 * heading after other rows has a space above it. */
GtkWidget *zg_grid_add_heading(GtkWidget *grid, int *row, const char *text);

/* A vertical scroll around `child`, which fills the height it gets. */
GtkWidget *zg_scrolled_new(GtkWidget *child);

/* TRUE if the theme of the app is dark now: its text color is light. The
 * views follow it (zs_view_set_dark, and the 2D view). */
gboolean zg_theme_dark(GtkWidget *widget);

/* Calls fn(data) after each change of the theme (the dark mode of the
 * system, or the theme of Preferences), once the new style applies. The
 * handler goes away with `owner`. */
void zg_on_theme_changed(GtkWidget *owner, void (*fn)(gpointer), gpointer data);

/* A label that wraps, aligned to the start. */
GtkWidget *zg_wrapped_label_new(const char *text);
