/* search.h: the search of settings and actions (/), a card over the view
 * (docs/internals/one-view.md). The web app has the same search
 * (web/app/search.js).
 *
 * The results are live controls: a number has a slider and an entry, a
 * choice its list, a switch its switch. A change goes to the core at once
 * (a drag sends a value at most each 90 ms), and the view under the
 * search shows the new slice. The eye of a result (or V) shows only the
 * lines that its setting changes, with the other lines as ghosts.
 *
 * Keys: Up and Down go through the results; Left and Right change the
 * value of the result (a step, or the next choice); Space or Enter turns a
 * switch or runs an action; V turns the eye on or off; Tab goes into the
 * controls; Esc leaves a control, then closes the search.
 *
 * The search field is always in the header (zg_search_header). Text in
 * it, a click in it, or / shows the results under it. The undock button
 * of the field makes the search a card over the view: a drag of its head
 * moves it, a drag of its lower right corner changes its size, and it
 * opens at the same place and size next time. While the search is
 * undocked, the header has a Search button that opens the card. The dock
 * button of the card puts the search back in the header.
 *
 * The search does not block the view: the results are a card of the
 * overlay of the preview (float.h), so a drag in the view turns it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new search card, hidden. Add it to the overlay of the preview. */
GtkWidget *zg_search_new(ZgModel *model);

/* The field of the search and the Search button, for the header bar. */
GtkWidget *zg_search_header(GtkWidget *search);

/* Opens the search with `text` (NULL: the text of the entry stays). part >= 0: the search of one part: only
 * the settings that a part can have of its own, and a change goes to the
 * part. part -1: the settings of the print, and the actions. */
void zg_search_show(GtkWidget *search, const char *text, gint64 part);
void zg_search_close(GtkWidget *search);
gboolean zg_search_is_open(GtkWidget *search);
