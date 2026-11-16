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
 * Saved state: the machine, filament, and project settings that differ
 * from the defaults are in <config>/zslice/{machine,filament,project}.toml
 * (zs_app_state_write). The model loads them at the start, and saves a
 * group 0.5 s after a change of one of its settings, and at the end.
 * ZSLICE_STATE_DIR moves the folder (for tests).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "app-model.h"

#include <errno.h>
#include <string.h>

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
    int anchor_feature;
    guint32 focus;
    gboolean focus_first;
    /* A setting changed while a slice ran: slice again when it ends. */
    gboolean slice_pending;
    /* The scope of the inspector edits (see zg_model_set_scope). */
    gboolean scope_on;
    double scope_min, scope_max, scope_show;
    /* The time of the last slice request, and of the last slice (ms). */
    gint64 slice_start;
    double slice_ms;
    /* The groups to save (a bit for each enum zs_group), and the timer. */
    guint dirty;
    guint save_timer;
};

static const char *group_files[] = {"machine", "filament", "project"};

/* Starts a slice, and notes the time for the slice time in the status bar. */
static int request_slice(ZgModel *self) {
    self->slice_start = g_get_monotonic_time();
    return zs_app_request_slice(self->core);
}

static char *state_path(int group) {
    const char *dir = g_getenv("ZSLICE_STATE_DIR");
    char *file = g_strconcat(group_files[group], ".toml", NULL);
    char *path = dir ? g_build_filename(dir, file, NULL) : g_build_filename(g_get_user_config_dir(), "zslice", file, NULL);
    g_free(file);
    return path;
}

static void save_state(ZgModel *self) {
    for (int g = 0; g < 3; g++) {
        if (!(self->dirty & (1u << g))) continue;
        size_t len = 0;
        if (zs_app_state_write(self->core, g, NULL, 0, &len) != ZS_OK) continue;
        char *text = g_malloc(len + 1);
        zs_app_state_write(self->core, g, text, len + 1, NULL);
        char *path = state_path(g);
        char *dir = g_path_get_dirname(path);
        GError *error = NULL;
        /* g_file_set_contents writes a new file and renames it: a crash
         * leaves the old file or the new file, never half of one. */
        if (g_mkdir_with_parents(dir, 0700) != 0 || !g_file_set_contents(path, text, (gssize)len, &error)) {
            g_warning("zslice: the settings were not saved to %s: %s", path, error ? error->message : g_strerror(errno));
            g_clear_error(&error);
        }
        g_free(dir);
        g_free(path);
        g_free(text);
    }
    self->dirty = 0;
}

static gboolean on_save_timer(gpointer data) {
    ZgModel *self = data;
    self->save_timer = 0;
    save_state(self);
    return G_SOURCE_REMOVE;
}

static void load_state(ZgModel *self) {
    for (int g = 0; g < 3; g++) {
        char *path = state_path(g);
        char *text = NULL;
        gsize len = 0;
        if (g_file_get_contents(path, &text, &len, NULL)) {
            char message[256] = "";
            int rc = zs_app_profile_apply(self->core, g, text, len, message, sizeof message);
            if (rc != ZS_OK) {
                /* Keep the file: the next save writes over it. */
                char *bad = g_strconcat(path, ".bad", NULL);
                g_file_set_contents(bad, text, (gssize)len, NULL);
                g_warning("zslice: %s was not loaded (%s). A copy is in %s.", path, message, bad);
                g_free(bad);
            }
            g_free(text);
        }
        g_free(path);
    }
}

G_DEFINE_FINAL_TYPE(ZgModel, zg_model, G_TYPE_OBJECT)

enum { SIGNAL_CORE_EVENT, SIGNAL_SELECTION_CHANGED, SIGNAL_PICKED, SIGNAL_SETTING_CHANGED, SIGNAL_FOCUS_CHANGED, SIGNAL_SCOPE_CHANGED, N_SIGNALS };
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
        if (p->event == ZS_EVENT_SLICED && model->slice_start) {
            model->slice_ms = (g_get_monotonic_time() - model->slice_start) / 1000.0;
        }
        if (p->event == ZS_EVENT_SLICED && model->anchored) {
            size_t path = zs_app_pick_layer(model->core, model->anchor_layer, model->anchor_x, model->anchor_y);
            /* The line moved (for example a new skirt distance): the
             * nearest line of the same kind on the same layer. */
            zs_toolpaths tp;
            if (zs_app_toolpaths(model->core, &tp) == ZS_OK &&
                (path == (size_t)-1 || tp.path_features[path] != model->anchor_feature)) {
                path = zs_app_pick_feature(model->core, model->anchor_layer, model->anchor_feature, model->anchor_x, model->anchor_y);
            }
            model->selected = path == (size_t)-1 ? -1 : (gint64)path;
            if (model->selected < 0) model->anchored = FALSE;
            g_signal_emit(model, signals[SIGNAL_SELECTION_CHANGED], 0, model->selected);
        }
        g_signal_emit(model, signals[SIGNAL_CORE_EVENT], 0, p->event, p->progress, p->status);
        /* The slice for the newest settings. */
        if (p->event != ZS_EVENT_PROGRESS && model->slice_pending && zs_app_state(model->core) != ZS_STATE_SLICING) {
            model->slice_pending = FALSE;
            request_slice(model);
        }
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
    if (self->save_timer) {
        g_source_remove(self->save_timer);
        self->save_timer = 0;
    }
    if (self->core && self->dirty) save_state(self);
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
    /* scope-changed(): see zg_model_set_scope. */
    signals[SIGNAL_SCOPE_CHANGED] = g_signal_new("scope-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
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
        self->anchor_feature = tp.path_features[path];
    }
    g_signal_emit(self, signals[SIGNAL_SELECTION_CHANGED], 0, path);
    g_signal_emit(self, signals[SIGNAL_PICKED], 0, path);
}

