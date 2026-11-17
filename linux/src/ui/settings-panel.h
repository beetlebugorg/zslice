/* settings-panel.h: the settings panel at the side of the window.
 *
 * The panel has two pages with tabs:
 *   "Selected": the inspector of the selected line or part (inspector.h)
 *   "Settings": a browser of all settings (settings-browser.h)
 * Both pages build their rows from the setting descriptions of the core
 * (zs_setting_get_info), so they need no change when the core gets a new
 * setting.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_settings_panel_new(ZgModel *model);
/* Shows the Settings page at the setting `key` (for example
 * "machine.start_gcode"). */
void zg_settings_panel_show_setting(GtkWidget *panel, const char *key);
