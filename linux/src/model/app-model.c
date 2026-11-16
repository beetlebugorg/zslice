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

#include <math.h>

#include "../prefs/printers.h"

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
    /* With a selected line: the other lines fade (see zg_model_set_isolate). */
    gboolean isolate;
    /* The selected segment of the selected line, or -1 (the whole line). */
    gint64 segment;
    /* The place of the selection (a layer and a point of the path), so
     * that a new slice can pick the path at the same place again. */
    gboolean anchored;
    size_t anchor_layer;
    double anchor_z; /* the nozzle z of the selected line, mm */
    double anchor_x, anchor_y;
    int anchor_feature;
    /* The other lines of a multiple selection (Shift+click), and their
     * anchors (the same as the anchor of the first line). */
    GArray *more;        /* gint64 */
    GArray *more_anchor; /* Anchor */
    guint32 focus;
    gboolean focus_first;
    /* A setting changed while a slice ran: slice again when it ends. */
    gboolean slice_pending;
    /* The scope of the inspector edits (see zg_model_set_scope). */
    gboolean scope_on;
    double scope_min, scope_max, scope_show;
    /* The selected part of the plate (Ctrl+click), or -1. */
    gint64 part;
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

/* The machine settings are the profile of the current printer; the
 * filament and the project settings are global files. */
