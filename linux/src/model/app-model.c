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
    /* The gaps view (see zg_model_set_gaps), and the selected gap: its
     * layer and index, or -1. */
    gboolean gaps_on;
    gint64 gap_layer, gap_index;
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
    /* The roll of filament in the printer (see zg_model_set_roll): its
     * key, or NULL. The filament settings are saved for it too. */
    char *roll;
    /* Undo and redo of the settings: snapshots of the three groups (the
     * texts of zg_model_group_text, joined with \x1e). `undo_now` is the
     * state after the last step; a burst of changes (a drag) is one step. */
    GPtrArray *undo, *redo;
    char *undo_now;
    guint undo_timer;
    gboolean undo_restoring;
    /* The rolls of the current printer (zg_model_set_rolls). */
    ZgRoll *rolls;
    size_t n_rolls;
    char *rolls_printer;
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

/* The file of the filament settings of a roll, or NULL. */
static char *roll_path(const char *roll) {
    if (!roll) return NULL;
    char *dir = zg_config_dir();
    /* A key is letters, digits, and dashes (see zg_model_set_roll). */
    char *file = g_strconcat(roll, ".toml", NULL);
    char *path = g_build_filename(dir, "rolls", file, NULL);
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
        /* The filament settings: also for the roll in the printer. */
        char *roll_file = g == ZS_GROUP_FILAMENT ? roll_path(self->roll) : NULL;
        if (roll_file) {
            char *rdir = g_path_get_dirname(roll_file);
            if (g_mkdir_with_parents(rdir, 0700) != 0 || !g_file_set_contents(roll_file, text, (gssize)len, NULL))
                g_warning("zslice: the settings of the roll were not saved to %s", roll_file);
            g_free(rdir);
            g_free(roll_file);
        }
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

enum { SIGNAL_CORE_EVENT, SIGNAL_SELECTION_CHANGED, SIGNAL_PICKED, SIGNAL_SETTING_CHANGED, SIGNAL_FOCUS_CHANGED, SIGNAL_SCOPE_CHANGED, SIGNAL_PRINTER_CHANGED, SIGNAL_PRINTERS_EDITED, SIGNAL_PART_SELECTED, SIGNAL_PLATE_CHANGED, SIGNAL_SEGMENT_CHANGED, SIGNAL_PROFILES_CHANGED, SIGNAL_OPEN_PROFILE, SIGNAL_GAPS_CHANGED, SIGNAL_UNDO_CHANGED, N_SIGNALS };
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

static void rolls_clear(ZgModel *self);

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
    rolls_clear(self);
    if (self->undo_timer) g_source_remove(self->undo_timer);
    self->undo_timer = 0;
    g_clear_pointer(&self->undo, g_ptr_array_unref);
    g_clear_pointer(&self->redo, g_ptr_array_unref);
    g_clear_pointer(&self->undo_now, g_free);
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
    g_clear_pointer(&self->roll, g_free);
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
    /* gaps-changed(): the gaps view went on or off, or another gap is
     * selected (zg_model_set_gaps, zg_model_select_gap). */
    /* undo-changed(): a step went on the undo list, or an undo or a redo
     * ran (zg_model_undo). */
    signals[SIGNAL_UNDO_CHANGED] = g_signal_new("undo-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    signals[SIGNAL_GAPS_CHANGED] = g_signal_new("gaps-changed", G_TYPE_FROM_CLASS(klass),
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

void zg_model_filament_from_printer(ZgModel *self, const char *material, const char *name, double diameter, const char *color) {
    /* The diameter is a property of the printer: a switch of the material
     * keeps it, unless the printer tells another one. The built-in
     * profiles of the materials are for 1.75 mm. */
    if (diameter <= 0) {
        char *now = zg_model_get(self, "filament.diameter");
        diameter = now ? g_ascii_strtod(now, NULL) : 0;
        g_free(now);
    }
    /* The material picks the built-in base profile, if there is one. */
    if (material) {
        char *lower = g_ascii_strdown(material, -1);
        char *profile = g_strconcat("extends = \"generic-", lower, "\"\n", NULL);
        char message[200] = "";
        if (zs_app_profile_apply(self->core, ZS_GROUP_FILAMENT, profile, strlen(profile), message, sizeof message) != ZS_OK)
            g_message("zslice: no built-in profile for %s (%s)", material, message);
        g_free(profile);
        g_free(lower);
    }
    if (name) zg_model_set(self, "filament.name", name, NULL);
    else if (material) zg_model_set(self, "filament.name", material, NULL);
    if (material) {
        char *upper = g_ascii_strup(material, -1);
        zg_model_set(self, "filament.material", upper, NULL);
        g_free(upper);
    }
    if (diameter > 0) {
        char buf[G_ASCII_DTOSTR_BUF_SIZE];
        zg_model_set(self, "filament.diameter", g_ascii_dtostr(buf, sizeof buf, diameter), NULL);
    }
    if (color) zg_model_set(self, "filament.color", color, NULL);
    zg_model_announce(self, "filament.");
    zg_model_save_soon(self, ZS_GROUP_FILAMENT);
}

char *zg_model_roll_key(const char *printer, const char *roll_id) {
    GString *key = g_string_new(NULL);
    for (const char *c = printer ? printer : ""; *c; c++) g_string_append_c(key, g_ascii_isalnum(*c) ? *c : '-');
    g_string_append_c(key, '-');
    for (const char *c = roll_id ? roll_id : ""; *c; c++) g_string_append_c(key, g_ascii_isalnum(*c) ? *c : '-');
    return g_string_free(key, FALSE);
}

static void rolls_clear(ZgModel *self) {
    for (size_t i = 0; i < self->n_rolls; i++) {
        g_free(self->rolls[i].id);
        g_free(self->rolls[i].name);
        g_free(self->rolls[i].material);
        g_free(self->rolls[i].color);
    }
    g_clear_pointer(&self->rolls, g_free);
    self->n_rolls = 0;
    g_clear_pointer(&self->rolls_printer, g_free);
}

void zg_model_set_rolls(ZgModel *self, const char *printer, const ZgRoll *rolls, size_t n) {
    rolls_clear(self);
    self->rolls_printer = g_strdup(printer);
    self->rolls = g_new0(ZgRoll, MAX(n, 1));
    self->n_rolls = n;
    for (size_t i = 0; i < n; i++) {
        self->rolls[i].id = g_strdup(rolls[i].id);
        self->rolls[i].name = g_strdup(rolls[i].name);
        self->rolls[i].material = g_strdup(rolls[i].material);
        self->rolls[i].color = g_strdup(rolls[i].color);
        self->rolls[i].left = rolls[i].left;
    }
}

const ZgRoll *zg_model_rolls(ZgModel *self, size_t *n, const char **printer) {
    if (n) *n = self->n_rolls;
    if (printer) *printer = self->rolls_printer;
    return self->rolls;
}

void zg_model_use_roll(ZgModel *self, const ZgRoll *roll) {
    char *key = zg_model_roll_key(self->rolls_printer, roll->id);
    char *before = zg_model_get(self, "filament.material");
    if (!zg_model_set_roll(self, key)) {
        gboolean same = roll->material && before && g_ascii_strcasecmp(roll->material, before) == 0;
        zg_model_filament_from_printer(self, same ? NULL : roll->material, roll->name, 0, roll->color);
    }
    g_free(before);
    g_free(key);
}

gboolean zg_model_set_roll(ZgModel *self, const char *roll) {
    if (g_strcmp0(self->roll, roll) == 0) return TRUE;
    /* The settings of the roll before go to its file. */
    if (self->roll) {
        self->dirty |= 1u << ZS_GROUP_FILAMENT;
        save_state(self);
    }
    g_free(self->roll);
    self->roll = g_strdup(roll);
    char *path = roll_path(roll);
    char *text = NULL;
    gsize len = 0;
    gboolean known = path && g_file_get_contents(path, &text, &len, NULL);
    if (known) {
        char message[256] = "";
        zs_app_group_reset(self->core, ZS_GROUP_FILAMENT);
        if (zs_app_profile_apply(self->core, ZS_GROUP_FILAMENT, text, len, message, sizeof message) != ZS_OK) {
            g_warning("zslice: %s was not loaded (%s)", path, message);
            known = FALSE;
        } else {
            zg_model_announce(self, "filament.");
            self->dirty |= 1u << ZS_GROUP_FILAMENT;
            save_state(self);
            slice_soon(self);
        }
    }
    g_free(text);
    g_free(path);
    return known;
}

gboolean zg_model_load_profile(ZgModel *self, int group, const char *text, size_t len, GError **error) {
    /* Check the text on a copy first: an error leaves the settings as
     * they are (zs_app_profile_apply changes nothing on an error, but the
     * reset before it would). */
    size_t now_len = 0;
    char *now = NULL;
    if (zs_app_state_write(self->core, group, NULL, 0, &now_len) == ZS_OK) {
        now = g_malloc(now_len + 1);
        zs_app_state_write(self->core, group, now, now_len + 1, NULL);
    }
    zs_app_group_reset(self->core, group);
    char message[256] = "";
    if (zs_app_profile_apply(self->core, group, text, len, message, sizeof message) != ZS_OK) {
        if (now) zs_app_profile_apply(self->core, group, now, now_len, NULL, 0);
        g_free(now);
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "%s", message);
        return FALSE;
    }
    g_free(now);
    static const char *prefixes[] = {"machine.", "filament.", "project."};
    zg_model_announce(self, prefixes[group]);
    zg_model_save_soon(self, group);
    slice_soon(self);
    return TRUE;
}

char *zg_model_group_text(ZgModel *self, int group) {
    size_t len = 0;
    if (zs_app_state_write(self->core, group, NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *text = g_malloc(len + 1);
    zs_app_state_write(self->core, group, text, len + 1, NULL);
    return text;
}

char *zg_model_profile_text(ZgModel *self, int group) {
    size_t len = 0;
    if (zs_app_profile_write(self->core, group, NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *text = g_malloc(len + 1);
    zs_app_profile_write(self->core, group, text, len + 1, NULL);
    return text;
}

gboolean zg_model_set_quality(ZgModel *self, const char *name, gboolean keep_edits) {
    /* A profile of the user with this name, else the built-in profile. */
    char *dir = zg_config_dir();
    char *file = g_strconcat(name, ".toml", NULL);
    char *path = g_build_filename(dir, "profiles", "project", file, NULL);
    char *text = NULL;
    gsize len = 0;
    if (!g_file_get_contents(path, &text, &len, NULL)) {
        text = g_strdup_printf("extends = \"%s\"\n", name);
        len = strlen(text);
    }
    char message[256] = "";
    gboolean ok = zs_app_quality_set(self->core, name, text, len, keep_edits, message, sizeof message) == ZS_OK;
    if (!ok) g_warning("zslice: the quality profile %s was not loaded (%s)", name, message);
    g_free(text);
    g_free(path);
    g_free(file);
    g_free(dir);
    if (!ok) return FALSE;
    zg_pref_set("profile_project", name);
    zg_model_announce(self, "project.");
    zg_model_save_soon(self, ZS_GROUP_PROJECT);
    slice_soon(self);
    return TRUE;
}

const char *zg_model_quality(ZgModel *self) {
    return zs_app_quality_name(self->core);
}

const char *zg_model_roll(ZgModel *self) {
    return self->roll;
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

void zg_model_set_gaps(ZgModel *self, gboolean on) {
    if (self->gaps_on == on) return;
    self->gaps_on = on;
    if (!on) self->gap_layer = self->gap_index = -1;
    g_signal_emit(self, signals[SIGNAL_GAPS_CHANGED], 0);
}

gboolean zg_model_gaps(ZgModel *self) {
    return self->gaps_on;
}

void zg_model_select_gap(ZgModel *self, gint64 layer, gint64 index) {
    if (self->gap_layer == layer && self->gap_index == index) return;
    self->gap_layer = index < 0 ? -1 : layer;
    self->gap_index = index;
    g_signal_emit(self, signals[SIGNAL_GAPS_CHANGED], 0);
}

gint64 zg_model_selected_gap(ZgModel *self, gint64 *layer) {
    if (layer) *layer = self->gap_layer;
    return self->gap_index;
}

/* ---- undo and redo of the settings ---- */

enum { UNDO_MAX = 100 };

static char *undo_snapshot(ZgModel *self) {
    GString *s = g_string_new(NULL);
    for (int g = 0; g < 3; g++) {
        char *t = zg_model_group_text(self, g);
        if (g) g_string_append_c(s, '\x1e');
        g_string_append(s, t);
        g_free(t);
    }
    return g_string_free(s, FALSE);
}

/* Ends the step of the changes so far: the state before it goes on the
 * undo list. */
static void undo_commit(ZgModel *self) {
    if (self->undo_timer) {
        g_source_remove(self->undo_timer);
        self->undo_timer = 0;
    }
    char *now = undo_snapshot(self);
    if (self->undo_now && strcmp(now, self->undo_now) != 0) {
        g_ptr_array_add(self->undo, self->undo_now);
        if (self->undo->len > UNDO_MAX) g_ptr_array_remove_index(self->undo, 0);
        g_ptr_array_set_size(self->redo, 0);
        self->undo_now = now;
        g_signal_emit(self, signals[SIGNAL_UNDO_CHANGED], 0);
    } else {
        g_free(self->undo_now);
        self->undo_now = now;
    }
}

static gboolean on_undo_timer(gpointer data) {
    ZgModel *self = data;
    self->undo_timer = 0;
    undo_commit(self);
    return G_SOURCE_REMOVE;
}

static void on_undo_change(ZgModel *self, const char *key, gpointer data) {
    if (self->undo_restoring) return;
    if (self->undo_timer) g_source_remove(self->undo_timer);
    self->undo_timer = g_timeout_add(400, on_undo_timer, self);
}

/* Loads a snapshot: each group whose text differs. */
static void undo_restore(ZgModel *self, const char *snap) {
    char **parts = g_strsplit(snap, "\x1e", 3);
    self->undo_restoring = TRUE;
    for (int g = 0; g < 3 && parts[g]; g++) {
        char *now = zg_model_group_text(self, g);
        if (strcmp(now, parts[g]) != 0) {
            GError *error = NULL;
            if (!zg_model_load_profile(self, g, parts[g], strlen(parts[g]), &error)) {
                g_warning("zslice: undo: %s", error->message);
                g_error_free(error);
            }
        }
        g_free(now);
    }
    self->undo_restoring = FALSE;
    g_strfreev(parts);
}

static gboolean undo_move(ZgModel *self, GPtrArray *from, GPtrArray *to) {
    undo_commit(self);
    if (from->len == 0) return FALSE;
    char *snap = g_ptr_array_steal_index(from, from->len - 1);
    g_ptr_array_add(to, self->undo_now);
    self->undo_now = snap;
    undo_restore(self, snap);
    g_signal_emit(self, signals[SIGNAL_UNDO_CHANGED], 0);
    return TRUE;
}

gboolean zg_model_undo(ZgModel *self) {
    return undo_move(self, self->undo, self->redo);
}

gboolean zg_model_redo(ZgModel *self) {
    return undo_move(self, self->redo, self->undo);
}

gboolean zg_model_can_undo(ZgModel *self) {
    return self->undo->len > 0 || self->undo_timer != 0;
}

gboolean zg_model_can_redo(ZgModel *self) {
    return self->redo->len > 0 && self->undo_timer == 0;
}

static void zg_model_init(ZgModel *self) {
    self->selected = -1;
    self->segment = -1;
    self->gap_layer = self->gap_index = -1;
    self->part = -1;
    self->bridge = g_atomic_rc_box_new0(Bridge);
    g_weak_ref_init(&self->bridge->model, self);
    int rc = zs_app_new(on_core_event, self->bridge, &self->core);
    if (rc != ZS_OK) g_error("zslice: the app core did not start: %s", zg_status_text(rc));
    load_state(self);
    /* The quality profile of the last session, under the changes of this
     * print (the state of the project group). */
    char *quality = zg_pref_get("profile_project", "");
    if (quality[0] && strcmp(quality, "custom") != 0) {
        char *dir = zg_config_dir();
        char *file = g_strconcat(quality, ".toml", NULL);
        char *path = g_build_filename(dir, "profiles", "project", file, NULL);
        char *text = NULL;
        gsize len = 0;
        if (!g_file_get_contents(path, &text, &len, NULL)) {
            text = g_strdup_printf("extends = \"%s\"\n", quality);
            len = strlen(text);
        }
        char message[256] = "";
        if (zs_app_quality_set(self->core, quality, text, len, TRUE, message, sizeof message) != ZS_OK)
            g_message("zslice: the quality profile %s was not loaded (%s)", quality, message);
        g_free(text);
        g_free(path);
        g_free(file);
        g_free(dir);
    }
    g_free(quality);
    self->undo = g_ptr_array_new_with_free_func(g_free);
    self->redo = g_ptr_array_new_with_free_func(g_free);
    self->undo_now = undo_snapshot(self);
    g_signal_connect(self, "setting-changed", G_CALLBACK(on_undo_change), NULL);
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

gboolean zg_model_part_setting_set(ZgModel *self, size_t i, const char *name, const char *value) {
    if (zs_app_part_setting_set(self->core, i, name, value) != ZS_OK) return FALSE;
    plate_changed(self);
    return TRUE;
}

char *zg_model_part_setting(ZgModel *self, size_t i, const char *name) {
    size_t len = 0;
    if (zs_app_part_setting_get(self->core, i, name, NULL, 0, &len) != ZS_OK) return NULL;
    char *buf = g_malloc(len + 1);
    zs_app_part_setting_get(self->core, i, name, buf, len + 1, NULL);
    return buf;
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
