/* cura-compare.h: the "Compare with Cura" window.
 *
 * It lists the zslice settings next to the settings of the active printer
 * of Cura (see cura-stack.h and zs_app_cura_compare): by default only the
 * settings that differ, or all settings that map to Cura. "Use" sets the
 * value of Cura in zslice (the printer, the filament, or this print), and
 * "Use all" sets all values that differ, except the names and the start
 * and end G-code. Each change goes through zg_model_set, so Undo works.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* Opens the window. `show_all` starts with all mapped settings. */
void zg_cura_compare_show(GtkWindow *parent, ZgModel *model, gboolean show_all);
