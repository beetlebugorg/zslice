/* inspector.h: the "Selected" page of the settings panel.
 *
 * A click on a line in a preview selects it (the "picked" signal of the
 * model), and the page shows what the line is: its speed and flow, the
 * reasons for them, and a compact row for each setting that changes it
 * (see setting-row.h), in sections. The edits of the page are for the
 * loaded part only: for all its layers, or for the layers of the line
 * ("Change for"). A Ctrl+click on a part shows the part page instead
 * (see part-page.h).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

/* A new page. `panel_stack` is the page stack of the panel: a click on a
 * line shows this page in it. */
GtkWidget *zg_inspector_new(ZgModel *model, GtkWidget *panel_stack);
