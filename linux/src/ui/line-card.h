/* line-card.h: the card of a selected line, next to it in the view
 * (docs/internals/one-view.md, as web/app/linecard.js). A click on a line
 * opens it at the click. It shows what the line is (the feature and the
 * layer), its three numbers (the planned speed, the real speed, the flow),
 * why it is slow, its size, and the settings that matter for it, each with
 * a live editor and the reason of its pick. A change slices at once.
 * "Fade the others" shows the line solid and the other lines as ghosts,
 * and "All settings…" opens the Selected page of the panel.
 *
 * The card follows the line after a new slice (the model finds the line
 * again), and closes with Esc, with x, or with a click on no line. A drag
 * of its head moves it, and it keeps that place until it closes.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new card, hidden. Add it to the overlay of `preview`. */
GtkWidget *zg_line_card_new(ZgModel *model, GtkWidget *preview);
/* The Filament row: filament `filament` (from 1) for the body of the
 * selected line on its layer, as a click on its chip. */
void zg_line_card_pick_filament(GtkWidget *card, int filament);
/* The line card of the preview that has `widget` in it, or NULL. */
GtkWidget *zg_line_card_of(GtkWidget *widget);
