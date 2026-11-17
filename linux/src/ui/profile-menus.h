/* profile-menus.h: the menus of the filament and the part (project)
 * settings in the header bar, next to the printer.
 *
 * Each menu lists the built-in profiles of its group and the profiles of
 * the user (profiles/<group>/<name>.toml in the settings folder, where the
 * command line finds them too), and has "Save as profile…". Its label is
 * the name of the profile in use (the filament: its name), with a mark
 * when the settings have changes since it was loaded. A switch asks first
 * when there are changes, so the settings of the user are not lost.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

G_BEGIN_DECLS

/* A menu button for group ZS_GROUP_FILAMENT or ZS_GROUP_PROJECT. */
GtkWidget *zg_profile_menu_new(ZgModel *model, int group);

G_END_DECLS
