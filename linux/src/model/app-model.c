/* app-model.c: see app-model.h.
 *
 * Plates: the model has a plate set of the core (zs_set). Each plate has
 * its own app; `core` is the app of the active plate. The set slices the
 * other plates in the background. A change of a plate calls
 * zs_set_changed, and the set starts the slice.
 *
 * Event bridge: the core callback runs on a slice thread. It puts the
 * event in a heap block and queues it with g_idle_add. The idle handler
 * runs on the main thread and emits "core-event" for the events of the
 * active plate, and "plates-changed" for ZS_EVENT_PLATES.
 *
 * The core keeps a pointer to a Bridge, not to the ZgModel: a queued event
 * can run after the model is gone. The bridge holds a weak reference to the
 * model, and each queued event holds a reference to the bridge.
 *
 * Saved state: the machine, filament, and project settings that differ
 * from the defaults are in <config>/zslice/{machine,filament,project}.toml
 * (zs_app_state_write). The model loads them at the start, and saves a
 * group 0.5 s after a change of one of its settings, and at the end.
 * ZSLICE_STATE_DIR moves the folder (for tests). The machine settings are
 * in the profile of the current printer (printers/<id>.toml). The
 * filament settings are also in printers/<id>.filament.toml: a switch to
 * a printer loads the filament that it was last used with.
 *
 * Project mode: a plate of a printdeck.yml project is on the view
 * (zg_model_project_load). Its machine settings come from the Cura stack
 * of the project. The model does not save them in the profile of the
 * printer of the user, and does not save the filament settings for the
 * roll in the printer. A change of printer or a model file that the user
 * opens ends project mode (zg_model_project_end).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "app-model.h"

#include <math.h>

#include "../prefs/printers.h"

#include <errno.h>
#include <json-glib/json-glib.h>
#include <string.h>

typedef struct {
    GWeakRef model;
} Bridge;

struct _ZgModel {
    GObject parent;
    /* The plate set, and the app of its active plate. */
    zs_set *set;
    zs_app *core;
    /* A drag or a turn holds the slices: each change marks the plate, and
     * one slice starts at the release (zg_model_hold). */
    gboolean held;
    /* A part falls, or the hand holds it (zs_app_fall_step runs). */
    gboolean falling;
    /* The count of the changes of the plate (zg_model_edit_gen), the count
     * at the start of the last slice, and the count of the plate that the
     * last done slice shows. */
    gint64 edit_gen, slice_gen, shown_gen;
    /* The id of each plate in the store of the refinements (by plate). */
    GPtrArray *refine_ids;
    /* The tool of the preview (ZgTool), and the points of the measure tape
     * (x, y, z each). */
    int tool;
    int measure_n;
    double measure[6];
    /* For each point: the radius of the circle or the arc at it (the
     * point is its center), or 0. */
    double measure_r[2];
    int measure_shape[2];
    Bridge *bridge;
    char *name;
    gint64 selected;
    /* The key and the layer of the selected line, for an edit while a new
     * slice runs (zs_app_path_key). */
    uint64_t selected_key;
    size_t selected_layer;
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
    /* The selected part of the plate (Ctrl+click), or -1. Shift and a
     * click add parts: the other selected parts are in `parts_more`, and
     * `part` is the last one. `parts_all` is the list that zg_model_parts
     * returns. */
    gint64 part;
    GArray *parts_more, *parts_all;
    /* The roll of filament in the printer (see zg_model_set_roll): its
     * key, or NULL. The filament settings are saved for it too. */
    char *roll;
    /* The part whose settings the editors change, or -1 for the plate
     * (zg_model_set_part_scope). */
    gint64 part_scope;
    /* Undo and redo: the undo list is in the core (zs_app_history_*). The
     * model ends a step 400 ms after the last change (`undo_timer`), so a
     * burst of changes (a drag) is one step. `undo_restoring`: the model
     * updates its editors after an undo, and these signals start no step. */
    guint undo_timer;
    gboolean undo_restoring;
    /* TRUE while plate_switched emits the core-event of the new plate. */
    gboolean switching;
    /* The rolls of the current printer (zg_model_set_rolls). */
    ZgRoll *rolls;
    size_t n_rolls;
    char *rolls_printer;
    /* The time of the last slice request, and of the last slice (ms). */
    gint64 slice_start;
    double slice_ms;
    /* The draft slices (zs_app_set_draft): the app whose next slices are
     * drafts (or NULL), the timer of its exact slice, and the times of the
     * last draft and the last exact slice (ms). */
    zs_app *draft_core;
    guint settle_timer;
    double draft_ms;
    double exact_ms;
    /* The groups to save (a bit for each enum zs_group), and the timer. */
    guint dirty;
    guint save_timer;
    /* Project mode (see the header comment), and the title of the plate. */
    gboolean project;
    char *project_title;
};

static const char *group_files[] = {"machine", "filament", "project"};

/* The active plate changed: `core` is its app. */
static void sync_core(ZgModel *self) {
    self->core = zs_set_app(self->set, zs_set_active(self->set));
    /* The print as it forms after each slice, on the thread of the slice
     * (ZS_EVENT_SIMULATED). */
    zs_app_set_auto_simulate(self->core, 1);
    /* The check of the print for the hints, on the thread of the slice
     * (5 to 60 ms on the UI thread). */
    zs_app_set_auto_checks(self->core, 1);
    /* The scene of the 3D view of each slice and each simulated print, on
     * the thread of the slice: zs_view_load then only swaps it in (25 to
     * 110 ms on the UI thread). The other plates too: their scenes wait
     * for a switch, and their worker writes the scene bytes of the row of
     * plates (zs_set_view_sync). */
    for (size_t i = 0; i < zs_set_count(self->set); i++) zs_app_set_auto_scene(zs_set_app(self->set, i), 1);
}

/* The draft slices. A change of a plate that has a slice gives a draft
 * first (zs_app_set_draft: an outline tolerance of 0.05 mm and no gap
 * fill, in about a third of the time). The exact slice follows
 * ZG_SETTLE_MS after the last change, or at the end of a drag
 * (zg_model_hold). A plate with no slice yet (a new model) slices exact at
 * once. A draft has no G-code (zs_app_gcode), so the window keeps the
 * export and the numbers of the print until the exact slice. */
#define ZG_SETTLE_MS 300

/* The exact slice of the plate that has a draft. */
static void settle(ZgModel *self) {
    if (self->settle_timer) g_source_remove(self->settle_timer);
    self->settle_timer = 0;
    zs_app *app = self->draft_core;
    self->draft_core = NULL;
    if (!app) return;
    for (size_t i = 0; i < zs_set_count(self->set); i++) {
        if (zs_set_app(self->set, i) != app) continue;
        zs_app_set_draft(app, 0);
        if (i == zs_set_active(self->set)) {
            self->slice_start = g_get_monotonic_time();
            self->slice_gen = self->edit_gen;
        }
        zs_set_changed(self->set, i);
        return;
    }
}

static gboolean on_settle(gpointer data) {
    ZgModel *self = data;
    /* A draft that still runs: the exact slice waits for its result, so
     * that the view gets the draft. */
    if (self->draft_core && zs_app_state(self->draft_core) == ZS_STATE_SLICING) return G_SOURCE_CONTINUE;
    self->settle_timer = 0;
    settle(self);
    return G_SOURCE_REMOVE;
}

/* A change of the active plate: its next slice is a draft, if the plate
 * has a slice. */
static void live_change(ZgModel *self) {
    if (self->settle_timer) g_source_remove(self->settle_timer);
    self->settle_timer = 0;
    if (self->draft_core && self->draft_core != self->core) settle(self);
    int state = zs_app_state(self->core);
    if (!self->draft_core && (state == ZS_STATE_DONE || state == ZS_STATE_SLICING)) {
        self->draft_core = self->core;
        zs_app_set_draft(self->core, 1);
    }
    if (self->draft_core) self->settle_timer = g_timeout_add(ZG_SETTLE_MS, on_settle, self);
}

/* The active plate changed: the set starts its slice. Notes the time for
 * the slice time in the status bar. */
static int request_slice(ZgModel *self) {
    if (self->held) return zs_set_changed_held(self->set, zs_set_active(self->set));
    live_change(self);
    self->slice_start = g_get_monotonic_time();
    self->slice_gen = self->edit_gen;
    return zs_set_changed(self->set, zs_set_active(self->set));
}

static void undo_commit(ZgModel *self);
static void fall_check(ZgModel *self);

/* A slice during a drag (the support follows a tree edit live): the held
 * change slices now, and the step of the history stays open until the
 * release (zg_model_hold). */
void zg_model_slice_now(ZgModel *self) {
    if (!self->held) return;
    live_change(self);
    self->slice_start = g_get_monotonic_time();
    self->slice_gen = self->edit_gen;
    zs_set_release(self->set);
}

