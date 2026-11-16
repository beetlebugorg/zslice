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

/* A label that wraps, aligned to the start. */
GtkWidget *zg_wrapped_label_new(const char *text);
