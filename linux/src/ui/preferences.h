/* preferences.h: the Preferences window: the printers (with their
 * connections) and the global app settings.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* Shows the Preferences window (one for each main window). */
void zg_preferences_show(GtkWindow *parent, ZgModel *model);

/* Applies the global app settings that change the look (the theme). */
void zg_preferences_apply_theme(void);
