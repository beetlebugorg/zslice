/* part-page.h: the page of the selected part of the plate (Ctrl+click on a
 * part): its name and size, its place, turn, and scale, buttons to turn
 * it, remove it, and arrange the plate, and the placement modes (smart,
 * less support, strong along an axis). The page follows the
 * "plate-changed" signal of the model.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new page for the part zg_model_selected_part. */
GtkWidget *zg_part_page_new(ZgModel *model);
