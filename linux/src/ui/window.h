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
/* Opens files from outside the app (a file manager, a second start): on a
 * new plate if the active plate has parts. */
void zg_window_open_external(GtkWindow *window, GFile **files, int n);
/* Opens the bytes of a downloaded model: on a new plate if the active
 * plate has parts. */
void zg_window_open_bytes(GtkWindow *window, const char *name, GBytes *bytes);
/* A line in the status bar and the fraction of the progress bar. */
void zg_window_show_progress(GtkWindow *window, const char *text, double fraction);
/* An alert with a message and a detail. */
void zg_window_show_error(GtkWindow *window, const char *message, const char *detail);
/* The 3D view of the window (for the camera of a session), or NULL. */
GtkWidget *zg_window_view3d(GtkWindow *window);

/* The actions of the window, for the app menu and the shortcuts. */
void zg_window_open_dialog(GtkWindow *window);
void zg_window_export_dialog(GtkWindow *window);
/* Saves the plate (parts, places, and their changes) as a 3MF file. */
void zg_window_save_plate_dialog(GtkWindow *window);
