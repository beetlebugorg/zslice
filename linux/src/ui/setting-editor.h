/* setting-editor.h: the editor of one setting, and the text of a value.
 *
 * The editor depends on the kind of the setting:
 *   number, integer: an entry. The value goes to the core after a short
 *     pause in the typing, on Enter, and when the focus leaves. Up and Down
 *     step the value (Shift: 10 steps, Ctrl: a tenth of a step). A ratio
 *     (unit "%") shows as a percentage: the core value 0.5 shows as 50.
 *   one-line text: an entry, set on Enter or when the focus leaves it
 *   boolean: a switch
 *   choice: a drop-down
 *   multi-line text (G-code): a text view, set when the focus leaves it
 *   a filament (zg_setting_is_filament): a row of chips, one in the color
 *     of each filament of the plate, and "+" to add a filament
 *
 * A value that the core rejects gets the "error" style, and the tooltip
 * says why. A value out of the slider range gets the "zg-unusual" style.
 * Each set starts a new slice (zg_model_set_for). Each editor follows the
 * "setting-changed" signal of the model, so all editors of a setting show
 * the same value.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new editor for the setting `info`. A `scoped` editor reads and sets
 * the value for the scope of the model (zg_model_get_for): all layers, or
 * the layers of the selection. */
GtkWidget *zg_setting_editor_new(ZgModel *model, const zs_setting_info *info, gboolean scoped);

/* An editor of the value of one part (zg_model_part_setting): it shows the
 * value of the plate while the part has none of its own, and a change
 * goes to the part. */
GtkWidget *zg_setting_editor_new_for_part(ZgModel *model, const zs_setting_info *info, size_t part);

ZgModel *zg_setting_editor_model(GtkWidget *editor);
const zs_setting_info *zg_setting_editor_info(GtkWidget *editor);

/* Shows the value of the core again, for example after a change of the
 * scope. An editor with the focus keeps its text. */
void zg_setting_editor_refresh(GtkWidget *editor);

/* A drag on `label` to the left or the right changes the number of the
 * editor: one step for each 6 px. */
void zg_setting_editor_add_scrub(GtkWidget *editor, GtkWidget *label);

/* A slider for the number editor, over the usual range of the setting
 * (slider_min to slider_max). The slider and the editor follow each other. */
GtkWidget *zg_setting_editor_slider_new(GtkWidget *editor);

/* A drag of the slider sends a value at most each `ms` ms, and the last
 * value at the end of the wait (the search: 90 ms). */
void zg_setting_editor_slider_throttle(GtkWidget *slider, guint ms);

/* For a speed ratio, `unit` also shows the speed that the ratio gives, for
 * example "% = 45 mm/s", and follows each change of a setting. Does nothing
 * for other settings. */
void zg_setting_editor_show_speed(GtkWidget *editor, GtkWidget *unit);

/* The text of a core value as the editors show it: a ratio as a
 * percentage, a line width of 0 as "auto", and the first line of G-code.
 * Free with g_free. */
char *zg_setting_display_value(const zs_setting_info *info, const char *value);

/* The display value with its unit: "3 walls", "1 layer", "auto". Free with
 * g_free. */
char *zg_setting_value_with_unit(const zs_setting_info *info, const char *value);

/* The description of the setting `name`. FALSE if there is none. */
gboolean zg_setting_find(const char *name, zs_setting_info *out);

/* TRUE for a setting whose editor is a row of filament chips:
 * project.filament, project.support_filament, and
 * project.support_interface_filament. Its editor has no slider. */
gboolean zg_setting_is_filament(const char *name);

/* TRUE if all of `text` is a number. */
gboolean zg_parses_as_number(const char *text);
