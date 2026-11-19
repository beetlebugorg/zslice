/* range-card.h: the card of a range of layers (as web/app/rangecard.js).
 *
 * A left drag of the Select tool that starts on a printed line lights the
 * layers from that layer to the layer under the pointer (view3d.c,
 * zs_view_light_layers). On the release this card opens beside the lit
 * layers, never over them. It shows "Layers A–B" and the settings that
 * matter most of those that can change for some layers. An edit is an
 * override of the z range of the layers (the scope of the model,
 * zg_model_set_scope), and slices at once.
 *
 * Esc, a click elsewhere in the view, or x closes the card and ends the
 * light.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new card, hidden. Add it to the overlay of `preview`. The preview
 * keeps it (zg_range_card_of). */
GtkWidget *zg_range_card_new(ZgModel *model, GtkWidget *preview);
/* The card of the preview of `widget` (an ancestor of it), or NULL. */
GtkWidget *zg_range_card_of(GtkWidget *widget);
/* Opens the card for layers lo to hi (0-based). */
void zg_range_card_show(GtkWidget *card, size_t lo, size_t hi);
void zg_range_card_close(GtkWidget *card);
gboolean zg_range_card_open(GtkWidget *card);
