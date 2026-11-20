/* filaments.h: the filaments of the plate (zs_app_filament_*).
 *
 * - zg_filament_button_new: the button of the header bar. It shows a dot
 *   in the color of each filament (up to 8) and the name of the filament,
 *   or "N filaments". A click opens the list: for each filament its
 *   color, its number, its material, its nozzle (on a printer with two
 *   nozzles), and its grams in the last slice, then "+ Add a filament".
 * - zg_filament_chip_new: a round chip in the color of a filament, for
 *   the editors of project.filament (setting-editor.c).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_filament_button_new(ZgModel *model);

/* The color of a filament ("#rrggbb") as rgb, 0 to 1. Another text gives
 * the default gray. */
void zg_filament_rgb(const char *color, double rgb[3]);

/* A round button in `color` with `text` on it. A selected chip has a
 * ring. A NULL color gives a chip with no fill ("+", "Part"). */
GtkWidget *zg_filament_chip_new(const char *color, const char *text, gboolean selected);

/* Calls redraw(owner) once, at idle, after each change of the
 * filaments: a change of the list, a change of a filament setting, or
 * another plate. With `slices`, also after each slice (for the grams).
 * The calls stop when `owner` goes. */
void zg_filaments_follow(ZgModel *model, GtkWidget *owner, gboolean slices, void (*redraw)(GtkWidget *owner));
