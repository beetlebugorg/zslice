/* history.h: undo, redo, and the history of the changes.
 *
 * The dock at the bottom of the preview has undo, redo, and a history
 * button (zg_history_tools_new, zg_preview_set_history). The button shows
 * a count of the changes since the last open or save. A click on it, the
 * History item of the main menu, or Ctrl+H opens the History list in a
 * popover over the button. The list shows each step, the newest first,
 * with the glyph of its kind, its time, and its changes in words. A click
 * on a step goes to it, and the preview slices at that step. Each change
 * has an undo button that undoes only that change and keeps the later
 * ones. A double click on a change goes to it and opens its setting, to
 * edit it. A button under the list clears the steps after the step now.
 *
 * The steps are the steps of undo and redo (zg_model_history_*).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include "../model/app-model.h"

#include <gtk/gtk.h>

/* The list of the changes. A double click on a setting opens it with the
 * actions "win.show-setting" and "win.show-page". */
GtkWidget *zg_history_page_new(ZgModel *model);
/* Undo, redo, and the history button for the dock of the preview, with
 * the list in a popover on the button. */
GtkWidget *zg_history_tools_new(ZgModel *model);
/* Opens the list of the changes over the button (open), or opens or
 * closes it (the other state). */
void zg_history_tools_toggle(GtkWidget *tools, gboolean open);
/* An open or a save: the count on the button starts again. */
void zg_history_tools_mark_saved(GtkWidget *tools);
