/* history.h: the history of changes, in two views.
 *
 * The History list (a popover over the dock at the bottom of the preview:
 * "History" in the dock, or History in the main menu) lists each step, the
 * newest first, with its time and its changes in words. A click on a step
 * goes to it, and the preview slices at that step. Each change has an undo
 * button that undoes only that change and keeps the later ones. A double
 * click on a change goes to it and opens its setting, to edit it.
 *
 * The timeline is the last group of the dock at the bottom of the preview
 * (zg_preview_set_timeline), as the timeline of Fusion: one mark for each
 * step, the oldest at the left. A mark shows its changes when
 * the pointer is on it, and a click goes to its step.
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
/* The timeline for the dock of the preview, with the list in a popover on
 * its "History" button. */
GtkWidget *zg_timeline_new(ZgModel *model);
/* Opens the list of the changes over the bar. */
void zg_timeline_show_history(GtkWidget *timeline);
