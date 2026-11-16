/* app-model.h: the app core as a GObject.
 *
 * ZgModel owns the zs_app of the core. The core sends its events from a
 * worker thread. ZgModel moves each event to the GTK main thread and emits
 * the "core-event" signal there, so that the UI code runs on one thread
 * only.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "zslice-app.h"

G_BEGIN_DECLS

#define ZG_TYPE_MODEL (zg_model_get_type())
G_DECLARE_FINAL_TYPE(ZgModel, zg_model, ZG, MODEL, GObject)

ZgModel *zg_model_new(void);

/* The core. Call it only from the main thread. */
zs_app *zg_model_core(ZgModel *self);

/* The name of the loaded model file, or NULL. */
const char *zg_model_name(ZgModel *self);

/* Loads an STL file from memory and starts a slice. */
gboolean zg_model_load(ZgModel *self, const char *name, const void *data, gsize len, GError **error);

/* Sets a setting and starts a new slice. */
gboolean zg_model_set(ZgModel *self, const char *key, const char *value, GError **error);

/* Gets a setting as text. Free the result with g_free. */
char *zg_model_get(ZgModel *self, const char *key);

/* The selected path (an index into zs_app_toolpaths), or -1. A new slice
 * clears it. "selection-changed" follows each change. */
void zg_model_select(ZgModel *self, gint64 path);
gint64 zg_model_selected(ZgModel *self);

/* The text for a core status code. */
const char *zg_status_text(int status);

G_END_DECLS
