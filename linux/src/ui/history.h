/* history.h: the history of changes, in two views.
 *
 * The History page (a tab of the settings panel) lists each step, the
 * newest first, with its time and its changes in words. A click on a step
 * goes to it, and the preview slices at that step. Each change has an undo
 * button that undoes only that change and keeps the later ones.
 *
 * The timeline is a bar under the preview, as the timeline of Fusion: one
 * mark for each step, the oldest at the left. A mark shows its changes when
 * the pointer is on it, and a click goes to its step.
 *
 * The steps are the steps of undo and redo (zg_model_history_*).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include "../model/app-model.h"

#include <gtk/gtk.h>

GtkWidget *zg_history_page_new(ZgModel *model);
GtkWidget *zg_timeline_new(ZgModel *model);
