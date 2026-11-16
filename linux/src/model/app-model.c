/* app-model.c: see app-model.h.
 *
 * Event bridge: the core callback runs on the worker thread. It puts the
 * event in a heap block and queues it with g_idle_add. The idle handler
 * runs on the main thread and emits "core-event".
 *
 * The core keeps a pointer to a Bridge, not to the ZgModel: a queued event
 * can run after the model is gone. The bridge holds a weak reference to the
 * model, and each queued event holds a reference to the bridge.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "app-model.h"

typedef struct {
    GWeakRef model;
} Bridge;

struct _ZgModel {
    GObject parent;
    zs_app *core;
    Bridge *bridge;
    char *name;
    gint64 selected;
    /* The place of the selection (a layer and a point of the path), so
     * that a new slice can pick the path at the same place again. */
    gboolean anchored;
    size_t anchor_layer;
    double anchor_x, anchor_y;
    guint32 focus;
    gboolean focus_first;
};

G_DEFINE_FINAL_TYPE(ZgModel, zg_model, G_TYPE_OBJECT)

enum { SIGNAL_CORE_EVENT, SIGNAL_SELECTION_CHANGED, SIGNAL_PICKED, SIGNAL_SETTING_CHANGED, SIGNAL_FOCUS_CHANGED, N_SIGNALS };
static guint signals[N_SIGNALS];

typedef struct {
    Bridge *bridge;
    int event;
    double progress;
    int status;
} Pending;

static void bridge_clear(gpointer data) {
    Bridge *b = data;
    g_weak_ref_clear(&b->model);
}

static gboolean deliver(gpointer data) {
    Pending *p = data;
    ZgModel *model = g_weak_ref_get(&p->bridge->model);
    if (model) {
        /* A new slice has new paths: pick the path at the place of the old
         * selection again, so the inspector stays on the same line. */
        if (p->event == ZS_EVENT_SLICED && model->anchored) {
            size_t path = zs_app_pick_layer(model->core, model->anchor_layer, model->anchor_x, model->anchor_y);
            model->selected = path == (size_t)-1 ? -1 : (gint64)path;
            if (model->selected < 0) model->anchored = FALSE;
            g_signal_emit(model, signals[SIGNAL_SELECTION_CHANGED], 0, model->selected);
        }
        g_signal_emit(model, signals[SIGNAL_CORE_EVENT], 0, p->event, p->progress, p->status);
        g_object_unref(model);
    }
    g_atomic_rc_box_release_full(p->bridge, bridge_clear);
    g_free(p);
    return G_SOURCE_REMOVE;
}

/* Runs on the worker thread. */
static void on_core_event(void *user, int event, double progress, int status) {
    Pending *p = g_new(Pending, 1);
    p->bridge = g_atomic_rc_box_acquire(user);
    p->event = event;
    p->progress = progress;
    p->status = status;
    g_idle_add(deliver, p);
}

static void zg_model_dispose(GObject *object) {
    ZgModel *self = ZG_MODEL(object);
    if (self->core) {
        /* Stops and joins the worker, so no new events follow. */
        zs_app_free(self->core);
        self->core = NULL;
    }
    if (self->bridge) {
        g_weak_ref_set(&self->bridge->model, NULL);
        g_atomic_rc_box_release_full(self->bridge, bridge_clear);
        self->bridge = NULL;
    }
    g_clear_pointer(&self->name, g_free);
    G_OBJECT_CLASS(zg_model_parent_class)->dispose(object);
}