void zg_model_set_scope(ZgModel *self, gboolean on, double z_min, double z_max, double z_show) {
    if (self->scope_on == on && self->scope_min == z_min && self->scope_max == z_max && self->scope_show == z_show) return;
    self->scope_on = on;
    self->scope_min = z_min;
    self->scope_max = z_max;
    self->scope_show = z_show;
    g_signal_emit(self, signals[SIGNAL_SCOPE_CHANGED], 0);
}

gboolean zg_model_scope(ZgModel *self, double *z_min, double *z_max, double *z_show) {
    if (z_min) *z_min = self->scope_min;
    if (z_max) *z_max = self->scope_max;
    if (z_show) *z_show = self->scope_show;
    return self->scope_on;
}

char *zg_model_get_for(ZgModel *self, const char *key, gboolean scoped) {
    if (!scoped || !self->scope_on) return zg_model_get(self, key);
    size_t len = 0;
    if (zs_app_setting_get_at(self->core, self->scope_show, key, NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *buf = g_malloc(len + 1);
    zs_app_setting_get_at(self->core, self->scope_show, key, buf, len + 1, NULL);
    return buf;
}

static gboolean fail(GError **error, int rc);

static void slice_soon(ZgModel *self) {
    int state = zs_app_state(self->core);
    if (state == ZS_STATE_SLICING) self->slice_pending = TRUE;
    else if (state != ZS_STATE_EMPTY) request_slice(self);
}

gboolean zg_model_set_for(ZgModel *self, const char *key, const char *value, gboolean scoped, GError **error) {
    zs_setting_info info;
    gboolean per_layer = FALSE;
    for (size_t i = 0; i < zs_setting_count(); i++) {
        if (zs_setting_get_info(i, &info) == ZS_OK && strcmp(info.name, key) == 0) {
            per_layer = info.per_layer;
            break;
        }
    }
    if (!scoped || !self->scope_on || !per_layer) return zg_model_set(self, key, value, error);
    int rc = zs_app_override_set(self->core, self->scope_min, self->scope_max, key, value);
    if (rc != ZS_OK) return fail(error, rc);
    g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, key);
    slice_soon(self);
    return TRUE;
}

gboolean zg_model_overridden(ZgModel *self, const char *key) {
    return self->scope_on && zs_app_override_at(self->core, self->scope_show, key);
}

void zg_model_clear_override(ZgModel *self, const char *key) {
    if (zs_app_override_clear_at(self->core, self->scope_show, key) == 0) return;
    g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, key);
    slice_soon(self);
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

double zg_model_slice_ms(ZgModel *self) {
    return self->slice_ms;
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
    load_state(self);
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
    rc = request_slice(self);
    if (rc != ZS_OK) return fail(error, rc);
    return TRUE;
}

gboolean zg_model_set(ZgModel *self, const char *key, const char *value, GError **error) {
    int rc = zs_app_setting_set(self->core, key, value);
    if (rc != ZS_OK) return fail(error, rc);
    g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, key);
    /* Save the group of the setting soon. */
    for (int g = 0; g < 3; g++) {
        size_t n = strlen(group_files[g]);
        if (strncmp(key, group_files[g], n) == 0 && key[n] == '.') self->dirty |= 1u << g;
    }
    if (self->dirty) {
        if (self->save_timer) g_source_remove(self->save_timer);
        self->save_timer = g_timeout_add(500, on_save_timer, self);
    }
    int state = zs_app_state(self->core);
    if (state == ZS_STATE_SLICING) {
        /* Let the running slice end and show, then slice the newest
         * settings. A stop and a restart for each change of a fast drag
         * would show nothing until the drag ends. */
        self->slice_pending = TRUE;
    } else if (state != ZS_STATE_EMPTY) {
        rc = request_slice(self);
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