static char *state_path(int group) {
    if (group == ZS_GROUP_MACHINE) return zg_printer_profile_path(zg_printers_current());
    char *dir = zg_config_dir();
    char *file = g_strconcat(group_files[group], ".toml", NULL);
    char *path = g_build_filename(dir, file, NULL);
    g_free(file);
    g_free(dir);
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

static void load_group(ZgModel *self, int g);

static void load_state(ZgModel *self) {
    zg_printers_load();
    for (int g = 0; g < 3; g++) load_group(self, g);
}

static void load_group(ZgModel *self, int g) {
    {
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

enum { SIGNAL_CORE_EVENT, SIGNAL_SELECTION_CHANGED, SIGNAL_PICKED, SIGNAL_SETTING_CHANGED, SIGNAL_FOCUS_CHANGED, SIGNAL_SCOPE_CHANGED, SIGNAL_PRINTER_CHANGED, SIGNAL_PRINTERS_EDITED, SIGNAL_PART_SELECTED, SIGNAL_PLATE_CHANGED, SIGNAL_SEGMENT_CHANGED, SIGNAL_PROFILES_CHANGED, SIGNAL_OPEN_PROFILE, N_SIGNALS };
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

/* The place of a selected line, to find it again after a slice. */
typedef struct {
    double z, x, y;
    int feature;
} Anchor;

static gboolean anchor_of(ZgModel *self, gint64 path, Anchor *a) {
    zs_toolpaths tp;
    if (path < 0 || zs_app_toolpaths(self->core, &tp) != ZS_OK || (size_t)path >= tp.path_count) return FALSE;
    uint32_t start = path == 0 ? 0 : tp.path_ends[path - 1];
    size_t layer = 0;
    while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path) layer++;
    a->z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
    a->x = tp.points[2 * start];
    a->y = tp.points[2 * start + 1];
    a->feature = tp.path_features[path];
    return TRUE;
}

/* The line at an anchor in the new slice, or -1. */
static gint64 find_anchor(ZgModel *self, const Anchor *a) {
    zs_toolpaths tp;
    if (zs_app_toolpaths(self->core, &tp) != ZS_OK || tp.layer_count == 0) return -1;
    size_t layer = 0;
    for (size_t l = 1; l < tp.layer_count; l++)
        if (fabs(tp.layer_z[l] - a->z) < fabs(tp.layer_z[layer] - a->z)) layer = l;
    size_t path = zs_app_pick_layer(self->core, layer, a->x, a->y);
    if (path == (size_t)-1 || tp.path_features[path] != a->feature) path = zs_app_pick_feature(self->core, layer, a->feature, a->x, a->y);
    return path == (size_t)-1 ? -1 : (gint64)path;
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
            /* The layer at the z of the selection: a new layer height
             * changes the layer numbers. */
            zs_toolpaths tz;
            if (zs_app_toolpaths(model->core, &tz) == ZS_OK && tz.layer_count > 0) {
                size_t best = 0;
                for (size_t l = 1; l < tz.layer_count; l++)
                    if (fabs(tz.layer_z[l] - model->anchor_z) < fabs(tz.layer_z[best] - model->anchor_z)) best = l;
                model->anchor_layer = best;
            }
            size_t path = zs_app_pick_layer(model->core, model->anchor_layer, model->anchor_x, model->anchor_y);
            /* The line moved (for example a new skirt distance): the
             * nearest line of the same kind on the same layer. */
            zs_toolpaths tp;
            if (zs_app_toolpaths(model->core, &tp) == ZS_OK &&
                (path == (size_t)-1 || tp.path_features[path] != model->anchor_feature)) {
                path = zs_app_pick_feature(model->core, model->anchor_layer, model->anchor_feature, model->anchor_x, model->anchor_y);
            }
            gint64 next = path == (size_t)-1 ? -1 : (gint64)path;
            /* The segment stays only on the same line. */
            if (next != model->selected) model->segment = -1;
            model->selected = next;
            /* No line of that kind there now (for example no skin at
             * this top thickness): the anchor stays, so the next slice
             * can find the line again, and the inspector keeps its page. */
            /* The other lines of a multiple selection, the same way. */
            if (model->more) {
                for (guint k = 0; k < model->more->len; k++) {
                    g_array_index(model->more, gint64, k) = find_anchor(model, &g_array_index(model->more_anchor, Anchor, k));
                }
            }
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
    if (self->more) g_array_free(self->more, TRUE);
    if (self->more_anchor) g_array_free(self->more_anchor, TRUE);
    self->more = self->more_anchor = NULL;
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
    /* segment-changed(gint64 segment): see zg_model_select_segment. */
    signals[SIGNAL_SEGMENT_CHANGED] = g_signal_new("segment-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT64);
    /* picked(gint64 path): after selection-changed, only for a selection by
     * the user (zg_model_select), not for the new pick after a slice. A
     * view can react to it (switch a tab, for example). */
    signals[SIGNAL_PICKED] = g_signal_new("picked", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT64);
    /* part-selected(gint64 part): see zg_model_select_part. */
    signals[SIGNAL_PART_SELECTED] = g_signal_new("part-selected", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT64);
    /* plate-changed(): a part was added, removed, moved, or turned. */
    signals[SIGNAL_PLATE_CHANGED] = g_signal_new("plate-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* printers-edited(): a printer was added, removed, or renamed. */
    signals[SIGNAL_PRINTERS_EDITED] = g_signal_new("printers-edited", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* printer-changed(): after zg_model_use_printer. */
    signals[SIGNAL_PRINTER_CHANGED] = g_signal_new("printer-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* scope-changed(): see zg_model_set_scope. */
    signals[SIGNAL_SCOPE_CHANGED] = g_signal_new("scope-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* focus-changed(): see zg_model_set_focus. */
    signals[SIGNAL_FOCUS_CHANGED] = g_signal_new("focus-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* profiles-changed(): after a change of the layer profiles or of the
     * overrides (zg_model_profile_*, a scoped edit, a reset). */
    signals[SIGNAL_PROFILES_CHANGED] = g_signal_new("profiles-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* open-profile(double z_min, double z_max): a request to edit the
     * layer profile of that range (zg_model_open_profile). */
    signals[SIGNAL_OPEN_PROFILE] = g_signal_new("open-profile", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 2, G_TYPE_DOUBLE, G_TYPE_DOUBLE);
    /* setting-changed(const char *key): after zg_model_set changes a value,
     * so that each editor of the setting shows the new value. */
    signals[SIGNAL_SETTING_CHANGED] = g_signal_new("setting-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
}

void zg_model_select(ZgModel *self, gint64 path) {
    if (self->more) g_array_set_size(self->more, 0);
    if (self->more_anchor) g_array_set_size(self->more_anchor, 0);
    self->selected = path;
    self->segment = -1;
    self->anchored = FALSE;
    zs_toolpaths tp;
    if (path >= 0 && zs_app_toolpaths(self->core, &tp) == ZS_OK && (size_t)path < tp.path_count) {
        uint32_t start = path == 0 ? 0 : tp.path_ends[path - 1];
        size_t layer = 0;
        while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path) layer++;
        self->anchored = TRUE;
        self->anchor_layer = layer;
        self->anchor_z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
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
    int rc = ZS_OK;
    guint n_more = self->more ? self->more->len : 0;
    if (n_more == 0) {
        rc = zs_app_override_set(self->core, self->scope_min, self->scope_max, key, value);
    } else {
        /* A multiple selection: the scope covers the layers of all lines.
         * This layer: each of their layers. And up, and down: from the
         * lowest or to the highest of them. */
        double lo = self->scope_min, hi = self->scope_max;
        gboolean up = hi > 1e5, down = lo < -1e5;
        double zmin = self->scope_show, zmax = self->scope_show;
        for (guint k = 0; k < n_more; k++) {
            double z = g_array_index(self->more_anchor, Anchor, k).z;
            zmin = MIN(zmin, z);
            zmax = MAX(zmax, z);
        }
        if (up && down) {
            /* The whole part: the same for one line or many. */
            rc = zs_app_override_set(self->core, lo, hi, key, value);
        } else if (up || down) {
            rc = zs_app_override_set(self->core, up ? zmin - 1e-3 : lo, down ? zmax + 1e-3 : hi, key, value);
        } else {
            rc = zs_app_override_set(self->core, lo, hi, key, value);
            for (guint k = 0; k < n_more && rc == ZS_OK; k++) {
                double z = g_array_index(self->more_anchor, Anchor, k).z;
                rc = zs_app_override_set(self->core, z - 1e-3, z + 1e-3, key, value);
            }
        }
    }
    if (rc != ZS_OK) return fail(error, rc);
    g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, key);
    g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
    slice_soon(self);
    return TRUE;
}

gboolean zg_model_overridden(ZgModel *self, const char *key) {
    return self->scope_on && zs_app_override_at(self->core, self->scope_show, key);
}

void zg_model_clear_override(ZgModel *self, const char *key) {
    /* The change for exactly the scope (a layer profile), else all the
     * changes that cover the selection. */
    if (!zs_app_override_remove(self->core, self->scope_min, self->scope_max, key) &&
        zs_app_override_clear_at(self->core, self->scope_show, key) == 0)
        return;
    g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, key);
    g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
    slice_soon(self);
}

void zg_model_profile_set(ZgModel *self, double z_min, double z_max, const char *name) {
    if (zs_app_profile_set(self->core, z_min, z_max, name) != ZS_OK) return;
    g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
}

void zg_model_open_profile(ZgModel *self, double z_min, double z_max) {
    g_signal_emit(self, signals[SIGNAL_OPEN_PROFILE], 0, z_min, z_max);
}

void zg_model_profile_remove(ZgModel *self, double z_min, double z_max) {
    /* The names of the changed settings, for their editors. */
    GPtrArray *names = g_ptr_array_new_with_free_func(g_free);
    size_t n = zs_app_override_count(self->core);
    for (size_t i = 0; i < n; i++) {
        zs_override o;
        if (zs_app_override_get(self->core, i, &o) == ZS_OK && fabs(o.z_min - z_min) < 1e-6 && fabs(o.z_max - z_max) < 1e-6)
            g_ptr_array_add(names, g_strndup(o.name, o.name_len));
    }
    size_t removed = zs_app_profile_remove(self->core, z_min, z_max);
    for (guint i = 0; i < names->len; i++) g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, (const char *)names->pdata[i]);
    g_ptr_array_free(names, TRUE);
    g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
    if (removed) slice_soon(self);
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

/* Tells each editor of a group that its value changed. */
void zg_model_announce(ZgModel *self, const char *prefix) {
    size_t n = zs_setting_count();
    for (size_t i = 0; i < n; i++) {
        zs_setting_info info;
        if (zs_setting_get_info(i, &info) == ZS_OK && g_str_has_prefix(info.name, prefix)) {
            g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], 0, info.name);
        }
    }
}

void zg_model_use_printer(ZgModel *self, const char *id) {
    ZgPrinter *cur = zg_printers_current();
    if (cur && strcmp(cur->id, id) == 0) return;
    /* Save the machine settings of the printer before. */
    self->dirty |= 1u << ZS_GROUP_MACHINE;
    save_state(self);
    zg_printers_set_current(id);
    zs_app_group_reset(self->core, ZS_GROUP_MACHINE);
    load_group(self, ZS_GROUP_MACHINE);
    zg_model_announce(self, "machine.");
    g_signal_emit(self, signals[SIGNAL_PRINTER_CHANGED], 0);
    slice_soon(self);
}

void zg_model_printers_edited(ZgModel *self) {
    g_signal_emit(self, signals[SIGNAL_PRINTERS_EDITED], 0);
}

void zg_model_save_soon(ZgModel *self, int group) {
    self->dirty |= 1u << group;
    if (self->save_timer) g_source_remove(self->save_timer);
    self->save_timer = g_timeout_add(500, on_save_timer, self);
}

double zg_model_slice_ms(ZgModel *self) {
    return self->slice_ms;
}

void zg_model_mark_add(ZgModel *self, double x, double y, double z, double r, int kind) {
    if (zs_app_mark_add(self->core, x, y, z, r, kind) == ZS_OK) request_slice(self);
}

size_t zg_model_mark_remove_near(ZgModel *self, double x, double y, double z, double r) {
    size_t n = zs_app_mark_remove_near(self->core, x, y, z, r);
    if (n > 0) request_slice(self);
    return n;
}

void zg_model_marks_clear(ZgModel *self) {
    if (zs_app_mark_count(self->core) == 0) return;
    zs_app_marks_clear(self->core);
    request_slice(self);
}

void zg_model_toggle_more(ZgModel *self, gint64 path) {
    if (path < 0) return;
    if (self->selected < 0) {
        zg_model_select(self, path);
        return;
    }
    if (!self->more) {
        self->more = g_array_new(FALSE, FALSE, sizeof(gint64));
        self->more_anchor = g_array_new(FALSE, FALSE, sizeof(Anchor));
    }
    /* The first line again: the next line becomes the first. */
    if (path == self->selected) {
        if (self->more->len == 0) return;
        gint64 next = g_array_index(self->more, gint64, 0);
        GArray *rest = g_array_new(FALSE, FALSE, sizeof(gint64));
        GArray *rest_a = g_array_new(FALSE, FALSE, sizeof(Anchor));
        g_array_append_vals(rest, self->more->data ? (gint64 *)self->more->data + 1 : NULL, self->more->len - 1);
        g_array_append_vals(rest_a, (Anchor *)self->more_anchor->data + 1, self->more_anchor->len - 1);
        zg_model_select(self, next);
        g_array_append_vals(self->more, rest->data, rest->len);
        g_array_append_vals(self->more_anchor, rest_a->data, rest_a->len);
        g_array_free(rest, TRUE);
        g_array_free(rest_a, TRUE);
        g_signal_emit(self, signals[SIGNAL_SELECTION_CHANGED], 0, self->selected);
        return;
    }
    for (guint k = 0; k < self->more->len; k++) {
        if (g_array_index(self->more, gint64, k) == path) {
            g_array_remove_index(self->more, k);
            g_array_remove_index(self->more_anchor, k);
            g_signal_emit(self, signals[SIGNAL_SELECTION_CHANGED], 0, self->selected);
            return;
        }
    }
    Anchor a;
    if (!anchor_of(self, path, &a)) return;
    g_array_append_val(self->more, path);
    g_array_append_val(self->more_anchor, a);
    g_signal_emit(self, signals[SIGNAL_SELECTION_CHANGED], 0, self->selected);
}

const gint64 *zg_model_more(ZgModel *self, guint *n) {
    *n = self->more ? self->more->len : 0;
    return self->more ? (const gint64 *)self->more->data : NULL;
}

gboolean zg_model_selection_lost(ZgModel *self) {
    return self->selected < 0 && self->anchored;
}

gint64 zg_model_selected(ZgModel *self) {
    return self->selected;
}

void zg_model_select_segment(ZgModel *self, gint64 path, gint64 segment) {
    /* A new line: the full selection first (the inspector follows it). */
    if (path != self->selected) zg_model_select(self, path);
    self->segment = path >= 0 ? segment : -1;
    g_signal_emit(self, signals[SIGNAL_SEGMENT_CHANGED], 0, self->segment);
}

gint64 zg_model_segment(ZgModel *self) {
    return self->segment;
}

void zg_model_set_isolate(ZgModel *self, gboolean on) {
    if (self->isolate == on) return;
    self->isolate = on;
    /* The previews read the flag when the selection changes. */
    g_signal_emit(self, signals[SIGNAL_SELECTION_CHANGED], 0, self->selected);
}

gboolean zg_model_isolate(ZgModel *self) {
    return self->isolate;
}

static void zg_model_init(ZgModel *self) {
    self->selected = -1;
    self->segment = -1;
    self->part = -1;
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

/* The name for the title: the first part, and how many more. */
static void update_name(ZgModel *self) {
    g_free(self->name);
    self->name = NULL;
    size_t n = zs_app_part_count(self->core);
    zs_part p;
    if (n == 0 || zs_app_part_get(self->core, 0, &p) != ZS_OK) return;
    self->name = n == 1 ? g_strdup(p.name) : g_strdup_printf("%s and %zu more", p.name, n - 1);
}

static void plate_changed(ZgModel *self) {
    update_name(self);
    if ((size_t)self->part >= zs_app_part_count(self->core)) zg_model_select_part(self, -1);
    g_signal_emit(self, signals[SIGNAL_PLATE_CHANGED], 0);
    if (zs_app_part_count(self->core) > 0) slice_soon(self);
}

gboolean zg_model_load(ZgModel *self, const char *name, const void *data, gsize len, GError **error) {
    int rc = zs_app_load_stl(self->core, name, data, len);
    if (rc != ZS_OK) return fail(error, rc);
    zg_model_select_part(self, -1);
    update_name(self);
    g_signal_emit(self, signals[SIGNAL_PLATE_CHANGED], 0);
    rc = request_slice(self);
    if (rc != ZS_OK) return fail(error, rc);
    return TRUE;
}

gboolean zg_model_add(ZgModel *self, const char *name, const void *data, gsize len, GError **error) {
    if (zs_app_part_count(self->core) == 0) return zg_model_load(self, name, data, len, error);
    ptrdiff_t i = zs_app_add_stl(self->core, name, data, len);
    if (i < 0) return fail(error, (int)-i);
    plate_changed(self);
    return TRUE;
}

void zg_model_select_part(ZgModel *self, gint64 part) {
    if (self->part == part) return;
    /* A part, or a line: not both. The line goes first, so the part page
     * comes after it. */
    if (part >= 0 && self->selected >= 0) zg_model_select(self, -1);
    self->part = part;
    g_signal_emit(self, signals[SIGNAL_PART_SELECTED], 0, part);
}

gint64 zg_model_selected_part(ZgModel *self) {
    return self->part;
}

void zg_model_part_move(ZgModel *self, size_t i, double x, double y) {
    if (zs_app_part_move(self->core, i, x, y) == ZS_OK) plate_changed(self);
}

void zg_model_part_scale(ZgModel *self, size_t i, double s) {
    if (zs_app_part_scale(self->core, i, s, s, s) == ZS_OK) plate_changed(self);
}

void zg_model_part_turn(ZgModel *self, size_t i, int axis, double degrees) {
    if (zs_app_part_turn(self->core, i, axis, degrees) == ZS_OK) plate_changed(self);
}

void zg_model_part_put_down_at(ZgModel *self, size_t i, double x, double y, double z) {
    if (zs_app_part_put_down_at(self->core, i, x, y, z) == ZS_OK) plate_changed(self);
}

void zg_model_part_place(ZgModel *self, size_t i, int mode, int axis) {
    if (zs_app_part_place(self->core, i, mode, axis) == ZS_OK) plate_changed(self);
}

void zg_model_part_reset(ZgModel *self, size_t i) {
    if (zs_app_part_reset(self->core, i) == ZS_OK) plate_changed(self);
}

/* Plates: a switch clears the selection, and slices the new plate. */
void zg_model_plate_select(ZgModel *self, size_t i) {
    if (i == zs_app_plate_active(self->core)) return;
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    if (zs_app_plate_select(self->core, i) != ZS_OK) return;
    plate_changed(self);
    g_signal_emit(self, signals[SIGNAL_CORE_EVENT], 0, ZS_EVENT_CANCELED, 0.0, 0);
}

void zg_model_plate_add(ZgModel *self) {
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    if (zs_app_plate_add(self->core) < 0) return;
    plate_changed(self);
    g_signal_emit(self, signals[SIGNAL_CORE_EVENT], 0, ZS_EVENT_CANCELED, 0.0, 0);
}

void zg_model_plate_remove(ZgModel *self, size_t i) {
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    if (zs_app_plate_remove(self->core, i) != ZS_OK) return;
    plate_changed(self);
    g_signal_emit(self, signals[SIGNAL_CORE_EVENT], 0, ZS_EVENT_CANCELED, 0.0, 0);
}

gboolean zg_model_plate_smart_place(ZgModel *self) {
    int ok = zs_app_plate_smart_place(self->core);
    plate_changed(self);
    return ok;
}

void zg_model_part_rotate(ZgModel *self, size_t i, double degrees) {
    if (zs_app_part_rotate(self->core, i, degrees) == ZS_OK) plate_changed(self);
}

void zg_model_part_remove(ZgModel *self, size_t i) {
    if (zs_app_part_remove(self->core, i) != ZS_OK) return;
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    plate_changed(self);
}

gboolean zg_model_plate_arrange(ZgModel *self) {
    int ok = zs_app_plate_arrange(self->core);
    plate_changed(self);
    return ok;
}

void zg_model_plate_clear(ZgModel *self) {
    zs_app_plate_clear(self->core);
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    plate_changed(self);
    g_signal_emit(self, signals[SIGNAL_CORE_EVENT], 0, ZS_EVENT_CANCELED, 0.0, 0);
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
    case ZS_PART_TOO_THIN: return "The part is lower than half of the first layer, so no layer cuts it";
    case ZS_WRITE_FAILED: return "Write failed";
    case ZS_CANCELED: return "Canceled";
    case ZS_BUSY: return "A slice is running";
    case ZS_NO_MODEL: return "No model";
    case ZS_NO_RESULT: return "No slice result";
    case ZS_OUT_OF_RANGE: return "Out of range";
    default: return zs_status_string(status);
    }
}