void zg_model_hold(ZgModel *self, gboolean hold) {
    if (self->held == hold) return;
    self->held = hold;
    if (!hold) {
        /* The end of a drag: the exact slice, with no draft before it. */
        settle(self);
        self->slice_start = g_get_monotonic_time();
        self->slice_gen = self->edit_gen;
        zs_set_release(self->set);
        /* The changes of the drag are one step. */
        if (zs_app_history_pending(self->core)) undo_commit(self);
        /* A turned part that cannot stand falls. */
        fall_check(self);
    }
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

/* The file of the filament settings that a printer was last used with:
 * printers/<id>.filament.toml, next to its profile. */
static char *printer_filament_path(const ZgPrinter *p) {
    char *profile = zg_printer_profile_path(p);
    if (g_str_has_suffix(profile, ".toml")) profile[strlen(profile) - 5] = '\0';
    char *path = g_strconcat(profile, ".filament.toml", NULL);
    g_free(profile);
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
    /* In project mode, the machine settings are of the project. */
    if (self->project) self->dirty &= ~(1u << ZS_GROUP_MACHINE);
    for (int g = 0; g < 3; g++) {
        if (!(self->dirty & (1u << g))) continue;
        size_t len = 0;
        if (zs_app_state_write(self->core, g, NULL, 0, &len) != ZS_OK) continue;
        char *text = g_malloc(len + 1);
        zs_app_state_write(self->core, g, text, len + 1, NULL);
        /* The filament settings: also for the roll in the printer, and
         * for the printer (it gets them back after a switch to it). */
        char *roll_file = g == ZS_GROUP_FILAMENT && !self->project ? roll_path(self->roll) : NULL;
        if (roll_file) {
            char *rdir = g_path_get_dirname(roll_file);
            if (g_mkdir_with_parents(rdir, 0700) != 0 || !g_file_set_contents(roll_file, text, (gssize)len, NULL))
                g_warning("zslice: the settings of the roll were not saved to %s", roll_file);
            g_free(rdir);
            g_free(roll_file);
        }
        if (g == ZS_GROUP_FILAMENT && !self->project) {
            char *pf = printer_filament_path(zg_printers_current());
            char *pdir = g_path_get_dirname(pf);
            if (g_mkdir_with_parents(pdir, 0700) != 0 || !g_file_set_contents(pf, text, (gssize)len, NULL))
                g_warning("zslice: the filament of the printer was not saved to %s", pf);
            g_free(pdir);
            g_free(pf);
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
    /* The formulas of the settings (any group): with each save. */
    if (self->dirty) {
        size_t len = 0;
        if (zs_app_formulas_write(self->core, NULL, 0, &len) == ZS_OK) {
            char *text = g_malloc(len + 1);
            zs_app_formulas_write(self->core, text, len + 1, NULL);
            char *dir = zg_config_dir();
            char *path = g_build_filename(dir, "formulas.txt", NULL);
            if (len > 0 || g_file_test(path, G_FILE_TEST_EXISTS)) g_file_set_contents(path, text, (gssize)len, NULL);
            g_free(path);
            g_free(dir);
            g_free(text);
        }
    }
    self->dirty = 0;
}

static gboolean on_save_timer(gpointer data) {
    ZgModel *self = data;
    self->save_timer = 0;
    save_state(self);
    return G_SOURCE_REMOVE;
}

static gboolean load_group(ZgModel *self, int g);

/* Loads the saved groups. Returns TRUE if a text has settings that moved
 * to another group (zs_profile_moved): the caller saves the groups again
 * after the start. */
static gboolean load_state(ZgModel *self) {
    zg_printers_load();
    gboolean moved = FALSE;
    for (int g = 0; g < 3; g++) moved |= load_group(self, g);
    return moved;
}

/* Loads the saved text of a group. Returns TRUE if the text has settings
 * that moved to another group. */
static gboolean load_group(ZgModel *self, int g) {
    gboolean moved = FALSE;
    {
        char *path = state_path(g);
        char *text = NULL;
        gsize len = 0;
        if (g_file_get_contents(path, &text, &len, NULL)) {
            moved = zs_profile_moved(g, text, len) > 0;
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
    return moved;
}

G_DEFINE_FINAL_TYPE(ZgModel, zg_model, G_TYPE_OBJECT)

enum { SIGNAL_PLATES_CHANGED, SIGNAL_PROJECT_CHANGED, SIGNAL_PROJECT_SENT, SIGNAL_CORE_EVENT, SIGNAL_SELECTION_CHANGED, SIGNAL_PICKED, SIGNAL_SETTING_CHANGED, SIGNAL_FOCUS_CHANGED, SIGNAL_SCOPE_CHANGED, SIGNAL_PRINTER_CHANGED, SIGNAL_PRINTERS_EDITED, SIGNAL_PART_SELECTED, SIGNAL_PLATE_CHANGED, SIGNAL_SEGMENT_CHANGED, SIGNAL_PROFILES_CHANGED, SIGNAL_OPEN_PROFILE, SIGNAL_GAPS_CHANGED, SIGNAL_UNDO_CHANGED, SIGNAL_PART_SCOPE_CHANGED, SIGNAL_TOOL_CHANGED, SIGNAL_MEASURE_CHANGED, SIGNAL_FALL, SIGNAL_FILAMENTS_CHANGED, N_SIGNALS };
static guint signals[N_SIGNALS];

/* "setting-changed" with the key as its detail. */
static void emit_setting(ZgModel *self, const char *key) {
    g_signal_emit(self, signals[SIGNAL_SETTING_CHANGED], g_quark_from_string(key), key);
}

typedef struct {
    Bridge *bridge;
    size_t plate;
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
    if (model && p->event == ZS_EVENT_PLATES) {
        g_signal_emit(model, signals[SIGNAL_PLATES_CHANGED], 0);
        g_object_unref(model);
        model = NULL;
    } else if (model && p->plate != zs_set_active(model->set)) {
        /* A slice of another plate: only its status shows. */
        g_object_unref(model);
        model = NULL;
    }
    if (model) {
        /* A new slice has new paths: pick the path at the place of the old
         * selection again, so the inspector stays on the same line. */
        if (p->event == ZS_EVENT_SLICED) model->shown_gen = model->slice_gen;
        if (p->event == ZS_EVENT_SLICED && model->slice_start) {
            model->slice_ms = (g_get_monotonic_time() - model->slice_start) / 1000.0;
            if (zs_app_is_draft(model->core)) model->draft_ms = model->slice_ms;
            else model->exact_ms = model->slice_ms;
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

/* Runs on a slice thread, or on the main thread in a zs_set call. */
static void on_core_event(void *user, size_t plate, int event, double progress, int status) {
    Pending *p = g_new(Pending, 1);
    p->bridge = g_atomic_rc_box_acquire(user);
    p->plate = plate;
    p->event = event;
    p->progress = progress;
    p->status = status;
    g_idle_add(deliver, p);
}

static void rolls_clear(ZgModel *self);

static void zg_model_dispose(GObject *object) {
    ZgModel *self = ZG_MODEL(object);
    if (self->settle_timer) g_source_remove(self->settle_timer);
    self->settle_timer = 0;
    if (self->more) g_array_free(self->more, TRUE);
    if (self->more_anchor) g_array_free(self->more_anchor, TRUE);
    self->more = self->more_anchor = NULL;
    if (self->parts_more) g_array_free(self->parts_more, TRUE);
    if (self->parts_all) g_array_free(self->parts_all, TRUE);
    self->parts_more = self->parts_all = NULL;
    if (self->save_timer) {
        g_source_remove(self->save_timer);
        self->save_timer = 0;
    }
    if (self->core && self->dirty) save_state(self);
    rolls_clear(self);
    if (self->undo_timer) g_source_remove(self->undo_timer);
    self->undo_timer = 0;
    if (self->set) {
        /* Stops and joins each slice, so no new events follow. */
        zs_set_free(self->set);
        self->set = NULL;
        self->core = NULL;
    }
    if (self->bridge) {
        g_weak_ref_set(&self->bridge->model, NULL);
        g_atomic_rc_box_release_full(self->bridge, bridge_clear);
        self->bridge = NULL;
    }
    g_clear_pointer(&self->name, g_free);
    g_clear_pointer(&self->project_title, g_free);
    g_clear_pointer(&self->roll, g_free);
    g_clear_pointer(&self->refine_ids, g_ptr_array_unref);
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
    /* plates-changed(): the list of the plates, the active plate, or a
     * status changed (zs_set). */
    signals[SIGNAL_PLATES_CHANGED] = g_signal_new("plates-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
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
    /* part-scope-changed(): the editors now change another part, or the
     * plate (zg_model_set_part_scope). */
    signals[SIGNAL_PART_SCOPE_CHANGED] = g_signal_new("part-scope-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    signals[SIGNAL_GAPS_CHANGED] = g_signal_new("gaps-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* open-profile(double z_min, double z_max): a request to edit the
     * layer profile of that range (zg_model_open_profile). */
    /* tool-changed(): see zg_model_set_tool. */
    signals[SIGNAL_TOOL_CHANGED] = g_signal_new("tool-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* measure-changed(): a point of the measure tape came or went. */
    signals[SIGNAL_MEASURE_CHANGED] = g_signal_new("measure-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    signals[SIGNAL_OPEN_PROFILE] = g_signal_new("open-profile", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 2, G_TYPE_DOUBLE, G_TYPE_DOUBLE);
    /* project-changed(): project mode went on or off. */
    signals[SIGNAL_PROJECT_CHANGED] = g_signal_new("project-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* project-sent(): the plate of a project went to a printer to print. */
    signals[SIGNAL_PROJECT_SENT] = g_signal_new("project-sent", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
    /* setting-changed(const char *key): after zg_model_set changes a value,
     * so that each editor of the setting shows the new value. The detail
     * is the key: an editor of one setting connects to
     * "setting-changed::<key>", so a switch of the plate (each setting
     * changes) calls each editor once, and not once for each setting. */
    signals[SIGNAL_SETTING_CHANGED] = g_signal_new("setting-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST | G_SIGNAL_DETAILED, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
    /* fall(gint64 part): the part cannot stand as it is now, and nothing
     * holds it (for example, support went off under a turned part). The
     * view shows its fall (zg_model_fall_start). */
    signals[SIGNAL_FALL] = g_signal_new("fall", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_INT64);
    /* filaments-changed(): a filament of the plate came, went, or got a
     * new value (zg_model_filament_add and the calls after it). */
    signals[SIGNAL_FILAMENTS_CHANGED] = g_signal_new("filaments-changed", G_TYPE_FROM_CLASS(klass),
        G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

void zg_model_select(ZgModel *self, gint64 path) {
    if (self->more) g_array_set_size(self->more, 0);
    if (self->more_anchor) g_array_set_size(self->more_anchor, 0);
    /* During a slice the key reads 0: the same line keeps its key. */
    uint64_t key = path >= 0 ? zs_app_path_key(self->core, (size_t)path) : 0;
    if (key || path != self->selected) {
        self->selected_key = key;
        ptrdiff_t sl = path >= 0 ? zs_app_path_layer(self->core, (size_t)path) : -1;
        self->selected_layer = sl > 0 ? (size_t)sl : 0;
    }
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

/* A setting that a part can have of its own: the project and the
 * filament settings, and the accelerations of the printer. */
static gboolean part_scoped(ZgModel *self, const char *key) {
    return self->part_scope >= 0 && zs_setting_is_part(key);
}

static void save_global(ZgModel *self) {
    size_t len = 0;
    if (zs_app_global_write(self->core, NULL, 0, &len) != ZS_OK) return;
    char *text = g_malloc(len + 1);
    zs_app_global_write(self->core, text, len + 1, NULL);
    char *dir = zg_config_dir();
    char *path = g_build_filename(dir, "global.toml", NULL);
    g_file_set_contents(path, text, (gssize)len, NULL);
    g_free(path);
    g_free(dir);
    g_free(text);
}

char *zg_model_get_for(ZgModel *self, const char *key, gboolean scoped) {
    if (self->part_scope == ZG_SCOPE_GLOBAL && g_str_has_prefix(key, "project.")) {
        size_t len = 0;
        if (zs_app_global_get(self->core, key, NULL, 0, &len) != ZS_OK) return g_strdup("");
        char *buf = g_malloc(len + 1);
        zs_app_global_get(self->core, key, buf, len + 1, NULL);
        return buf;
    }
    if ((!scoped || !self->scope_on) && part_scoped(self, key)) {
        char *mine = zg_model_part_setting(self, (size_t)self->part_scope, key);
        return mine ? mine : zg_model_get(self, key);
    }
    if (!scoped || !self->scope_on) return zg_model_get(self, key);
    size_t len = 0;
    if (zs_app_setting_get_at(self->core, self->scope_show, key, NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *buf = g_malloc(len + 1);
    zs_app_setting_get_at(self->core, self->scope_show, key, buf, len + 1, NULL);
    return buf;
}

static gboolean fail(GError **error, int rc);
static void plate_leave(ZgModel *self);
static void plate_switched(ZgModel *self);

/* A part that cannot stand, with nothing to hold it, falls. Not during
 * a drag or a fall: those end with this check. */
static void fall_check(ZgModel *self) {
    if (self->held || self->falling) return;
    ptrdiff_t k = zs_app_fall_pending(self->core);
    if (k >= 0) g_signal_emit(self, signals[SIGNAL_FALL], 0, (gint64)k);
}

/* A slice after a change of the plate. */
static void slice_plate_soon(ZgModel *self) {
    int state = zs_app_state(self->core);
    if (state == ZS_STATE_SLICING) self->slice_pending = TRUE;
    else if (state != ZS_STATE_EMPTY) request_slice(self);
}

/* A slice after a change of a setting: it can take away what held a
 * part. */
static void slice_soon(ZgModel *self) {
    fall_check(self);
    slice_plate_soon(self);
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
    if (self->part_scope == ZG_SCOPE_GLOBAL && g_str_has_prefix(key, "project.")) {
        int rc = zs_app_global_setting_set(self->core, key, value);
        if (rc != ZS_OK) return fail(error, rc);
        save_global(self);
        zg_model_announce(self, key);
        slice_soon(self);
        return TRUE;
    }
    if ((!scoped || !self->scope_on) && part_scoped(self, key)) {
        if (!zg_model_part_setting_set(self, (size_t)self->part_scope, key, value)) {
            g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "not a valid value");
            return FALSE;
        }
        emit_setting(self, key);
        return TRUE;
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
    emit_setting(self, key);
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
    emit_setting(self, key);
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
    for (guint i = 0; i < names->len; i++) emit_setting(self, (const char *)names->pdata[i]);
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
            emit_setting(self, info.name);
        }
    }
}

static void project_off(ZgModel *self);

void zg_model_use_printer(ZgModel *self, const char *id) {
    ZgPrinter *cur = zg_printers_current();
    if (cur && strcmp(cur->id, id) == 0 && !self->project) return;
    /* Save the machine settings of the printer before (save_state skips
     * them in project mode), and the filament that it used. */
    self->dirty |= 1u << ZS_GROUP_MACHINE;
    if (!self->project) self->dirty |= 1u << ZS_GROUP_FILAMENT;
    save_state(self);
    project_off(self);
    zg_printers_set_current(id);
    zs_app_group_reset(self->core, ZS_GROUP_MACHINE);
    load_group(self, ZS_GROUP_MACHINE);
    zg_model_announce(self, "machine.");
    /* The roll was in the printer before. The next poll of this printer
     * names its own roll, and the settings of that roll win. */
    g_clear_pointer(&self->roll, g_free);
    /* The filament that this printer was last used with. A printer with
     * no saved filament keeps the filament now. */
    char *pf = printer_filament_path(zg_printers_current());
    char *text = NULL;
    gsize len = 0;
    if (g_file_get_contents(pf, &text, &len, NULL)) {
        char *before = zg_model_group_text(self, ZS_GROUP_FILAMENT);
        zs_app_group_reset(self->core, ZS_GROUP_FILAMENT);
        char message[256] = "";
        if (zs_app_profile_apply(self->core, ZS_GROUP_FILAMENT, text, len, message, sizeof message) != ZS_OK) {
            g_warning("zslice: %s was not loaded (%s)", pf, message);
            zs_app_profile_apply(self->core, ZS_GROUP_FILAMENT, before, strlen(before), NULL, 0);
        }
        g_free(before);
        zg_model_announce(self, "filament.");
        zg_model_save_soon(self, ZS_GROUP_FILAMENT);
    }
    g_free(text);
    g_free(pf);
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

void zg_model_apply_printer_status(ZgModel *self, const zs_printer_status *status, int what) {
    if (!status || zs_app_apply_printer_status(self->core, status, what) != ZS_OK) return;
    if (what & 1) {
        zg_model_announce(self, "machine.");
        zg_model_save_soon(self, ZS_GROUP_MACHINE);
    }
    if (what & 2) {
        zg_model_announce(self, "filament.");
        zg_model_save_soon(self, ZS_GROUP_FILAMENT);
    }
    request_slice(self);
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

/* zg_model_load_profile with no slice. */
static gboolean apply_profile(ZgModel *self, int group, const char *text, size_t len, GError **error) {
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
    return TRUE;
}

gboolean zg_model_load_profile(ZgModel *self, int group, const char *text, size_t len, GError **error) {
    if (!apply_profile(self, group, text, len, error)) return FALSE;
    slice_soon(self);
    return TRUE;
}

static void undo_commit(ZgModel *self);

char *zg_model_import_profile(ZgModel *self, const char *name, const guint8 *bytes, size_t len, GError **error) {
    int rc = zs_app_profile_import(self->core, name, bytes, len);
    if (rc == ZS_INVALID_VALUE) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "The file is not a profile of PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura.");
        return NULL;
    }
    if (rc != ZS_OK) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The profile did not import (status %d).", rc);
        return NULL;
    }
    size_t n = 0;
    zs_app_profile_import_report(self->core, NULL, 0, &n);
    char *report = g_malloc(n + 1);
    zs_app_profile_import_report(self->core, report, n + 1, NULL);
    static const char *prefixes[] = {"machine.", "filament.", "project."};
    for (int g = 0; g < 3; g++) {
        zg_model_announce(self, prefixes[g]);
        zg_model_save_soon(self, g);
    }
    undo_commit(self);
    slice_soon(self);
    return report;
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
    static const char *const keys[] = {"project.filament", "project.support_filament", "project.support_interface_filament"};
    for (size_t k = 0; k < G_N_ELEMENTS(keys); k++) emit_setting(self, keys[k]);
    zg_model_save_soon(self, ZS_GROUP_PROJECT);
    slice_soon(self);
    return TRUE;
}

char *zg_model_source_text(ZgModel *self, const char *key, gint64 part, int *level_out) {
    int level = ZS_LEVEL_DEFAULT;
    /* A formula of this print: it says so. */
    char *formula = part < 0 ? zg_model_formula(self, key) : NULL;
    if (formula) {
        if (level_out) *level_out = ZS_LEVEL_PRINT;
        char *t = g_strdup_printf("= %s", formula);
        g_free(formula);
        return t;
    }
    char profile[256] = "";
    if (zs_app_setting_source(self->core, part, key, &level, profile, sizeof profile) != ZS_OK) level = ZS_LEVEL_DEFAULT;
    if (level_out) *level_out = level;
    switch (level) {
    case ZS_LEVEL_GLOBAL: return g_strdup("Global");
    case ZS_LEVEL_MACHINE: return g_strdup(profile[0] ? profile : "Printer");
    case ZS_LEVEL_FILAMENT: return g_strdup(profile[0] ? profile : "Filament");
    case ZS_LEVEL_QUALITY: return g_strdup(profile[0] ? profile : "Quality");
    case ZS_LEVEL_PRINT: return g_strdup("This print");
    case ZS_LEVEL_PART: return g_strdup("This part");
    default: return NULL;
    }
}

char *zg_model_formula(ZgModel *self, const char *key) {
    size_t len = 0;
    if (zs_app_formula_get(self->core, key, NULL, 0, &len) != ZS_OK) return NULL;
    char *buf = g_malloc(len + 1);
    zs_app_formula_get(self->core, key, buf, len + 1, NULL);
    return buf;
}

char *zg_model_base_get(ZgModel *self, const char *key) {
    size_t len = 0;
    if (zs_app_setting_base_get(self->core, key, NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *buf = g_malloc(len + 1);
    zs_app_setting_base_get(self->core, key, buf, len + 1, NULL);
    return buf;
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

gboolean zg_model_is_draft(ZgModel *self) {
    return zs_app_state(self->core) == ZS_STATE_DONE && zs_app_is_draft(self->core);
}

gboolean zg_model_slices_draft(ZgModel *self) {
    return zs_app_state(self->core) == ZS_STATE_SLICING && zs_app_is_draft(self->core);
}

double zg_model_draft_ms(ZgModel *self) {
    return self->draft_ms;
}

double zg_model_exact_ms(ZgModel *self) {
    return self->exact_ms;
}

void zg_model_mark_add(ZgModel *self, double x, double y, double z, double r, int kind) {
    if (zs_app_mark_add(self->core, x, y, z, r, kind) == ZS_OK) request_slice(self);
}

size_t zg_model_mark_remove_near(ZgModel *self, double x, double y, double z, double r) {
    size_t n = zs_app_mark_remove_near(self->core, x, y, z, r);
    if (n > 0) request_slice(self);
    return n;
}

void zg_model_mark_set(ZgModel *self, size_t i, int kind, double r) {
    if (zs_app_mark_set(self->core, i, kind, r) == ZS_OK) request_slice(self);
}

void zg_model_mark_remove(ZgModel *self, size_t i) {
    zs_app_mark_remove(self->core, i);
    request_slice(self);
}

void zg_model_marks_clear(ZgModel *self) {
    if (zs_app_mark_count(self->core) == 0) return;
    zs_app_marks_clear(self->core);
    request_slice(self);
}

/* A change of the support areas: a slice, and a history step (at the
 * release of a hold). */
static void support_changed(ZgModel *self) {
    request_slice(self);
    if (!self->held) undo_commit(self);
}

/* An edit of the support trees in the core: a slice (held during a
 * drag), one step of the history, and a part that lost what held it
 * falls. */
void zg_model_support_trees_changed(ZgModel *self) {
    support_changed(self);
    fall_check(self);
}

gint64 zg_model_support_add(ZgModel *self, int kind, const double *pts, size_t n, double z_lo, double z_hi) {
    ptrdiff_t i = zs_app_support_area_add(self->core, kind, pts, n, z_lo, z_hi);
    if (i < 0) return -1;
    support_changed(self);
    return i;
}

gboolean zg_model_support_set(ZgModel *self, size_t i, const double *pts, size_t n) {
    if (zs_app_support_area_set(self->core, i, pts, n, NAN, NAN) != ZS_OK) return FALSE;
    support_changed(self);
    return TRUE;
}

gboolean zg_model_support_set_kind(ZgModel *self, size_t i, int kind) {
    if (zs_app_support_area_set_kind(self->core, i, kind) != ZS_OK) return FALSE;
    support_changed(self);
    fall_check(self);
    return TRUE;
}

gboolean zg_model_support_remove(ZgModel *self, size_t i) {
    if (zs_app_support_area_remove(self->core, i) != ZS_OK) return FALSE;
    support_changed(self);
    fall_check(self);
    return TRUE;
}

/* A change of the labels of a part: a slice and one step of the
 * history. */
static void labels_changed(ZgModel *self) {
    request_slice(self);
    if (!self->held) undo_commit(self);
}

gint64 zg_model_label_add(ZgModel *self, size_t part, const char *json) {
    uint32_t id = 0;
    if (zs_app_label_add(self->core, part, json, strlen(json), &id) != ZS_OK) return -1;
    labels_changed(self);
    return id;
}

gboolean zg_model_label_update(ZgModel *self, size_t part, guint32 id, const char *json) {
    if (zs_app_label_update(self->core, part, id, json, strlen(json)) != ZS_OK) return FALSE;
    labels_changed(self);
    return TRUE;
}

gboolean zg_model_part_paint_set(ZgModel *self, size_t part, const char *text, size_t len) {
    if (zs_app_part_paint_set(self->core, part, text, len) != ZS_OK) return FALSE;
    labels_changed(self);
    return TRUE;
}

gboolean zg_model_paint_body(ZgModel *self, const float *beads, size_t n, guint filament) {
    size_t changed = 0;
    if (zs_app_paint_body(self->core, beads, n, filament, &changed) != ZS_OK) return FALSE;
    if (changed > 0) labels_changed(self);
    return TRUE;
}

gboolean zg_model_label_remove(ZgModel *self, size_t part, guint32 id) {
    if (zs_app_label_remove(self->core, part, id) != ZS_OK) return FALSE;
    labels_changed(self);
    return TRUE;
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

/* ---- undo and redo of the settings and the plate ----
 *
 * The core keeps the undo list (zs_app_history_*), and notes each change.
 * The model keeps the timer of a step and the focus, and updates the
 * editors after an undo. */

static void plate_changed(ZgModel *self);

static gint64 now_ms(void) {
    return g_get_real_time() / 1000;
}

static void undo_stop_timer(ZgModel *self) {
    if (self->undo_timer) g_source_remove(self->undo_timer);
    self->undo_timer = 0;
}

/* Ends the step of the changes so far. */
static void undo_commit(ZgModel *self) {
    undo_stop_timer(self);
    gint64 t0 = g_get_monotonic_time();
    gboolean done = zs_app_history_commit(self->core, now_ms());
    if (g_getenv("ZSLICE_BENCH")) g_message("bench: a history commit, %.0f ms", (g_get_monotonic_time() - t0) / 1000.0);
    if (done) g_signal_emit(self, signals[SIGNAL_UNDO_CHANGED], 0);
}

static gboolean on_undo_timer(gpointer data) {
    ZgModel *self = data;
    self->undo_timer = 0;
    undo_commit(self);
    return G_SOURCE_REMOVE;
}

static void undo_schedule(ZgModel *self) {
    if (self->undo_restoring) return;
    undo_stop_timer(self);
    /* A drag: the step ends at the release (zg_model_hold). */
    if (self->held) return;
    self->undo_timer = g_timeout_add(400, on_undo_timer, self);
}

static void on_undo_change(ZgModel *self, const char *key, gpointer data) {
    undo_schedule(self);
}

static void on_undo_plate(ZgModel *self, gpointer data) {
    undo_schedule(self);
}

void zg_model_history_set_focus(ZgModel *self, const char *key) {
    /* A new focus ends the edit: the core commits its changes. */
    gboolean changed = zs_app_history_set_focus(self->core, key, now_ms());
    if (!zs_app_history_pending(self->core)) undo_stop_timer(self);
    if (changed) g_signal_emit(self, signals[SIGNAL_UNDO_CHANGED], 0);
}

/* After an undo, a redo, or a jump (the bits of enum
 * zs_history_restored): the selection, the editors, the saved groups, and
 * a new slice. */
static void undo_restored(ZgModel *self, int bits) {
    if (bits & ZS_HISTORY_MOVED) {
        self->undo_restoring = TRUE;
        if (bits & ZS_HISTORY_PLATE) {
            zg_model_select_part(self, -1);
            zg_model_select(self, -1);
            plate_changed(self);
            if (zs_app_part_count(self->core) == 0) g_signal_emit(self, signals[SIGNAL_CORE_EVENT], 0, ZS_EVENT_CANCELED, 0.0, 0);
        }
        if (bits & ZS_HISTORY_QUALITY) {
            const char *q = zs_app_quality_name(self->core);
            zg_pref_set("profile_project", q);
        }
        static const char *prefixes[] = {"machine.", "filament.", "project."};
        for (int g = 0; g < 3; g++) {
            if (!(bits & (ZS_HISTORY_MACHINE << g))) continue;
            zg_model_announce(self, prefixes[g]);
            zg_model_save_soon(self, g);
        }
        self->undo_restoring = FALSE;
        slice_soon(self);
    }
    g_signal_emit(self, signals[SIGNAL_UNDO_CHANGED], 0);
}

gboolean zg_model_undo(ZgModel *self) {
    undo_stop_timer(self);
    /* A fall or the hand ends first: its part can change or go. */
    zg_model_fall_cancel(self);
    int bits = zs_app_history_undo(self->core, now_ms());
    undo_restored(self, bits);
    return bits != 0;
}

gboolean zg_model_redo(ZgModel *self) {
    undo_stop_timer(self);
    /* A fall or the hand ends first: its part can change or go. */
    zg_model_fall_cancel(self);
    int bits = zs_app_history_redo(self->core, now_ms());
    undo_restored(self, bits);
    return bits != 0;
}

/* ---- the history: the steps of the undo list, the oldest first ---- */

guint zg_model_history_count(ZgModel *self) {
    return zs_app_history_count(self->core);
}

guint zg_model_history_current(ZgModel *self) {
    return zs_app_history_current(self->core);
}

gint64 zg_model_history_time(ZgModel *self, guint i) {
    zs_history_step st;
    if (zs_app_history_step(self->core, i, &st) != ZS_OK) return 0;
    return st.time_ms * 1000;
}

char *zg_model_history_changes(ZgModel *self, guint i) {
    zs_history_step st;
    if (i == 0 || zs_app_history_step(self->core, i, &st) != ZS_OK) return NULL;
    return g_strndup(st.changes, st.changes_len);
}

char *zg_model_history_describe(ZgModel *self, const char *changes) {
    size_t len = 0;
    if (!changes || zs_app_history_describe(self->core, changes, strlen(changes), NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *out = g_malloc(len + 1);
    zs_app_history_describe(self->core, changes, strlen(changes), out, len + 1, NULL);
    return out;
}

gboolean zg_model_history_goto(ZgModel *self, guint i) {
    undo_stop_timer(self);
    /* A fall or the hand ends first: its part can change or go. */
    zg_model_fall_cancel(self);
    int bits = zs_app_history_goto(self->core, i, now_ms());
    undo_restored(self, bits);
    return bits != 0;
}

gboolean zg_model_history_truncate(ZgModel *self, guint i) {
    undo_stop_timer(self);
    int bits = zs_app_history_truncate(self->core, i, now_ms());
    undo_restored(self, bits);
    return (bits & ZS_HISTORY_DROPPED) != 0;
}

static void save_soon(ZgModel *self, const char *key);

/* Applies one refinement (zs_app_refine_apply): one step of the history,
 * then a slice. */
gboolean zg_model_refine_apply(ZgModel *self, const char *line) {
    if (zs_app_refine_apply(self->core, line, strlen(line)) != ZS_OK) return FALSE;
    undo_commit(self);
    char **f = g_strsplit(line, "\t", 4);
    if (f[0] && f[1] && f[2]) {
        if (strcmp(f[0], "print") == 0) save_soon(self, f[2]);
        emit_setting(self, f[2]);
    }
    g_strfreev(f);
    g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
    g_signal_emit(self, signals[SIGNAL_UNDO_CHANGED], 0);
    plate_changed(self);
    slice_soon(self);
    return TRUE;
}

gboolean zg_model_history_revert(ZgModel *self, const char *line) {
    if (zs_app_history_revert(self->core, line, strlen(line)) != ZS_OK) return FALSE;
    char **f = g_strsplit(line, "\t", 3);
    if (f[0] && f[1]) {
        if (g_str_has_prefix(f[0], "part:")) {
            plate_changed(self);
        } else if (g_str_has_prefix(f[0], "layers:")) {
            emit_setting(self, f[1]);
            g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
            slice_soon(self);
        } else {
            save_soon(self, f[1]);
            emit_setting(self, f[1]);
            slice_soon(self);
        }
    }
    g_strfreev(f);
    return TRUE;
}

/* ---- the tools of the preview, and the measure tape ---- */

ZgTool zg_model_tool(ZgModel *self) {
    return (ZgTool)self->tool;
}

void zg_model_set_tool(ZgModel *self, ZgTool tool) {
    if (self->tool == (int)tool) return;
    self->tool = (int)tool;
    /* The tape goes with its tool. */
    if (tool != ZG_TOOL_MEASURE && self->measure_n > 0) zg_model_measure_clear(self);
    g_signal_emit(self, signals[SIGNAL_TOOL_CHANGED], 0);
}

void zg_model_measure_add_shape(ZgModel *self, double x, double y, double z, double radius, int shape) {
    /* A third point starts a new measure. */
    if (self->measure_n >= 2) self->measure_n = 0;
    self->measure[3 * self->measure_n] = x;
    self->measure[3 * self->measure_n + 1] = y;
    self->measure[3 * self->measure_n + 2] = z;
    self->measure_r[self->measure_n] = radius;
    self->measure_shape[self->measure_n] = shape;
    self->measure_n++;
    g_signal_emit(self, signals[SIGNAL_MEASURE_CHANGED], 0);
}

void zg_model_measure_move(ZgModel *self, int i, double x, double y, double z) {
    if (i < 0 || i >= self->measure_n) return;
    self->measure[3 * i] = x;
    self->measure[3 * i + 1] = y;
    self->measure[3 * i + 2] = z;
    /* A moved end is a point, not a center. */
    self->measure_r[i] = 0;
    self->measure_shape[i] = 0;
    g_signal_emit(self, signals[SIGNAL_MEASURE_CHANGED], 0);
}

void zg_model_measure_add(ZgModel *self, double x, double y, double z) {
    zg_model_measure_add_shape(self, x, y, z, 0, 0);
}

double zg_model_measure_radius(ZgModel *self, int i, int *shape) {
    if (i < 0 || i >= self->measure_n) return 0;
    if (shape) *shape = self->measure_shape[i];
    return self->measure_r[i];
}

void zg_model_measure_clear(ZgModel *self) {
    if (self->measure_n == 0) return;
    self->measure_n = 0;
    g_signal_emit(self, signals[SIGNAL_MEASURE_CHANGED], 0);
}

int zg_model_measure(ZgModel *self, const double **pts) {
    if (pts) *pts = self->measure;
    return self->measure_n;
}

gboolean zg_model_can_undo(ZgModel *self) {
    return zs_app_history_current(self->core) > 0 || self->undo_timer != 0;
}

gboolean zg_model_can_redo(ZgModel *self) {
    return zs_app_history_current(self->core) + 1 < zs_app_history_count(self->core) && self->undo_timer == 0;
}

/* For tests: ZSLICE_USE_PRINTERS=id,id,... switches to each printer in
 * turn, 4 s apart, and logs the filament and the outer wall acceleration
 * after each switch. */
typedef struct {
    GWeakRef model;
    char **ids;
    int next;
} SwitchTest;

static gboolean switch_test_step(gpointer data) {
    SwitchTest *t = data;
    ZgModel *self = g_weak_ref_get(&t->model);
    if (!self || !t->ids[t->next]) {
        if (self) g_object_unref(self);
        g_weak_ref_clear(&t->model);
        g_strfreev(t->ids);
        g_free(t);
        return G_SOURCE_REMOVE;
    }
    zg_model_use_printer(self, t->ids[t->next++]);
    char *fil = zg_model_get(self, "filament.name");
    char *acc = zg_model_get(self, "machine.outer_wall_accel");
    g_message("switch test: printer %s, filament %s, outer_wall_accel %s", zg_printers_current()->name, fil, acc);
    g_free(fil);
    g_free(acc);
    g_object_unref(self);
    return G_SOURCE_CONTINUE;
}

static void zg_model_init(ZgModel *self) {
    self->selected = -1;
    self->segment = -1;
    self->gap_layer = self->gap_index = -1;
    self->part = -1;
    self->parts_more = g_array_new(FALSE, FALSE, sizeof(gint64));
    self->parts_all = g_array_new(FALSE, FALSE, sizeof(gint64));
    self->part_scope = -1;
    self->bridge = g_atomic_rc_box_new0(Bridge);
    g_weak_ref_init(&self->bridge->model, self);
    int rc = zs_set_new(on_core_event, self->bridge, &self->set);
    if (rc != ZS_OK) g_error("zslice: the app core did not start: %s", zg_status_text(rc));
    sync_core(self);
    gboolean moved = load_state(self), global_moved = FALSE;
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
    /* The global settings of the user, under the quality. */
    {
        char *dir = zg_config_dir();
        char *path = g_build_filename(dir, "global.toml", NULL);
        char *text = NULL;
        gsize len = 0;
        char message[256] = "";
        gboolean read = g_file_get_contents(path, &text, &len, NULL);
        if (read && zs_profile_moved(ZS_GROUP_PROJECT, text, len) > 0) moved = global_moved = TRUE;
        if (read && zs_app_global_set(self->core, text, len, message, sizeof message) != ZS_OK)
            g_warning("zslice: %s was not loaded (%s)", path, message);
        g_free(text);
        g_free(path);
        g_free(dir);
    }
    /* The formulas of the settings, on top. */
    {
        char *dir = zg_config_dir();
        char *path = g_build_filename(dir, "formulas.txt", NULL);
        char *text = NULL;
        gsize len = 0;
        if (g_file_get_contents(path, &text, &len, NULL)) zs_app_formulas_read(self->core, text, len);
        g_free(text);
        g_free(path);
        g_free(dir);
    }
    /* The saved texts of an older version have the accelerations of the
     * features in the project settings. They loaded into the printer now
     * (the current one). Save the groups once in their new form, so the
     * project text has no accelerations and each printer keeps its own. */
    if (moved) {
        g_message("zslice: the accelerations of the features are printer settings now; the saved values moved to the printer %s",
                  zg_printers_current()->name);
        self->dirty |= (1u << ZS_GROUP_MACHINE) | (1u << ZS_GROUP_PROJECT);
        save_state(self);
        if (global_moved) save_global(self);
    }
    const char *switches = g_getenv("ZSLICE_USE_PRINTERS");
    if (switches) {
        SwitchTest *t = g_new0(SwitchTest, 1);
        g_weak_ref_init(&t->model, self);
        t->ids = g_strsplit(switches, ",", -1);
        g_timeout_add_seconds(4, switch_test_step, t);
    }
    /* The start of the undo list: the state after the start. */
    zs_app_history_commit(self->core, now_ms());
    g_signal_connect(self, "plate-changed", G_CALLBACK(on_undo_plate), NULL);
    g_signal_connect(self, "setting-changed", G_CALLBACK(on_undo_change), NULL);
    /* The layer profiles and the changes for some layers are in the plate
     * (its 3MF file): a step keeps them with the plate. */
    g_signal_connect(self, "profiles-changed", G_CALLBACK(on_undo_plate), NULL);
}

ZgModel *zg_model_new(void) {
    return g_object_new(ZG_TYPE_MODEL, NULL);
}

zs_app *zg_model_core(ZgModel *self) {
    return self->core;
}

zs_set *zg_model_plate_set(ZgModel *self) {
    return self->set;
}

const char *zg_model_name(ZgModel *self) {
    return self->name;
}

static gboolean fail(GError **error, int rc) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s", zg_status_text(rc));
    return FALSE;
}

/* The name for the title: the first part, and how many more. A plate of
 * a project has the names of its parts. */
static void update_name(ZgModel *self) {
    g_free(self->name);
    self->name = NULL;
    if (self->project && self->project_title) {
        self->name = g_strdup(self->project_title);
        return;
    }
    size_t n = zs_app_part_count(self->core);
    zs_part p;
    if (n == 0 || zs_app_part_get(self->core, 0, &p) != ZS_OK) return;
    self->name = n == 1 ? g_strdup(p.name) : g_strdup_printf("%s and %zu more", p.name, n - 1);
}

static void plate_changed(ZgModel *self) {
    self->edit_gen++;
    update_name(self);
    /* The part of the scope went: the plate. */
    if (self->part_scope >= (gint64)zs_app_part_count(self->core)) {
        self->part_scope = -1;
        g_signal_emit(self, signals[SIGNAL_PART_SCOPE_CHANGED], 0);
    }
    if ((size_t)self->part >= zs_app_part_count(self->core)) zg_model_select_part(self, -1);
    /* The other selected parts that went. */
    for (guint k = self->parts_more->len; k-- > 0;)
        if ((size_t)g_array_index(self->parts_more, gint64, k) >= zs_app_part_count(self->core)) g_array_remove_index(self->parts_more, k);
    g_signal_emit(self, signals[SIGNAL_PLATE_CHANGED], 0);
    if (zs_app_part_count(self->core) > 0) slice_plate_soon(self);
}

/* A copy of the session (zs_session_snapshot_take): the plates, their scenes,
 * the camera (or NULL), and the text of the app. NULL on failure. */
zs_session_snapshot *zg_model_session_snapshot(ZgModel *self, const float *camera, const char *app_text) {
    zs_session_snapshot *snap = NULL;
    if (zs_session_snapshot_take(self->set, camera, app_text, &snap) != ZS_OK) return NULL;
    return snap;
}

/* Puts a session back: the plates, the camera (*has_camera), and the text
 * of the app (free it with g_free). */
gboolean zg_model_session_open(ZgModel *self, const void *data, gsize len, float camera[8], gboolean *has_camera, char **app_text, GError **error) {
    char message[512] = "";
    int has = 0;
    uint8_t *text = NULL;
    size_t text_len = 0;
    plate_leave(self);
    int rc = zs_session_read(self->set, data, len, camera, &has, &text, &text_len, message, sizeof message);
    if (rc != ZS_OK) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s", message[0] ? message : zs_status_string(rc));
        return FALSE;
    }
    if (has_camera) *has_camera = has != 0;
    if (app_text) *app_text = g_strndup((const char *)text, text_len);
    if (text) zs_buffer_free(text, text_len);
    for (size_t i = 0; i < zs_set_count(self->set); i++) zs_set_changed(self->set, i);
    plate_switched(self);
    return TRUE;
}

gboolean zg_model_load(ZgModel *self, const char *name, const void *data, gsize len, GError **error) {
    /* A project file of zslice: its plates replace the plates. */
    if (zs_project_file_is(data, len)) {
        char message[512] = "";
        plate_leave(self);
        int prc = zs_set_project_open(self->set, data, len, message, sizeof message);
        if (prc != ZS_OK) {
            g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s", message[0] ? message : zs_status_string(prc));
            return FALSE;
        }
        for (size_t i = 0; i < zs_set_count(self->set); i++) zs_set_changed(self->set, i);
        plate_switched(self);
        if (message[0]) g_message("zslice: %s", message);
        return TRUE;
    }
    int rc = zs_app_load_stl(self->core, name, data, len);
    if (rc != ZS_OK) return fail(error, rc);
    /* The plate takes the name of the file. */
    zs_set_name(self->set, zs_set_active(self->set), name);
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
    gboolean had_more = self->parts_more->len > 0;
    g_array_set_size(self->parts_more, 0);
    if (self->part == part && !had_more) return;
    /* A part, or a line: not both. The line goes first, so the part page
     * comes after it. */
    if (part >= 0 && self->selected >= 0) zg_model_select(self, -1);
    self->part = part;
    g_signal_emit(self, signals[SIGNAL_PART_SELECTED], 0, part);
}

gint64 zg_model_selected_part(ZgModel *self) {
    return self->part;
}

void zg_model_toggle_part(ZgModel *self, gint64 part) {
    if (part < 0) return;
    if (self->part < 0) {
        zg_model_select_part(self, part);
        return;
    }
    if (part == self->part) {
        /* The last part of the others takes its place. */
        gint64 next = -1;
        if (self->parts_more->len > 0) {
            next = g_array_index(self->parts_more, gint64, self->parts_more->len - 1);
            g_array_set_size(self->parts_more, self->parts_more->len - 1);
        }
        self->part = next;
        g_signal_emit(self, signals[SIGNAL_PART_SELECTED], 0, next);
        return;
    }
    for (guint k = 0; k < self->parts_more->len; k++) {
        if (g_array_index(self->parts_more, gint64, k) == part) {
            g_array_remove_index(self->parts_more, k);
            g_signal_emit(self, signals[SIGNAL_PART_SELECTED], 0, self->part);
            return;
        }
    }
    g_array_append_val(self->parts_more, self->part);
    self->part = part;
    g_signal_emit(self, signals[SIGNAL_PART_SELECTED], 0, part);
}

const gint64 *zg_model_parts(ZgModel *self, guint *n) {
    g_array_set_size(self->parts_all, 0);
    g_array_append_vals(self->parts_all, self->parts_more->data, self->parts_more->len);
    if (self->part >= 0) g_array_append_val(self->parts_all, self->part);
    *n = self->parts_all->len;
    return (const gint64 *)self->parts_all->data;
}

static int cmp_desc(gconstpointer a, gconstpointer b) {
    gint64 x = *(const gint64 *)a, y = *(const gint64 *)b;
    return x < y ? 1 : x > y ? -1 : 0;
}

/* The selected parts, the highest index first (a remove moves the parts
 * after it). Free with g_array_free. */
static GArray *parts_desc(ZgModel *self) {
    guint n = 0;
    const gint64 *list = zg_model_parts(self, &n);
    GArray *a = g_array_new(FALSE, FALSE, sizeof(gint64));
    g_array_append_vals(a, list, n);
    g_array_sort(a, cmp_desc);
    return a;
}

void zg_model_parts_remove(ZgModel *self) {
    zg_model_fall_cancel(self);
    GArray *a = parts_desc(self);
    gboolean done = FALSE;
    for (guint k = 0; k < a->len; k++)
        if (zs_app_part_remove(self->core, (size_t)g_array_index(a, gint64, k)) == ZS_OK) done = TRUE;
    g_array_free(a, TRUE);
    if (!done) return;
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    plate_changed(self);
}

void zg_model_parts_duplicate(ZgModel *self) {
    guint n = 0;
    const gint64 *list = zg_model_parts(self, &n);
    GArray *src = g_array_new(FALSE, FALSE, sizeof(gint64));
    g_array_append_vals(src, list, n);
    GArray *copies = g_array_new(FALSE, FALSE, sizeof(gint64));
    for (guint k = 0; k < src->len; k++) {
        ptrdiff_t c = zs_app_part_duplicate(self->core, (size_t)g_array_index(src, gint64, k));
        if (c >= 0) {
            gint64 c64 = c;
            g_array_append_val(copies, c64);
        }
    }
    g_array_free(src, TRUE);
    if (copies->len > 0) {
        plate_changed(self);
        /* The copies are the new selection. */
        zg_model_select_part(self, g_array_index(copies, gint64, 0));
        for (guint k = 1; k < copies->len; k++) zg_model_toggle_part(self, g_array_index(copies, gint64, k));
    }
    g_array_free(copies, TRUE);
}

/* ---- the clipboard of parts (zs_app_parts_copy) ---- */

gboolean zg_model_parts_copy(ZgModel *self) {
    guint n = 0;
    const gint64 *list = zg_model_parts(self, &n);
    if (n == 0) return FALSE;
    size_t *idx = g_new(size_t, n);
    for (guint k = 0; k < n; k++) idx[k] = (size_t)list[k];
    int rc = zs_app_parts_copy(self->core, idx, n, 0);
    g_free(idx);
    return rc == ZS_OK;
}

gboolean zg_model_parts_cut(ZgModel *self) {
    if (!zg_model_parts_copy(self)) return FALSE;
    zg_model_parts_remove(self);
    return TRUE;
}

gboolean zg_model_plate_copy(ZgModel *self) {
    if (zs_app_part_count(self->core) == 0) return FALSE;
    return zs_app_parts_copy(self->core, NULL, 0, 1) == ZS_OK;
}

/* The new parts from index `first` on are the selection. */
static void select_from(ZgModel *self, size_t first) {
    size_t n = zs_app_part_count(self->core);
    if (first >= n) return;
    zg_model_select_part(self, (gint64)first);
    for (size_t k = first + 1; k < n; k++) zg_model_toggle_part(self, (gint64)k);
}

gint64 zg_model_parts_paste(ZgModel *self, gboolean at_point, double x, double y) {
    zg_model_fall_cancel(self);
    ptrdiff_t first = zs_app_parts_paste(self->core, at_point ? 1 : 0, x, y);
    if (first < 0) return -1;
    plate_changed(self);
    select_from(self, (size_t)first);
    return (gint64)(zs_app_part_count(self->core) - (size_t)first);
}

/* A new plate after the others (with the settings of the active plate),
 * and the parts of `from` on it: the clipboard, or a copy of plate
 * `from` (with no change of the clipboard). */
static gboolean plate_new_from(ZgModel *self, zs_app *from) {
    if (!from && zs_clipboard_parts() == 0) return FALSE;
    if (from && zs_app_part_count(from) == 0) return FALSE;
    plate_leave(self);
    if (zs_set_add(self->set) < 0) return FALSE;
    plate_switched(self);
    ptrdiff_t first = from ? zs_app_plate_copy_to(from, self->core) : zs_app_parts_paste(self->core, 0, 0, 0);
    if (first < 0) return FALSE;
    plate_changed(self);
    g_signal_emit(self, signals[SIGNAL_PLATES_CHANGED], 0);
    return TRUE;
}

gboolean zg_model_plate_paste_new(ZgModel *self) {
    return plate_new_from(self, NULL);
}

gboolean zg_model_plate_duplicate(ZgModel *self) {
    return plate_new_from(self, self->core);
}

GPtrArray *zg_model_scope_changes(ZgModel *self) {
    GPtrArray *out = g_ptr_array_new_with_free_func(g_free);
    if (!self->scope_on) return out;
    GHashTable *seen = g_hash_table_new(g_str_hash, g_str_equal);
    size_t n = zs_app_override_count(self->core);
    for (size_t i = 0; i < n; i++) {
        zs_override o;
        if (zs_app_override_get(self->core, i, &o) != ZS_OK) continue;
        if (o.z_min > self->scope_show + 1e-4 || o.z_max < self->scope_show - 1e-4) continue;
        char *name = g_strndup(o.name, o.name_len);
        char *line = g_strdup_printf("%s\t%.*s", name, (int)o.value_len, o.value);
        /* The last change of a setting wins. */
        gpointer at = g_hash_table_lookup(seen, name);
        if (at) {
            guint k = GPOINTER_TO_UINT(at) - 1;
            g_free(g_ptr_array_index(out, k));
            g_ptr_array_index(out, k) = line;
            g_free(name);
        } else {
            g_ptr_array_add(out, line);
            g_hash_table_insert(seen, name, GUINT_TO_POINTER(out->len));
        }
    }
    GHashTableIter it;
    gpointer key;
    g_hash_table_iter_init(&it, seen);
    while (g_hash_table_iter_next(&it, &key, NULL)) g_free(key);
    g_hash_table_destroy(seen);
    return out;
}

guint zg_model_scope_paste(ZgModel *self, GPtrArray *changes) {
    if (!self->scope_on) return 0;
    guint ok = 0;
    for (guint k = 0; k < changes->len; k++) {
        const char *line = g_ptr_array_index(changes, k);
        const char *tab = strchr(line, '\t');
        if (!tab) continue;
        char *name = g_strndup(line, (gsize)(tab - line));
        if (zs_app_override_set(self->core, self->scope_min, self->scope_max, name, tab + 1) == ZS_OK) {
            emit_setting(self, name);
            ok++;
        }
        g_free(name);
    }
    if (ok == 0) return 0;
    g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
    slice_soon(self);
    return ok;
}

guint zg_model_scope_clear(ZgModel *self, GPtrArray *changes) {
    if (!self->scope_on) return 0;
    guint ok = 0;
    for (guint k = 0; k < changes->len; k++) {
        const char *line = g_ptr_array_index(changes, k);
        const char *tab = strchr(line, '\t');
        char *name = tab ? g_strndup(line, (gsize)(tab - line)) : g_strdup(line);
        if (zs_app_override_remove(self->core, self->scope_min, self->scope_max, name) || zs_app_override_clear_at(self->core, self->scope_show, name) > 0) {
            emit_setting(self, name);
            ok++;
        }
        g_free(name);
    }
    if (ok == 0) return 0;
    g_signal_emit(self, signals[SIGNAL_PROFILES_CHANGED], 0);
    slice_soon(self);
    return ok;
}

gint64 zg_model_parts_to_new_plate(ZgModel *self) {
    GArray *a = parts_desc(self);
    ptrdiff_t to = -1;
    for (guint k = 0; k < a->len; k++) {
        ptrdiff_t r = zs_set_part_move(self->set, zs_set_active(self->set), (size_t)g_array_index(a, gint64, k), to);
        if (r < 0) break;
        to = r;
    }
    g_array_free(a, TRUE);
    if (to < 0) return -1;
    zg_model_select_part(self, -1);
    plate_changed(self);
    return to;
}

gboolean zg_model_parts_setting_set(ZgModel *self, const char *name, const char *value) {
    guint n = 0;
    const gint64 *list = zg_model_parts(self, &n);
    gboolean ok = TRUE;
    for (guint k = 0; k < n; k++)
        if (!zg_model_part_setting_set(self, (size_t)list[k], name, value)) ok = FALSE;
    return ok;
}

void zg_model_part_move(ZgModel *self, size_t i, double x, double y) {
    if (zs_app_part_move(self->core, i, x, y) == ZS_OK) plate_changed(self);
}

gboolean zg_model_fall_start(ZgModel *self, size_t i) {
    if (self->falling || zs_app_fall_start(self->core, i) != 1) return FALSE;
    self->falling = TRUE;
    return TRUE;
}

int zg_model_fall_step(ZgModel *self, double dt, double out[10]) {
    int rc = zs_app_fall_step(self->core, dt, out);
    if (rc == 1) return 1;
    self->falling = FALSE;
    if (rc == 0) {
        /* At rest: the part is at its new place, one step of the history. */
        plate_changed(self);
        undo_commit(self);
    }
    return rc;
}

void zg_model_fall_cancel(ZgModel *self) {
    if (!self->falling) return;
    zs_app_fall_cancel(self->core);
    self->falling = FALSE;
}

gboolean zg_model_falling(ZgModel *self) {
    return self->falling;
}

gint64 zg_model_edit_gen(ZgModel *self) {
    return self->edit_gen;
}

gint64 zg_model_shown_gen(ZgModel *self) {
    return self->shown_gen;
}

gboolean zg_model_grab_start(ZgModel *self, size_t i, double x, double y, double z) {
    if (self->falling || zs_app_grab_start(self->core, i, x, y, z) != 1) return FALSE;
    self->falling = TRUE;
    return TRUE;
}

void zg_model_grab_move(ZgModel *self, double x, double y, double z) {
    zs_app_grab_move(self->core, x, y, z);
}

void zg_model_grab_turn(ZgModel *self, double ax, double ay, double az, double degrees) {
    zs_app_grab_turn(self->core, ax, ay, az, degrees);
}

void zg_model_grab_end(ZgModel *self) {
    zs_app_grab_end(self->core);
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

void zg_model_part_mirror(ZgModel *self, size_t i, int axis) {
    if (zs_app_part_mirror(self->core, i, axis) == ZS_OK) plate_changed(self);
}

void zg_model_part_reset(ZgModel *self, size_t i) {
    if (zs_app_part_reset(self->core, i) == ZS_OK) plate_changed(self);
}

/* Plates: each plate has its own app (zs_set). After a switch, the
 * editors show the settings of the new plate, and the view its slice. */
static void plate_switched(ZgModel *self) {
    sync_core(self);
    /* The first step of the undo list of a new plate. */
    if (zs_app_history_count(self->core) == 0) zs_app_history_commit(self->core, now_ms());
    self->undo_restoring = TRUE;
    update_name(self);
    self->part_scope = -1;
    g_signal_emit(self, signals[SIGNAL_PART_SCOPE_CHANGED], 0);
    static const char *prefixes[] = {"machine.", "filament.", "project."};
    for (int g = 0; g < 3; g++) zg_model_announce(self, prefixes[g]);
    g_signal_emit(self, signals[SIGNAL_PLATE_CHANGED], 0);
    self->undo_restoring = FALSE;
    g_signal_emit(self, signals[SIGNAL_UNDO_CHANGED], 0);
    g_signal_emit(self, signals[SIGNAL_PLATES_CHANGED], 0);
    /* The view: the slice of the plate, or no slice yet. */
    int state = zs_app_state(self->core);
    self->switching = TRUE;
    g_signal_emit(self, signals[SIGNAL_CORE_EVENT], 0, state == ZS_STATE_DONE ? ZS_EVENT_SLICED : ZS_EVENT_CANCELED, 0.0, 0);
    self->switching = FALSE;
    fall_check(self);
}

/* Ends the step of the changes of the active plate before a switch. */
static void plate_leave(ZgModel *self) {
    zg_model_fall_cancel(self);
    if (self->undo_timer) undo_commit(self);
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    self->slice_pending = FALSE;
}

gboolean zg_model_plate_switching(ZgModel *self) {
    return self->switching;
}

void zg_model_plate_select(ZgModel *self, size_t i) {
    if (i == zs_set_active(self->set) || i >= zs_set_count(self->set)) return;
    plate_leave(self);
    if (zs_set_select(self->set, i) != ZS_OK) return;
    plate_switched(self);
}

GBytes *zg_model_project_bytes(ZgModel *self, const char *name) {
    uint8_t *out = NULL;
    size_t len = 0;
    if (zs_set_project_save(self->set, name, &out, &len) != ZS_OK) return NULL;
    GBytes *b = g_bytes_new(out, len);
    zs_buffer_free(out, len);
    return b;
}

gint64 zg_model_part_fill(ZgModel *self, size_t i, size_t n, size_t *plates) {
    plate_leave(self);
    ptrdiff_t r = zs_set_fill(self->set, zs_set_active(self->set), i, n, plates);
    plate_switched(self);
    return r;
}

void zg_model_edits_changed(ZgModel *self) {
    zg_model_select(self, -1);
    plate_changed(self);
}

gboolean zg_model_edit_line(ZgModel *self, gint64 path, int kind, double value) {
    if (path < 0) return FALSE;
    /* The key of the selected line works while a new slice runs. */
    int rc = path == self->selected && self->selected_key ? zs_app_edit_add_key(self->core, self->selected_key, self->selected_layer, kind, value)
                                                           : zs_app_edit_add(self->core, (size_t)path, kind, value);
    if (rc != ZS_OK) return FALSE;
    zg_model_select(self, -1);
    plate_changed(self);
    return TRUE;
}

gint64 zg_model_part_to_new_plate(ZgModel *self, size_t i) {
    ptrdiff_t to = zs_set_part_move(self->set, zs_set_active(self->set), i, -1);
    if (to < 0) return -1;
    zg_model_select_part(self, -1);
    plate_changed(self);
    return to;
}

void zg_model_plate_add(ZgModel *self) {
    plate_leave(self);
    if (zs_set_add(self->set) < 0) return;
    plate_switched(self);
}

char *zg_model_calibration(ZgModel *self) {
    size_t len = 0;
    if (zs_app_calibration_get(self->core, NULL, 0, &len) != ZS_OK) return NULL;
    char *text = g_malloc(len + 1);
    zs_app_calibration_get(self->core, text, len + 1, NULL);
    return text;
}

gboolean zg_model_calibrate(ZgModel *self, int kind, GError **error) {
    size_t from = zs_set_active(self->set);
    plate_leave(self);
    if (zs_set_add(self->set) < 0) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "No new plate.");
        return FALSE;
    }
    plate_switched(self);
    int rc = zs_app_calibration_add(self->core, kind);
    if (rc != ZS_OK) {
        plate_leave(self);
        settle(self);
        zs_set_remove(self->set, zs_set_active(self->set));
        zs_set_select(self->set, from);
        plate_switched(self);
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s",
                    rc == ZS_INVALID_SETTINGS ? "The printer has no retraction (machine.retract_length is 0)." : "The test did not load.");
        return FALSE;
    }
    char *cal = zg_model_calibration(self);
    if (cal) {
        for (char *l = cal; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
            if (!g_str_has_prefix(l, "name\t")) continue;
            char *name = g_strndup(l + 5, strcspn(l + 5, "\n"));
            zs_set_name(self->set, zs_set_active(self->set), name);
            g_free(name);
            break;
        }
        g_free(cal);
    }
    zs_app_history_commit(self->core, now_ms());
    plate_changed(self);
    return TRUE;
}

gboolean zg_model_calibration_use(ZgModel *self, const char *setting, const char *value) {
    gboolean ok = TRUE;
    for (size_t i = 0; i < zs_set_count(self->set); i++) {
        if (zs_app_setting_set(zs_set_app(self->set, i), setting, value) != ZS_OK) ok = FALSE;
        else if (i != zs_set_active(self->set)) zs_set_changed(self->set, i);
    }
    zs_app_history_commit(self->core, now_ms());
    zg_model_announce(self, setting);
    zg_model_save_soon(self, ZS_GROUP_FILAMENT);
    slice_soon(self);
    return ok;
}

void zg_model_plate_remove(ZgModel *self, size_t i) {
    plate_leave(self);
    settle(self);
    if (zs_set_remove(self->set, i) != ZS_OK) return;
    if (self->refine_ids && i < self->refine_ids->len) g_ptr_array_remove_index(self->refine_ids, (guint)i);
    plate_switched(self);
}

/* ---- the ids of the plates in the store of the refinements ---- */

const char *zg_model_refine_id(ZgModel *self) {
    if (!self->refine_ids) self->refine_ids = g_ptr_array_new_with_free_func(g_free);
    guint i = (guint)zs_set_active(self->set);
    while (self->refine_ids->len <= i) g_ptr_array_add(self->refine_ids, NULL);
    if (!g_ptr_array_index(self->refine_ids, i)) {
        char *id = g_strdup_printf("%" G_GINT64_MODIFIER "x-%08x", g_get_real_time() / 1000, g_random_int());
        g_ptr_array_index(self->refine_ids, i) = id;
    }
    return g_ptr_array_index(self->refine_ids, i);
}

char *zg_model_refine_ids(ZgModel *self) {
    GString *s = g_string_new(NULL);
    for (guint i = 0; self->refine_ids && i < self->refine_ids->len; i++) {
        const char *id = g_ptr_array_index(self->refine_ids, i);
        g_string_append_printf(s, "%s%s", i ? "," : "", id ? id : "");
    }
    return g_string_free(s, FALSE);
}

void zg_model_set_refine_ids(ZgModel *self, const char *text) {
    g_clear_pointer(&self->refine_ids, g_ptr_array_unref);
    self->refine_ids = g_ptr_array_new_with_free_func(g_free);
    char **f = g_strsplit(text ? text : "", ",", -1);
    for (char **k = f; *k; k++) g_ptr_array_add(self->refine_ids, **k ? g_strdup(*k) : NULL);
    g_strfreev(f);
}

gboolean zg_model_plate_smart_place(ZgModel *self) {
    int ok = zs_app_plate_smart_place(self->core);
    plate_changed(self);
    return ok;
}

void zg_model_part_rotate(ZgModel *self, size_t i, double degrees) {
    if (zs_app_part_rotate(self->core, i, degrees) == ZS_OK) plate_changed(self);
}

gboolean zg_model_global_clear(ZgModel *self, const char *key) {
    if (zs_app_global_setting_set(self->core, key, NULL) != ZS_OK) return FALSE;
    save_global(self);
    zg_model_announce(self, key);
    slice_soon(self);
    return TRUE;
}

void zg_model_set_part_scope(ZgModel *self, gint64 part) {
    if (part >= (gint64)zs_app_part_count(self->core)) part = -1;
    if (part < -1 && part != ZG_SCOPE_GLOBAL) part = -1;
    if (self->part_scope == part) return;
    self->part_scope = part;
    g_signal_emit(self, signals[SIGNAL_PART_SCOPE_CHANGED], 0);
    /* The editors show the values of the scope. */
    zg_model_announce(self, "project.");
    zg_model_announce(self, "filament.");
}

gint64 zg_model_part_scope(ZgModel *self) {
    return self->part_scope;
}

/* ---- the filaments of the plate ---- */

gint64 zg_model_filament_add(ZgModel *self) {
    size_t i = 0;
    if (zs_app_filament_add(self->core, &i) != ZS_OK) return -1;
    g_signal_emit(self, signals[SIGNAL_FILAMENTS_CHANGED], 0);
    plate_changed(self);
    return (gint64)i;
}

gboolean zg_model_filament_remove(ZgModel *self, size_t i) {
    if (zs_app_filament_remove(self->core, i) != ZS_OK) return FALSE;
    g_signal_emit(self, signals[SIGNAL_FILAMENTS_CHANGED], 0);
    /* The parts and the layers of the filaments after i have new
     * numbers: the editors of project.filament show them. */
    zg_model_announce(self, "project.");
    plate_changed(self);
    return TRUE;
}

gboolean zg_model_filament_set(ZgModel *self, size_t i, const char *name, const char *value, GError **error) {
    int rc = zs_app_filament_set(self->core, i, name, value);
    if (rc != ZS_OK) return fail(error, rc);
    /* Filament 0 is the filament of the settings: the settings change
     * too, and the filament profile saves. */
    if (i == 0) {
        emit_setting(self, name);
        save_soon(self, name);
    }
    g_signal_emit(self, signals[SIGNAL_FILAMENTS_CHANGED], 0);
    plate_changed(self);
    return TRUE;
}

char *zg_model_filament_get(ZgModel *self, size_t i, const char *name) {
    size_t len = 0;
    if (zs_app_filament_get(self->core, i, name, NULL, 0, &len) != ZS_OK) return g_strdup("");
    char *buf = g_malloc(len + 1);
    if (zs_app_filament_get(self->core, i, name, buf, len + 1, NULL) != ZS_OK) buf[0] = 0;
    return buf;
}

gboolean zg_model_filaments_from_printer(ZgModel *self, const char *printer, const char *json, gsize len, int flags,
                                         char **message) {
    char text[1024] = "";
    int changed = 0;
    int rc = zs_app_filaments_from_printer(self->core, printer, json, len, flags, &changed, text, sizeof text);
    if (message) *message = rc == ZS_OK || text[0] ? g_strdup(text) : NULL;
    if (rc != ZS_OK || !changed) return FALSE;
    /* Filament 0 is the filament of the settings: its profile saves. */
    zg_model_announce(self, "filament.");
    zg_model_announce(self, "project.");
    zg_model_save_soon(self, ZS_GROUP_FILAMENT);
    g_signal_emit(self, signals[SIGNAL_FILAMENTS_CHANGED], 0);
    plate_changed(self);
    return TRUE;
}

gboolean zg_model_part_setting_set(ZgModel *self, size_t i, const char *name, const char *value) {
    if (zs_app_part_setting_set(self->core, i, name, value) != ZS_OK) return FALSE;
    plate_changed(self);
    /* Support off for this part: it can fall. */
    fall_check(self);
    return TRUE;
}

char *zg_model_part_setting(ZgModel *self, size_t i, const char *name) {
    size_t len = 0;
    if (zs_app_part_setting_get(self->core, i, name, NULL, 0, &len) != ZS_OK) return NULL;
    char *buf = g_malloc(len + 1);
    zs_app_part_setting_get(self->core, i, name, buf, len + 1, NULL);
    return buf;
}

gint64 zg_model_part_duplicate(ZgModel *self, size_t i) {
    ptrdiff_t copy = zs_app_part_duplicate(self->core, i);
    if (copy < 0) return -1;
    plate_changed(self);
    return copy;
}

gint64 zg_model_part_cut(ZgModel *self, size_t i, double z, gboolean flip, int pegs, double peg_d) {
    ptrdiff_t n = zs_app_part_cut(self->core, i, z, flip ? 1 : 0, pegs, peg_d);
    if (n <= 0) return n < 0 ? -1 : 0;
    plate_changed(self);
    return n;
}

gint64 zg_model_part_split(ZgModel *self, size_t i) {
    ptrdiff_t n = zs_app_part_split(self->core, i);
    if (n <= 0) return n < 0 ? -1 : 0;
    plate_changed(self);
    return n;
}

void zg_model_part_remove(ZgModel *self, size_t i) {
    zg_model_fall_cancel(self);
    if (zs_app_part_remove(self->core, i) != ZS_OK) return;
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    plate_changed(self);
}

gboolean zg_model_part_reorder(ZgModel *self, size_t i, size_t to) {
    zg_model_fall_cancel(self);
    if (zs_app_part_reorder(self->core, i, to) != ZS_OK) return FALSE;
    plate_changed(self);
    return TRUE;
}

gboolean zg_model_plate_arrange(ZgModel *self) {
    int ok = zs_app_plate_arrange(self->core);
    plate_changed(self);
    return ok;
}

void zg_model_plate_clear(ZgModel *self) {
    zs_app_plate_clear(self->core);
    /* No parts: the plate has no name, and the set drops its slice. */
    zs_set_name(self->set, zs_set_active(self->set), NULL);
    zs_set_changed(self->set, zs_set_active(self->set));
    zg_model_select_part(self, -1);
    zg_model_select(self, -1);
    plate_changed(self);
    g_signal_emit(self, signals[SIGNAL_CORE_EVENT], 0, ZS_EVENT_CANCELED, 0.0, 0);
}

/* Saves the group of the setting soon. */
static void save_soon(ZgModel *self, const char *key) {
    for (int g = 0; g < 3; g++) {
        size_t n = strlen(group_files[g]);
        if (strncmp(key, group_files[g], n) == 0 && key[n] == '.') self->dirty |= 1u << g;
    }
    if (self->dirty) {
        if (self->save_timer) g_source_remove(self->save_timer);
        self->save_timer = g_timeout_add(500, on_save_timer, self);
    }
}

gboolean zg_model_set(ZgModel *self, const char *key, const char *value, GError **error) {
    int rc = zs_app_setting_set(self->core, key, value);
    if (rc != ZS_OK) return fail(error, rc);
    emit_setting(self, key);
    /* The settings with a formula can change with this one. */
    size_t flen = 0;
    if (zs_app_formulas_write(self->core, NULL, 0, &flen) == ZS_OK && flen > 0) {
        char *text = g_malloc(flen + 1);
        zs_app_formulas_write(self->core, text, flen + 1, NULL);
        char **lines = g_strsplit(text, "\n", -1);
        for (int i = 0; lines[i]; i++) {
            char *eq = strstr(lines[i], " = ");
            if (!eq) continue;
            *eq = 0;
            if (strcmp(lines[i], key) != 0) emit_setting(self, lines[i]);
        }
        g_strfreev(lines);
        g_free(text);
    }
    save_soon(self, key);
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
    /* The texts of the core, the same in each app. */
    return zs_status_message(status);
}

/* ---- printdeck.yml projects ---- */

/* Project mode off, with no change of the settings. */
static void project_off(ZgModel *self) {
    if (!self->project) return;
    self->project = FALSE;
    g_clear_pointer(&self->project_title, g_free);
    update_name(self);
    g_signal_emit(self, signals[SIGNAL_PROJECT_CHANGED], 0);
}

gboolean zg_model_project_active(ZgModel *self) {
    return self->project;
}

void zg_model_project_end(ZgModel *self) {
    if (!self->project) return;
    project_off(self);
    /* The machine settings of the printer of the user again. */
    zs_app_group_reset(self->core, ZS_GROUP_MACHINE);
    load_group(self, ZS_GROUP_MACHINE);
    zg_model_announce(self, "machine.");
    g_signal_emit(self, signals[SIGNAL_PRINTER_CHANGED], 0);
    slice_soon(self);
}

void zg_model_project_sent(ZgModel *self) {
    if (self->project) g_signal_emit(self, signals[SIGNAL_PROJECT_SENT], 0);
}

/* The text of member `group` ("machine") of the profiles JSON: its name
 * and text. FALSE if it is not there. */
static gboolean profile_of(JsonObject *o, const char *group, const char **name, const char **text) {
    JsonNode *n = json_object_get_member(o, group);
    if (!n || !JSON_NODE_HOLDS_OBJECT(n)) return FALSE;
    JsonObject *g = json_node_get_object(n);
    *name = json_object_get_string_member_with_default(g, "name", group);
    *text = json_object_get_string_member_with_default(g, "text", NULL);
    return *text != NULL;
}

int zg_model_project_load(ZgModel *self, const zs_files *files, const char *yml, const char *counts, size_t plate,
                          const char *title, char **message) {
    *message = NULL;
    size_t len = 0;
    int rc = zs_project_profiles(files, yml, counts, plate, NULL, 0, &len);
    if (rc != ZS_OK) {
        *message = g_strdup(zg_status_text(rc));
        return rc;
    }
    char *json = g_malloc(len + 1);
    zs_project_profiles(files, yml, counts, plate, json, len + 1, NULL);
    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, json, (gssize)len, NULL) || !JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser))) {
        g_object_unref(parser);
        g_free(json);
        *message = g_strdup("The profiles of the plate are not valid JSON.");
        return ZS_INVALID_VALUE;
    }
    g_free(json);
    JsonObject *o = json_node_get_object(json_parser_get_root(parser));
    if (json_object_has_member(o, "error")) {
        *message = g_strdup(json_object_get_string_member_with_default(o, "error", "error"));
        g_object_unref(parser);
        return ZS_INVALID_VALUE;
    }
    /* The machine settings of the printer of the user go to its profile
     * before project mode starts. */
    if (self->dirty) save_state(self);
    gboolean was = self->project;
    self->project = TRUE;
    static const char *groups[] = {"machine", "filament", "project"};
    for (int g = 0; g < 3; g++) {
        const char *name = NULL, *text = NULL;
        GError *error = NULL;
        if (!profile_of(o, groups[g], &name, &text)) {
            *message = g_strdup_printf("The %s profile is missing.", groups[g]);
            rc = ZS_INVALID_VALUE;
        } else if (!apply_profile(self, g, text, strlen(text), &error)) {
            *message = g_strdup_printf("The %s profile %s: %s", groups[g], name, error->message);
            g_error_free(error);
            rc = ZS_INVALID_VALUE;
        }
        if (rc != ZS_OK) {
            /* The machine settings of the printer of the user stay. */
            if (!was) {
                self->project = FALSE;
                zs_app_group_reset(self->core, ZS_GROUP_MACHINE);
                load_group(self, ZS_GROUP_MACHINE);
                zg_model_announce(self, "machine.");
            }
            g_object_unref(parser);
            return rc;
        }
    }
    g_object_unref(parser);
    char msg[1024] = "";
    rc = zs_app_project_load(self->core, files, yml, counts, plate, msg, sizeof msg);
    if (rc != ZS_OK && rc != ZS_OUT_OF_RANGE) {
        *message = g_strdup(msg[0] ? msg : zg_status_text(rc));
        /* The profiles of the project are on the view: project mode stays,
         * so the machine settings of the user stay as they are. */
    } else if (rc == ZS_OUT_OF_RANGE) {
        *message = g_strdup(msg);
    }
    g_free(self->project_title);
    self->project_title = g_strdup(title);
    zg_model_select(self, -1);
    zg_model_select_part(self, -1);
    if (!was) g_signal_emit(self, signals[SIGNAL_PROJECT_CHANGED], 0);
    /* The settings of the plate (support, adhesion) changed in the core. */
    zg_model_announce(self, "project.");
    zg_model_save_soon(self, ZS_GROUP_PROJECT);
    plate_changed(self);
    /* An empty app before the load: plate_changed does not slice it. */
    if (zs_app_state(self->core) == ZS_STATE_EMPTY && zs_app_part_count(self->core) > 0) request_slice(self);
    return rc;
}