static void zg_model_class_init(ZgModelClass *klass) {
    G_OBJECT_CLASS(klass)->dispose = zg_model_dispose;
    /* core-event(int event, double progress, int status): see zs_app_event_fn. */
    signals[SIGNAL_CORE_EVENT] = g_signal_new("core-event", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 3,
        G_TYPE_INT, G_TYPE_DOUBLE, G_TYPE_INT);
    /* selection-changed(gint64 path) */
    signals[SIGNAL_SELECTION_CHANGED] = g_signal_new("selection-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT64);
    /* picked(gint64 path): after selection-changed, only for a selection by
     * the user (zg_model_select), not for the new pick after a slice. A
     * view can react to it (switch a tab, for example). */
    signals[SIGNAL_PICKED] = g_signal_new("picked", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT64);
    /* focus-changed(): see zg_model_set_focus. */
    signals[SIGNAL_FOCUS_CHANGED] = g_signal_new("focus-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* setting-changed(const char *key): after zg_model_set changes a value,
     * so that each editor of the setting shows the new value. */
    signals[SIGNAL_SETTING_CHANGED] = g_signal_new("setting-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
}

void zg_model_select(ZgModel *self, gint64 path) {
    self->selected = path;
    self->anchored = FALSE;
    zs_toolpaths tp;
    if (path >= 0 && zs_app_toolpaths(self->core, &tp) == ZS_OK && (size_t)path < tp.path_count) {
        uint32_t start = path == 0 ? 0 : tp.path_ends[path - 1];
        size_t layer = 0;
        while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path) layer++;
        self->anchored = TRUE;
        self->anchor_layer = layer;
        self->anchor_x = tp.points[2 * start];
        self->anchor_y = tp.points[2 * start + 1];
    }
    g_signal_emit(self, signals[SIGNAL_SELECTION_CHANGED], 0, path);
    g_signal_emit(self, signals[SIGNAL_PICKED], 0, path);
}

void zg_model_set_focus(ZgModel *self, guint32 features, gboolean first_layer_only) {
    first_layer_only = features != 0 && first_layer_only;
    if (self->focus == features && self->focus_first == first_layer_only) return;
    self->focus = features;
    self->focus_first = first_layer_only;
    g_signal_emit(self, signals[SIGNAL_FOCUS_CHANGED], 0);
}

guint32 zg_model_focus(ZgModel *self, gboolean *first_layer_only) {
    if (first_layer_only) *first_layer_only = self->focus_first;
    return self->focus;
}

gint64 zg_model_selected(ZgModel *self) {
    return self->selected;
}

static void zg_model_init(ZgModel *self) {
    self->selected = -1;
    self->bridge = g_atomic_rc_box_new0(Bridge);
    g_weak_ref_init(&self->bridge->model, self);
    int rc = zs_app_new(on_core_event, self->bridge, &self->core);
    if (rc != ZS_OK) g_error("zslice: the app core did not start: %s", zg_status_text(rc));
}

ZgModel *zg_model_new(void) {
    return g_object_new(ZG_TYPE_MODEL, NULL);
}

zs_app *zg_model_core(ZgModel *self) {
    return self->core;
}

const char *zg_model_name(ZgModel *self) {
    return self->name;
}

static gboolean fail(GError **error, int rc) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s", zg_status_text(rc));
    return FALSE;
}

gboolean zg_model_load(ZgModel *self, const char *name, const void *data, gsize len, GError **error) {
    int rc = zs_app_load_stl(self->core, name, data, len);
    if (rc != ZS_OK) return fail(error, rc);
    g_free(self->name);
    self->name = g_strdup(name);
    rc = zs_app_request_slice(self->core);
    if (rc != ZS_OK) return fail(error, rc);
    return TRUE;
}

gboolean zg_model_set(ZgModel *self, const char *key, const char *value, GError **error) {
    int rc = zs_app_setting_set(self->core, key, value);
    if (rc != ZS_OK) return fail(error, rc);
    g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, key);
    if (zs_app_state(self->core) != ZS_STATE_EMPTY) {
        rc = zs_app_request_slice(self->core);
        if (rc != ZS_OK) return fail(error, rc);
    }
    return TRUE;
}

char *zg_model_get(ZgModel *self, const char *key) {
    size_t len = 0;
    if (zs_app_setting_get(self->core, key, NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *buf = g_malloc(len + 1);
    zs_app_setting_get(self->core, key, buf, len + 1, NULL);
    return buf;
}

const char *zg_status_text(int status) {
    switch (status) {
    case ZS_OK: return "OK";
    case ZS_OUT_OF_MEMORY: return "Out of memory";
    case ZS_INVALID_ARGUMENT: return "Invalid argument";
    case ZS_INVALID_MESH: return "The file is not a valid STL file";
    case ZS_EMPTY_MESH: return "The model has no triangles or no height";
    case ZS_UNKNOWN_SETTING: return "Unknown setting";
    case ZS_INVALID_VALUE: return "The value has the wrong type";
    case ZS_INVALID_SETTINGS: return "The settings cannot make a print";
    case ZS_PART_TOO_LARGE: return "The part is higher than the printer";
    case ZS_WRITE_FAILED: return "Write failed";
    case ZS_CANCELED: return "Canceled";
    case ZS_BUSY: return "A slice is running";
    case ZS_NO_MODEL: return "No model";
    case ZS_NO_RESULT: return "No slice result";
    case ZS_OUT_OF_RANGE: return "Out of range";
    default: return zs_status_string(status);
    }
}
