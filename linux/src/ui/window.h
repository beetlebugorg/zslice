/* window.h: the main window.
 *
 * A header bar (Open, Export, the menu), the settings panel on the left,
 * the layer preview on the right, and a status bar with the progress and
 * the result.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWindow *zg_window_new(GtkApplication *app, ZgModel *model);

/* Opens a model file in the window. */
void zg_window_open_file(GtkWindow *window, GFile *file);

/* The actions of the window, for the app menu and the shortcuts. */
void zg_window_open_dialog(GtkWindow *window);
void zg_window_export_dialog(GtkWindow *window);
/* Saves the plate (parts, places, and their changes) as a 3MF file. */
void zg_window_save_plate_dialog(GtkWindow *window);
