/* paint-card.h: the card of the Paint tool (paint-tool.h), as the card of
 * web/app/paint.js: the mode (Smart select or Brush), the size of the
 * brush, a chip for each filament of the plate (the filament to paint
 * with) and "+" for a new filament, a hint, and "Remove all paint". It sits
 * at the top left of the 3D view, next to the tools, so it never covers
 * the part. Its buttons take no focus: the keys stay with the view.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"
#include "paint-tool.h"

GtkWidget *zg_paint_card_new(ZgModel *model, ZgPaintTool *tool);
/* The values of the tool again: the mode, the size, and the chips. */
void zg_paint_card_update(GtkWidget *card);
