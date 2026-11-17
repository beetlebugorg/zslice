/* settings-browser.h: the "Settings" page of the settings panel, a browser
 * of all settings, built from the setting descriptions of the core
 * (zs_setting_get_info).
 *
 * Three columns, as in a column view of a file manager:
 *   1. the sections, under a heading for each group (Project, Filament,
 *      Machine, Engine), with a search field on top
 *   2. the settings of the section (or the search results), with their
 *      values
 *   3. the selected setting: its editor, its default, its help, and the
 *      lines of the project that it changes. The previews show these lines
 *      clearly and fade the others (zg_model_set_focus).
 * The columns scroll to the side, so a narrow panel shows the last two. A
 * bar over the columns has a Back button and the path to the setting.
 *
 * The edits of this page are the defaults for all prints.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new page. `panel_stack` is the page stack of the panel: the previews
 * show the lines of the selected setting only while this page is in front. */
GtkWidget *zg_settings_browser_new(ZgModel *model, GtkWidget *panel_stack);

/* Selects the setting `key`, for a link from another page. */
void zg_settings_browser_show_setting(GtkWidget *browser, const char *key);

/* TRUE if the page must be in front at the start (ZSLICE_SETTING). */
gboolean zg_settings_browser_opens_first(GtkWidget *browser);

/* The place in the browser (its column, section or feature list, and
 * setting) as text, and a move back to such a place. For the history of
 * the panel. */
char *zg_settings_browser_get_place(GtkWidget *browser);
void zg_settings_browser_set_place(GtkWidget *browser, const char *place);
/* The history of the panel: `nav` after each move in the browser, and
 * `back` for its Back button (in place of the column before). */
void zg_settings_browser_set_history(GtkWidget *browser, void (*nav)(gpointer), void (*back)(gpointer), gpointer data);
/* The column before. */
void zg_settings_browser_up(GtkWidget *browser);
