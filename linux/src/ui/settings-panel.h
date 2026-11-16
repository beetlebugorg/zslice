/* settings-panel.h: the settings panel.
 *
 * The panel has one page for each settings group (machine, filament,
 * project, engine). It builds its rows from the setting descriptions of the
 * core (zs_setting_get_info), so it needs no change when the core gets a new
 * setting.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

GtkWidget *zg_settings_panel_new(ZgModel *model);
