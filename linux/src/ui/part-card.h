/* part-card.h: the card of a selected part, next to it in the view
 * (docs/internals/one-view.md, as web/app/partcard.js). The Move or the
 * Turn tool (or Ctrl and a click) selects a part, and the card shows:
 *
 * - its name, its size, and its turn;
 * - its actions: Duplicate (D), Best orientation, Less support, Reset,
 *   and Remove (Delete);
 * - the settings that the part has of its own, each with a live editor
 *   and x to give it the value of the plate again;
 * - "+ Add a setting for this part": the search of the part (search.h).
 *
 * A change slices at once. The card follows the part when the camera
 * moves, until a drag of its head moves it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new card, hidden. Add it to the overlay of `preview`. */
GtkWidget *zg_part_card_new(ZgModel *model, GtkWidget *preview);
