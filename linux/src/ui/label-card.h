/* label-card.h: the card of the selected label of the Label tool
 * (label-tool.h), as web/app/labelcard.js. A spatial card: it goes
 * beside the label and never covers the label or its handle, until a
 * drag of its head moves it. The card has:
 *
 * - the shapes of the label, each with the chips Text, Line, Bar, Ring,
 *   Ticks, and Free, and its fields (the text, the size, the ticks of a
 *   dial, ...), its offset, and "+ Add a shape…";
 * - the turn of the label, its filament (chips, "+", and "Add a filament"
 *   when the plate has one filament), and its depth (1 line, 2 lines, or
 *   mm);
 * - the stroke check (the thinnest stroke, the sizes of text that print
 *   clean and fair, and one line of advice), and the cost (the filament
 *   changes, the minutes, and the grams; an estimate before the slice),
 *   from zs_app_label_info;
 * - Delete.
 *
 * Each field changes the decal at once; the label goes to the core after
 * a short pause (label-tool.h).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"
#include "label-tool.h"

/* A new card, hidden. */
GtkWidget *zg_label_card_new(ZgModel *model, ZgLabelTool *tool);
/* Shows the card for label l: the fields again when its shapes changed,
 * else the new values (the field with the focus keeps its text). NULL
 * hides the card. */
void zg_label_card_show(GtkWidget *card, const ZgLabel *l);
/* The facts of zs_app_label_info: the stroke check and the cost. */
void zg_label_card_info(GtkWidget *card, JsonObject *info);
/* The curve of the face under the label (the warning over 60°). */
void zg_label_card_curve(GtkWidget *card, double deg);
/* The focus to the first text field, with its text selected. */
void zg_label_card_focus_text(GtkWidget *card);
/* Beside box (the label and its handle on the screen: x0, y0, x1, y1 in
 * points of the view), or where the user put the card. */
void zg_label_card_place(GtkWidget *card, GtkWidget *host, const double box[4]);
