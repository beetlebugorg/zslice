/* setting-row.h: one setting as a row of a grid: the label, the editor
 * (see setting-editor.h), the unit, and the slider.
 *
 * A row has four columns: the label, the editor, the unit, and (in a
 * compact row) a reset button. The unit has its own column, so the editors
 * line up.
 *
 * A compact row is for the inspector. It has one line (the label does not
 * wrap, and the group is in the tooltip). While the row has the focus, a
 * part opens under it with the slider and a text that says what the
 * setting does to the selected line, and the previews show the lines that
 * the setting changes (zg_model_set_focus). The row also follows the scope
 * of the model: a setting that cannot change in the scope is off, and a
 * setting with an override has the accent color and a reset button.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* The flags of zg_setting_row_add. */
enum { ZG_ROW_COMPACT = 1 };

/* The widgets of one row, for a filter. */
typedef struct {
    GtkWidget *widgets[4];
    char *needle; /* the label in lower case */
} ZgSettingRow;

/* Adds the rows of the setting `info` to `grid`, from row `*row` on, and
 * moves `*row` past them. Free the result with zg_setting_row_free. */
ZgSettingRow *zg_setting_row_add(GtkWidget *grid, int *row, ZgModel *model, const zs_setting_info *info, int flags);

void zg_setting_row_free(gpointer row);
