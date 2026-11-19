/* zslice-app.h: the app core, for the platform shells.
 *
 * A shell (GTK4, SwiftUI, Win32, Kotlin) draws native widgets, reads and
 * writes files, and moves events to its UI thread. All other app logic is
 * in the core, behind this API. See docs/app/README.md.
 *
 * Flow:
 *   1. zs_app_new with an event callback.
 *   2. Read a model file, and give the bytes to zs_app_load_stl.
 *   3. Build the settings panel from zs_setting_count and zs_setting_get_info.
 *      Show values with zs_app_setting_get, and set them with
 *      zs_app_setting_set.
 *   4. zs_app_slice. The slice runs on a worker thread. The callback gets
 *      ZS_EVENT_PROGRESS events, then one of ZS_EVENT_SLICED,
 *      ZS_EVENT_FAILED, or ZS_EVENT_CANCELED.
 *   5. After ZS_EVENT_SLICED: zs_app_stats, zs_app_layer_count,
 *      zs_app_layer_paths for the preview, and zs_app_gcode to export.
 *
 * Threads: the callback runs on the worker thread. Move each event to the
 * UI thread before it touches a widget or calls another zs_app function.
 * Call all zs_app functions from one thread (the UI thread).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef ZSLICE_APP_H
#define ZSLICE_APP_H

#include <stdbool.h>

#include "zslice.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zs_app zs_app;

enum zs_app_state {
    ZS_STATE_EMPTY = 0,   /* no model */
    ZS_STATE_READY = 1,   /* a model, no slice result */
    ZS_STATE_SLICING = 2,
    ZS_STATE_DONE = 3,    /* a slice result */
    ZS_STATE_FAILED = 4
};

enum zs_event {
    ZS_EVENT_PROGRESS = 1, /* progress is 0 to 1 */
    ZS_EVENT_SLICED = 2,
    ZS_EVENT_FAILED = 3,   /* status has the error code */
    ZS_EVENT_CANCELED = 4,
    ZS_EVENT_PLATES = 5    /* a plate set: the list or a status changed */
};

/* Runs on the worker thread. */
typedef void (*zs_app_event_fn)(void *user, int event, double progress, int status);

int zs_app_new(zs_app_event_fn event_fn, void *user, zs_app **out);
/* wasm only: the same, with the events to the import env.zs_web_event
 * (event, progress, status) of the module. The wasm build has no threads:
 * zs_app_slice slices on the calling thread (run it in a Web Worker), and
 * the events come while it runs. */
int zs_app_new_web(zs_app **out);
/* Stops a slice that runs, and frees the app. */
void zs_app_free(zs_app *app);
int zs_app_state(const zs_app *app);
/* Frees the memory that only makes the next slice faster: the results of
 * the slow steps of each layer, and the buffers of the results before.
 * The last result stays. For an app that waits, for example a plate of a
 * set that is not the active plate. No effect while a slice runs. */
void zs_app_trim(zs_app *app);

/* ---- the model ---- */

/* Loads an STL file. It replaces the current model and the slice result,
 * and stops a slice that runs. name is for display (can be NULL). */
int zs_app_load_stl(zs_app *app, const char *name, const uint8_t *data, size_t len);

typedef struct zs_model_info {
    uint64_t triangles;
    double size_x, size_y, size_z; /* mm */
} zs_model_info;

int zs_app_model_info(const zs_app *app, zs_model_info *out);

/* ---- settings ---- */

enum zs_setting_kind {
    ZS_SETTING_NUMBER = 0,  /* a decimal number */
    ZS_SETTING_INTEGER = 1,
    ZS_SETTING_BOOLEAN = 2, /* "true" or "false" */
    ZS_SETTING_CHOICE = 3,  /* one of `choices` */
    ZS_SETTING_TEXT = 4
};

/* The description of a setting. All strings are static. */
typedef struct zs_setting_info {
    const char *name;    /* "group.name", the key for get and set */
    const char *group;   /* "machine", "filament", "project", or "engine" */
    const char *section; /* a heading in the group, for example "Walls"; can be "" */
    const char *label;   /* a label for the UI */
    const char *doc;     /* help text, for a tooltip */
    int kind;            /* enum zs_setting_kind */
    int multiline;       /* for text: 1 if the value can have more than one line */
    const char *choices; /* for a choice: the choices, one on each line */
    const char *unit;    /* for a number: "mm", "mm/s", "°C", and so on. "%"
                            is a ratio: 0.5 is 50 %, so show the value times
                            100. "" for the other kinds. */
    const char *default_value; /* the built-in default, as zs_app_setting_get
                                  writes it */
    double slider_min, slider_max; /* the usual values, for a slider, in the
                                      units of the core (a ratio is 0..1);
                                      equal: no slider */
    double limit_min, limit_max;   /* the hard limits: a value out of them
                                      is ZS_OUT_OF_RANGE; equal: none */
    double slider_step;            /* the step of the slider (0.01 mm for a
                                      layer height), in core units */
    int per_layer;                 /* 1: the setting can change for some
                                      layers (zs_app_override_set) */
    int per_part;                  /* 1: one part of the plate can have
                                      its own value in a slice
                                      (zs_app_part_setting_set); 0: the
                                      same for all parts */
} zs_setting_info;

/* The text of a value of setting `name`, as an editor shows it: a ratio as
 * a percentage (0.2 is "20"), a line width of 0 as "auto", the first line
 * of a G-code and " …", a number as %.6g. with_unit != 0 adds the unit
 * ("0.8 mm", "20 %", "1 layer"). The same buffer rules as
 * zs_app_setting_get. */
int zs_setting_display(const char *name, const char *value, int with_unit, char *buf, size_t cap, size_t *out_len);
/* The core value of the text of an editor of setting `name`: "auto" is 0,
 * a percentage becomes a ratio. ZS_INVALID_VALUE for a number setting with
 * a text that is not a number. */
int zs_setting_parse(const char *name, const char *text, char *buf, size_t cap, size_t *out_len);
/* The source of a value as a short tag: level (enum zs_level), the name of
 * its profile, and its formula or NULL: "Global", the profile name, "This
 * print", "This part", or "= formula". */
int zs_setting_source_text(int level, const char *profile, const char *formula, char *buf, size_t cap, size_t *out_len);

/* 1 if a change line of a history step (zs_history_step.changes, one change
 * a line) can be undone alone with zs_app_history_revert: not the quality,
 * and not a move, turn, orientation, or scale of a part. */
int zs_history_revertible(const char *line, size_t len);

/* The settings that match a search query, best first, at most max: their
 * indices (zs_setting_get_info) in out_index and their scores in out_score
 * (either can be NULL). Each word of the query must match the label, the
 * name, the section, or the help text, by itself or by a word that means
 * the same (other slicers' words: "perimeters" finds the walls).
 * part_only != 0 keeps the settings that a part can have of its own.
 * Returns the count. The actions of an app stay in the app. */
size_t zs_setting_search(const char *query, int part_only, uint32_t *out_index, double *out_score, size_t max);

/* ---- the status of a printer ----
 * The app GETs each path of zs_printer_status_paths(kind) from the printer
 * (with its API key), and gives each reply to zs_printer_status_feed. The
 * kinds: 1 OctoPrint, 2 printdeck, 3 Moonraker. */
typedef struct zs_printer_status zs_printer_status;
typedef struct zs_printer_roll {
    const char *id, *name, *material, *color; /* color: "#rrggbb" */
    double left;                              /* grams */
} zs_printer_roll;
typedef struct zs_printer_info {
    const char *state;        /* "Operational", "Printing", "standby", ... */
    double bed_x, bed_y, height, nozzle;
    const char *material;     /* the filament in the printer, "PLA" */
    double diameter;
    zs_printer_roll spool;    /* the loaded roll (printdeck) */
    double spool_price, spool_full; /* 0 when not known */
    size_t roll_count;        /* zs_printer_status_roll */
    double max_velocity, max_accel, corner_velocity, max_z_velocity, max_z_accel; /* 0: not known */
    const char *job;          /* "" for no job */
    double progress;          /* 0 to 1 */
    double time_left;         /* seconds, -1: not known */
    int layer, layers;        /* 0: not known */
} zs_printer_info;
/* The paths to GET for a kind, one on each line (static). */
const char *zs_printer_status_paths(int kind);
zs_printer_status *zs_printer_status_new(void);
void zs_printer_status_free(zs_printer_status *s);
/* Reads the reply body of a path. A reply that is not JSON changes nothing. */
int zs_printer_status_feed(zs_printer_status *s, int kind, const char *path, const char *body, size_t len);
/* The status so far; the strings stay valid until the next feed or free. */
int zs_printer_status_get(const zs_printer_status *s, zs_printer_info *out);
int zs_printer_status_roll(const zs_printer_status *s, size_t i, zs_printer_roll *out);
/* Why the print failed or stopped ("" for none): the error of OctoPrint and
 * printdeck, the message of Moonraker, the error code of a Bambu Lab
 * printer. Valid until the next feed. */
const char *zs_printer_status_message(const zs_printer_status *s);
/* The state of the printer for the farm (enum zs_farm_printer_state, 0 to
 * 5), from its state text, the same for each kind of printer. */
int zs_printer_status_farm_state(const zs_printer_status *s);
/* Bambu Lab printers (kind 4 of zs_printer_status): no paths; give each
 * MQTT report (topic device/<serial>/report) to zs_printer_status_feed
 * with the path "report". The shell does the network: an upload of
 * zs_bambu_file over FTPS (implicit TLS, port 990, user "bblp", the access
 * code as the password), then MQTT over TLS (port 8883, the same user and
 * password). Start a print only after a fresh confirmation of the user
 * that the plate is clear. */
int zs_bambu_file(const uint8_t *gcode, size_t len, const char *title, uint8_t **out, size_t *out_len);
/* flags: 1 bed leveling, 2 the AMS, 4 a time lapse, 8 the url form
 * "ftp://<file>" (P1 and A1, reported) in place of "file:///sdcard/<file>"
 * (X1). md5: zs_bambu_md5 of the G-code, or NULL. */
int zs_bambu_start_message(const char *file, const char *title, const char *md5, int flags, uint8_t **out, size_t *out_len);
/* The MD5 of the G-code: 32 upper case hex digits and a 0 in out. */
int zs_bambu_md5(const uint8_t *gcode, size_t len, char out[33]);
const char *zs_bambu_push_all_message(void);
/* Applies the status of a printer to the settings. what: 1 the machine (the
 * bed, the height, the nozzle, and the motion limits, each only when the
 * printer gives it), 2 the filament (the built-in profile of its material,
 * the roll name, the diameter, the color), 3 both. One history step. */
int zs_app_apply_printer_status(zs_app *app, const zs_printer_status *s, int what);

/* The settings, in the order to show them. */
size_t zs_setting_count(void);
int zs_setting_get_info(size_t index, zs_setting_info *out);

/* Writes the value as text, with a NUL at the end, cut to cap. out_len (can
 * be NULL) gets the full length without the NUL. */
int zs_app_setting_get(const zs_app *app, const char *name, char *buf, size_t cap, size_t *out_len);
int zs_app_setting_set(zs_app *app, const char *name, const char *value);

/* ---- slicing ---- */

/* Starts a slice with the current settings. ZS_NO_MODEL without a model,
 * ZS_BUSY while a slice runs. */
int zs_app_slice(zs_app *app);
/* Starts a slice with the current settings, and stops a slice that runs
 * first, with no event for the old slice. Call it after each change of a
 * setting or the model, so that the preview shows the current settings.
 * Events can still arrive from the old slice if they were already queued:
 * read zs_app_state on each event, and do not depend on the event alone. */
int zs_app_request_slice(zs_app *app);
/* Asks a slice that runs to stop. ZS_EVENT_CANCELED follows. */
void zs_app_cancel(zs_app *app);
/* The address of the cancel flag (a byte: 1 stops the slice that runs),
 * for a shell that shares the memory of the app with another thread (the
 * web page: Atomics.store). A new slice sets it back to 0. */
size_t zs_app_cancel_address(zs_app *app);

/* ---- the result (state ZS_STATE_DONE) ---- */

int zs_app_stats(const zs_app *app, zs_stats *out);
/* The G-code. Valid until the next slice, the next model, or zs_app_free. */
int zs_app_gcode(const zs_app *app, const uint8_t **out, size_t *out_len);

/* A 3MF file of the plate: each part at its place, and the changes for
 * the part and for some layers. The bytes stay valid until the next call
 * or zs_app_destroy. zs_app_load_stl and zs_app_add_stl read 3MF files
 * too (the parts stay at their places). */
/* The speed in mm/s that a speed ratio setting (for example
 * "project.outer_wall_speed") gives with `value`, and the other settings
 * as they are. ZS_UNKNOWN_SETTING if the setting is not a speed ratio. */
int zs_app_ratio_speed(const zs_app *app, const char *name, const char *value, double *mm_s);

/* Islands: shapes of the last slice that start in the air (no outline and
 * no support under them on the layer below). They fall or make strings:
 * add support there, or check the model. In layer order. */
size_t zs_app_island_count(const zs_app *app);
int zs_app_island_get(const zs_app *app, size_t i, size_t *layer, double *x, double *y, double *area);

/* Support marks, from the context menu of a selected line: support of a
 * kind under a disk (radius r, mm) at x, y on the layer at nozzle z, or no
 * support there. They work also when support is off. A mark at the same
 * place is replaced. Call zs_app_request_slice after a change. */
enum zs_mark_kind { ZS_MARK_GRID = 0, ZS_MARK_TREE = 1, ZS_MARK_BRIDGE = 2, ZS_MARK_BLOCK = 3 };
int zs_app_mark_add(zs_app *app, double x, double y, double z, double r, int kind);
size_t zs_app_mark_remove_near(zs_app *app, double x, double y, double z, double r);
size_t zs_app_mark_count(const zs_app *app);
/* The mark under a place: (x, y) in its disk, on a layer within dz of z;
 * -1 if none. */
ptrdiff_t zs_app_mark_at(const zs_app *app, double x, double y, double z, double dz);
/* Mark i: its place, radius, and kind (enum zs_mark_kind). */
int zs_app_mark_get(const zs_app *app, size_t i, double *x, double *y, double *z, double *r, int *kind);
/* Changes the kind and the radius of mark i. */
int zs_app_mark_set(zs_app *app, size_t i, int kind, double r);
void zs_app_mark_remove(zs_app *app, size_t i);
void zs_app_marks_clear(zs_app *app);

/* Support areas (the support editor): a polygon of n points on the surface
 * of a part, x, y, z (mm) each, in points (3 n values, 3 to 256 points).
 * Kind (enum zs_mark_kind) grid or tree: support under the surface in the
 * polygon that faces down in the z range z_lo to z_hi, also under the
 * support angle and with support off; bridge: a pad there; block: no
 * support there. A z range with z_lo over z_hi (or NaN) comes from the z
 * of the points. The areas are in the plate 3MF and the history. Each
 * change is one history step; slice again after it. zs_app_support_area_add
 * returns the index of the new area, or -status. */
ptrdiff_t zs_app_support_area_add(zs_app *app, int kind, const double *points, size_t n, double z_lo, double z_hi);
/* The overhang of a part nearest to the bed point (x, y, z) mm, within
 * max_dist mm, for the support tool: the faces that face down and connect
 * to the face under the point. Writes its outline (x, y, z each, at most
 * cap points) to points, the count to *n, and the z range. Returns the
 * part, or -1 with no overhang there, or -status. Give the outline to
 * zs_app_support_area_add. */
ptrdiff_t zs_app_support_pick(zs_app *app, double x, double y, double z, double max_dist, double *points, size_t cap, size_t *n, double *z_lo, double *z_hi);
/* New points and z range for area i: a drag of a point. Hold the slice of
 * the plate during a drag (zs_set_changed_held), and release it at the
 * end (zs_set_release). */
int zs_app_support_area_set(zs_app *app, size_t i, const double *points, size_t n, double z_lo, double z_hi);
int zs_app_support_area_set_kind(zs_app *app, size_t i, int kind);
int zs_app_support_area_remove(zs_app *app, size_t i);
size_t zs_app_support_area_count(const zs_app *app);
/* Area i: its kind, its z range, and its points: *n gets the count, and
 * points gets at most cap of them (3 values each). Any output can be NULL. */
int zs_app_support_area_get(const zs_app *app, size_t i, int *kind, double *points, size_t cap, size_t *n, double *z_lo, double *z_hi);

/* Support trees (the support editor of tree support). A slice plans the
 * trees of each part. The first edit of a part copies them into the trees
 * of the user of that part; from then on its slices use those trees,
 * until zs_app_support_tree_reset. The trees of the user move with the
 * part, and go into the 3MF, the history, and the session. A turn or a
 * scale of the part, or other layers, drops them (see
 * zs_app_support_tree_note). Each edit keeps the rules of the planner and
 * reports in *clamp (can be NULL) the rules that limited it: the node
 * stays out of the part and its XY gap, a segment leans at most the
 * support tree angle, and a radius is at least what the bend, buckling,
 * and least-radius rules need. Each edit is one history step; slice again
 * after it, and call zs_app_fall_pending (a part may lose what held it).
 * During a drag, hold the slice of the plate (zs_set_changed_held). The
 * edits need a slice result: else they return ZS_BUSY. */
typedef struct zs_tree_node {
    double x, y, z; /* the center on the plate, and the top z of its layer (mm) */
    double r;       /* the radius (mm) */
    double r_min;   /* the least radius that the rules allow (mm) */
    int32_t down;   /* the next node toward the bed, or -1 */
    uint32_t layer;
    uint32_t branch; /* the branch: the nodes between two joins */
    uint32_t flags;  /* enum zs_tree_node_flag */
} zs_tree_node;

enum zs_tree_node_flag {
    ZS_TREE_TIP = 1,   /* the top of a branch, under an overhang */
    ZS_TREE_FOOT = 2,  /* the root of a tree on the bed */
    ZS_TREE_RESTS = 4, /* the root of a tree that rests on the part */
};

enum zs_tree_clamp {
    ZS_TREE_CLAMP_PART = 1,       /* the node stays out of the part */
    ZS_TREE_CLAMP_LEAN = 2,       /* a segment leans at most the angle */
    ZS_TREE_CLAMP_RADIUS_MIN = 4, /* the radius is at least r_min */
    ZS_TREE_CLAMP_RADIUS_MAX = 8, /* the radius is at most the largest */
    ZS_TREE_CLAMP_REACH = 16,     /* a new foot moved nearer to its tip */
};

/* The nodes of the trees of part `part` (the trees of the user, or of the
 * last slice). A segment goes from each node to its down node. Writes at
 * most cap nodes to out (NULL: none); returns the count of all nodes, or
 * -status. */
ptrdiff_t zs_app_support_tree_nodes(zs_app *app, size_t part, zs_tree_node *out, size_t cap);
/* 1 if part `part` has trees of the user. */
int zs_app_support_tree_edited(const zs_app *app, size_t part);
/* Moves node `node` to (x, y) on the plate (mm). */
int zs_app_support_tree_move_node(zs_app *app, size_t part, uint32_t node, double x, double y, uint32_t *clamp);
/* Sets the radius of node `node` (mm): wider or narrower there. */
int zs_app_support_tree_set_radius(zs_app *app, size_t part, uint32_t node, double r, uint32_t *clamp);
/* Moves the branch of node `node` by (dx, dy) mm, as far as the rules
 * allow. */
int zs_app_support_tree_move_branch(zs_app *app, size_t part, uint32_t node, double dx, double dy, uint32_t *clamp);
/* Deletes the branch of node `node` and the branches over it. Returns the
 * count of nodes that went, or -status. */
ptrdiff_t zs_app_support_tree_delete_branch(zs_app *app, size_t part, uint32_t node);
/* Adds a branch from the bed point (fx, fy) to the point (tx, ty, tz) of
 * the part that needs support (mm): a planned branch, sized by the rules.
 * Returns its tip node, or -status (ZS_INVALID_VALUE: no room there). */
ptrdiff_t zs_app_support_tree_add_branch(zs_app *app, size_t part, double fx, double fy, double tx, double ty, double tz, uint32_t *clamp);
/* The planned trees again for part `part`: 1 if it had trees of the user. */
int zs_app_support_tree_reset(zs_app *app, size_t part);
/* The note of the last drop of the trees of the user, with a 0 at the end
 * (at most cap bytes). Returns its length, or 0 with no note. The note
 * goes after the call. */
size_t zs_app_support_tree_note(zs_app *app, char *buf, size_t cap);

int zs_app_write_3mf(zs_app *app, const uint8_t **out, size_t *out_len);
/* A debug print: the G-code of the layers lo to hi - 1 of the last slice
 * alone, lowered so that layer lo prints on the bed ("print this layer":
 * hi = lo + 1; a few layers to check them before a long print). Each layer
 * keeps its height, lines, and speeds, with the start and end G-code. Free
 * *out with zs_buffer_free. */
int zs_app_debug_gcode(zs_app *app, size_t lo, size_t hi, uint8_t **out, size_t *len);
/* The segment editor: edits of the user on the lines of a slice. kind 0
 * deletes line `path` (an index of zs_app_toolpaths), kind 1 prints it with
 * `value` times its plastic (0.1 to 3). An edit stays apart from the slice,
 * and applies to each new slice that makes the same line again (a strict
 * match of the layer, the feature, and the points to 10 um). Slice again
 * after an add or a remove. Each is one history step. */
int zs_app_edit_add(zs_app *app, size_t path, int kind, double value);
/* A drop of plastic of diameter d mm at (x, y) mm on layer `layer`, to fill
 * a small gap: a short closed loop at the end of the layer (edit kind 2). */
int zs_app_edit_add_dot(zs_app *app, size_t layer, double x, double y, double d);
size_t zs_app_edit_count(const zs_app *app);
/* The key of a line for an edit, read when the user selects it (0: no
 * slice), and the add by key: these work while a new slice runs. */
uint64_t zs_app_path_key(const zs_app *app, size_t path);
int zs_app_edit_add_key(zs_app *app, uint64_t key, size_t layer, int kind, double value);
/* A drop with the z of its layer (read when the layer shows). */
int zs_app_edit_add_dot_z(zs_app *app, size_t layer, double z, double x, double y, double d);
/* The layer of path `path` of the last slice, or -1. */
ptrdiff_t zs_app_path_layer(const zs_app *app, size_t path);
/* applied: 1 if the last slice found the line of the edit, 0 if the line
 * is not there now (the edit waits). Any output can be NULL. */
int zs_app_edit_get(const zs_app *app, size_t i, int *kind, double *value, size_t *layer, int *applied);
int zs_app_edit_remove(zs_app *app, size_t i);
size_t zs_app_layer_count(const zs_app *app);
/* The part on the bed: min x, min y, max x, max y, in mm. */
int zs_app_part_bounds(const zs_app *app, double out[4]);

/* Path features, in zs_layer_paths.path_features. */
enum zs_feature {
    ZS_FEATURE_OUTER_WALL = 0,
    ZS_FEATURE_INNER_WALL = 1,
    ZS_FEATURE_SKIN = 2,
    ZS_FEATURE_INFILL = 3,
    ZS_FEATURE_IRONING = 4,
    ZS_FEATURE_SKIRT = 5, /* skirt and brim */
    ZS_FEATURE_SUPPORT = 6,
    ZS_FEATURE_SUPPORT_INTERFACE = 7,
    ZS_FEATURE_SLOPE_SMOOTHING = 8, /* beads in the steps of a sloped top */
    ZS_FEATURE_SLOPE_IRONING = 9,   /* ironing over the steps of a sloped top */
    ZS_FEATURE_BRIDGE = 10          /* skin over air, held at its sides */
};

/* The paths of one layer, in print order, in mm. Path i has the points
 * from path_ends[i - 1] (0 for i = 0) to path_ends[i], as x, y pairs in
 * points. A closed path connects its last point to its first point. The
 * outline uses the same layout. Free with zs_layer_paths_free. */
typedef struct zs_layer_paths {
    const float *points;
    const uint32_t *path_ends;
    const uint8_t *path_features; /* enum zs_feature */
    const uint8_t *path_closed;
    size_t path_count;
    const float *outline_points;
    const uint32_t *outline_ends;
    size_t outline_count;
    float z;      /* the nozzle height, mm */
    float height; /* the layer height, mm */
    float width;  /* the line width, mm */
    void *owner;  /* private */
} zs_layer_paths;

/* The paths of all layers, for a 3D view. Path i has the points from
 * path_ends[i - 1] (0 for i = 0) to path_ends[i], as x, y pairs in points.
 * Layer j has the paths from layer_ends[j - 1] to layer_ends[j], at the
 * nozzle height layer_z[j], with the layer height layer_height[j] and the
 * line width layer_width[j]. All values are in mm. The arrays stay valid
 * until the next slice, the next model, or zs_app_free. */
typedef struct zs_toolpaths {
    const float *points;
    const uint32_t *path_ends;
    const uint8_t *path_features; /* enum zs_feature */
    const uint8_t *path_closed;
    const float *path_area;     /* the bead cross section, mm^2 */
    const float *path_end_time; /* seconds from the start of the print */
    size_t path_count;
    const uint32_t *layer_ends;
    const float *layer_z;
    const float *layer_height;
    const float *layer_width;
    size_t layer_count;
    const float *path_start_time; /* seconds, at the start of the extrusion */
    const uint8_t *path_retract;  /* 1 if the travel to the path retracted */
    float z_hop;                  /* the nozzle lift of a retracted travel, mm */
    const uint8_t *layer_slowed;  /* 1 if the layer prints slower than planned,
                                     to cool (filament.min_layer_time) */
    /* A path whose nozzle z changes along it (slope smoothing) has
     * path_z_start[i] != ZS_NO_Z. Its point k has the nozzle z
     * point_z[path_z_start[i] + k] and the bead area (mm^2)
     * point_area[path_z_start[i] + k]. The bead is under the nozzle, down
     * to the top of the layer below (layer_z - layer_height). A path whose
     * line width changes along it (Arachne walls) uses the same arrays,
     * with the z of its layer at each point. */
    const uint32_t *path_z_start;
    const float *point_z;
    const float *point_area;
    const float *path_height;     /* the bead height, mm: the layer height, or
                                     the height of the layers of combined
                                     infill (project.infill_layers) */
} zs_toolpaths;
#define ZS_NO_Z 0xffffffffu

int zs_app_toolpaths(const zs_app *app, zs_toolpaths *out);

/* The print as it forms: a physical simulation of the plastic of the last
 * slice. The plastic comes out of the nozzle at the time of each point,
 * rests where the bed or an earlier layer holds it, and hangs (a bridge
 * sags) or falls (a strand with no support) where no plastic holds it. It
 * cools with the fan, and sets. The next layers print on the shape that
 * formed. zs_app_simulate_print runs it on the calling thread (about
 * 1.5 s for a 3DBenchy) and shows the result: zs_app_toolpaths then gives
 * the paths as the plastic set, until zs_app_show_simulated(app, 0) or the
 * next slice. A path that moved has a point for each mass of the
 * simulation, with point_z and point_area. Call zs_view_load to draw it.
 * ZS_NO_RESULT if there is no slice. out can be NULL. */
typedef struct zs_print_sim_stats {
    size_t masses;      /* the masses of the plastic (one for each half
                           bead width of the paths) */
    size_t soft_masses; /* the masses that hung or fell */
    size_t moved;       /* the masses that set more than half a bead height
                           from their place */
    size_t moved_paths; /* the paths with plastic that moved */
    float max_move;     /* the largest move of a mass, mm */
    double mass;        /* the plastic, g */
    size_t peak_soft;   /* the most soft masses at one time */
    size_t steps;       /* the steps of the solver */
} zs_print_sim_stats;
int zs_app_simulate_print(zs_app *app, zs_print_sim_stats *out);
/* Shows the simulated print (on = 1) or the slice (on = 0) in
 * zs_app_toolpaths. ZS_NO_RESULT for on = 1 with no simulation of the last
 * slice. */
int zs_app_show_simulated(zs_app *app, int on);

/* Makes the paths of one layer. It takes a few milliseconds. */
int zs_app_layer_paths(const zs_app *app, size_t layer, zs_layer_paths *out);
void zs_layer_paths_free(zs_layer_paths *paths);

/* ---- inspect a path ---- */

/* What a path is, its real values, why they are what they are, and the
 * settings that change it. For an inspector panel: the user clicks a path
 * in a view (zs_app_pick_layer, zs_view_pick), and the shell shows this. */
typedef struct zs_inspect {
    int feature;          /* enum zs_feature */
    size_t layer;         /* from 0 */
    size_t path;          /* the index in zs_app_toolpaths */
    double z, height;     /* mm */
    double line_width;    /* the planned line width, mm */
    double bead_width;    /* the width of the deposited bead, mm */
    double length;        /* mm */
    double planned_speed; /* mm/s, from the settings */
    double speed;         /* mm/s, with the cooling slow-down */
    double flow;          /* mm^3/s */
    double start_time, end_time; /* s from the start of the print */
    const char *title;    /* for example "Outer wall" */
    const char *explain;  /* the values and why, in plain words, with line breaks */
    const char *settings; /* the setting names that change it, one on each
                             line; a line "# Name" starts a section (Speed,
                             Shape, Material) */
    /* Why the planned speed, the real speed, and the flow are what they
     * are, and how to change them, in plain words with line breaks. A
     * setting is a mark {{name}}, for a link. */
    const char *why_planned, *why_real, *why_flow;
    /* Why the real speed is lower than planned: 0 it is not, 1 the
     * cooling slow-down (filament.min_layer_time), 2 the acceleration on
     * short segments. */
    int slow_reason;
    const char *slow_text; /* the sentence of slow_reason, or "" */
    double fan;            /* the part fan of the line, 0 (off) to 1 (full) */
    double layer_time;     /* the print time of its layer, s */
    double max_flow;       /* the flow limit, mm^3/s (filament.max_flow) */
    int flow_limited;      /* 1 if the flow limit, not the machine, sets the
                              planned speed */
    /* For a support line: the layer and the feature (enum zs_feature) of
     * the part line that it holds up. ZS_NO_PATH and -1: none. */
    uint32_t holds_layer;
    int holds_feature;
} zs_inspect;

/* The measurements of a path at its segment seg (src/app/measure.zig):
 * the segment, the straight edge with its direction, the whole path, the
 * size of the path, and for a circle (shape 1) or an arc (shape 2) its
 * radius, its center, and its angle in degrees. Shape 0: no circle. */
typedef struct {
    double segment_length, edge_length, path_length;
    int closed;
    double size_x, size_y;
    int shape;
    double radius, center_x, center_y, angle;
} zs_measure;
int zs_app_measure(const zs_app *app, size_t path, size_t seg, zs_measure *out);

/* The printability check of the last slice (src/app/checks.zig): each
 * issue has its kind, its severity (0 note, 1 warning, 2 problem), its
 * layer, the path it is about (ZS_NO_PATH: none), a place in mm, a size
 * (flow in %, layer time in s, area in mm², or a count), and its text,
 * text[text_start .. text_start + text_len) of the text of the call. The
 * worst first. Valid until the next slice. */
enum zs_issue_kind { ZS_ISSUE_FLOW = 0, ZS_ISSUE_COOLING = 1, ZS_ISSUE_OVERHANG = 2, ZS_ISSUE_ISLAND = 3, ZS_ISSUE_RETRACTIONS = 4, ZS_ISSUE_BRIDGE = 5 };
#define ZS_NO_PATH 0xffffffffu
typedef struct {
    uint8_t kind;
    uint8_t severity;
    uint32_t layer;
    uint32_t path;
    double x, y;
    double value;
    uint32_t text_start, text_len;
} zs_issue;
int zs_app_checks(zs_app *app, const zs_issue **issues, size_t *n, const char **text);
/* 1 if the check of the last slice has run, so zs_app_checks returns at
 * once; else 0. */
int zs_app_checks_ready(const zs_app *app);

/* The built-in profiles of a group (enum zs_group): their number and
 * their names. Apply one with the text `extends = "name"`
 * (zs_app_profile_apply). */
size_t zs_builtin_profile_count(int group);
const char *zs_builtin_profile_name(int group, size_t i);

/* Gaps: the parts of a layer that should be solid and that no bead covers
 * (src/gaps.zig). x, y are the center in mm; width is the width of a bead
 * that fills the gap; features has a bit (1 << enum zs_feature) for each
 * feature of the beads next to it. Its cells are runs[run_start ..
 * run_start + run_len): rows one cell (0.04 mm) tall, from x0 to x1. */
typedef struct {
    double area, x, y, width;
    uint32_t features;
    bool at_edge;
    uint32_t run_start, run_len;
} zs_gap;
typedef struct {
    float y, x0, x1;
} zs_gap_run;
/* The gaps of layer `layer` of the last slice, the largest first. Valid
 * until the next call for another layer, or the next slice. */
int zs_app_layer_gaps(zs_app *app, size_t layer, const zs_gap **gaps, size_t *n_gaps, const zs_gap_run **runs,
                      size_t *n_runs);
/* The gap of a layer at x, y (mm), or the nearest within 0.3 mm, or -1
 * (cell: the size of its cells, mm). zs_app_gap_cell: the cell size of the
 * gaps of a layer. */
int64_t zs_app_gap_at(zs_app *app, size_t layer, double x, double y, double *cell);
double zs_app_gap_cell(zs_app *app, size_t layer);
/* A setting that can close a gap: the name, the value to try, and why (not
 * NUL-terminated). */
typedef struct {
    const char *name;
    size_t name_len;
    const char *value;
    size_t value_len;
    const char *why;
    size_t why_len;
} zs_gap_step;
/* The settings that can close gap `index` of layer `layer`, the best
 * first: at most `cap` in `out`, and their number in `n`. */
int zs_app_gap_advice(zs_app *app, size_t layer, size_t index, zs_gap_step *out, size_t cap, size_t *n);

/* A plain-text report of path `path`, for "Copy for AI": what it is, its
 * numbers, why, the values of the settings that change it, the printer,
 * the filament, its first points, and its place in the G-code: the file
 * `gcode_file` (the shell writes the G-code of the slice there), the line
 * numbers, and the lines. Valid until the next call or zs_app_inspect. */
int zs_app_line_report(zs_app *app, size_t path, const char *gcode_file, const char **out, size_t *out_len);

/* What a setting changes in the toolpaths. */
typedef struct zs_setting_effect {
    uint32_t features;    /* a bit (1 << enum zs_feature) for each feature
                             whose lines the setting changes; 0 if it
                             changes no line (only the G-code) */
    int first_layer_only; /* 1: only the lines of the first layer */
    const char *note;     /* if features is 0: what the setting changes
                             instead, in plain words */
} zs_setting_effect;

/* The marks after the features in zs_setting_effect.features and
 * zs_view_focus: the seam points, the travel moves, and the
 * retractions. */
#define ZS_MARK_SEAM (1u << 11)
#define ZS_MARK_TRAVEL (1u << 12)
#define ZS_MARK_RETRACT (1u << 13)

int zs_setting_get_effect(const char *name, zs_setting_effect *out);

/* The print time, length, and plastic of the lines of one feature. */
typedef struct zs_feature_stats {
    double time_s;
    double length_mm;
    double volume_mm3;
    size_t paths;
} zs_feature_stats;

#define ZS_FEATURE_COUNT 11
/* Fills out[0 .. ZS_FEATURE_COUNT), in the order of enum zs_feature, for
 * the last slice. ZS_NO_RESULT if there is none. */
int zs_app_feature_stats(const zs_app *app, zs_feature_stats *out);

/* The strings stay valid until the next zs_app_inspect, the next slice, or
 * zs_app_free. */
int zs_app_inspect(zs_app *app, size_t path, zs_inspect *out);

/* A setting that matters for a selected line, and why ("" for the main
 * settings of its feature). The strings are static. */
typedef struct zs_pick {
    const char *name;
    const char *why;
} zs_pick;
/* The settings that matter most for path `path`, best first, at most max:
 * why it is slow (the minimum layer time and the fan, or the acceleration
 * of its feature), the first layer settings on layer 1, the settings of the
 * line that the user changed (for some layers, or for the print or the
 * part), the main settings of its feature, then the other settings that
 * change it. *n gets the count. For the line card of each app. */
int zs_app_inspect_picks(zs_app *app, size_t path, zs_pick *out, size_t max, size_t *n);
/* ---- settings for some layers ---- */

/* Changes a setting for the layers with a top z from z_min to z_max (mm),
 * for example only the layer of a selection. The z range, and not layer
 * numbers, keeps the change on the same part of the print after a change
 * of the layer height. Only settings with per_layer can change. An
 * override with the same range and setting is replaced. The next slice
 * uses it (zs_app_request_slice). A new model clears all overrides. */
int zs_app_override_set(zs_app *app, double z_min, double z_max, const char *name, const char *value);
/* The overrides: their number, and override i (its range, its setting,
 * and its value; the strings are not NUL-terminated and stay valid until
 * the next change of the overrides). */
typedef struct {
    double z_min, z_max;
    const char *name;
    size_t name_len;
    const char *value;
    size_t value_len;
} zs_override;
size_t zs_app_override_count(const zs_app *app);
int zs_app_override_get(const zs_app *app, size_t i, zs_override *out);
/* Removes the override of a setting for exactly the range z_min..z_max.
 * Returns 1 if there was one. */
int zs_app_override_remove(zs_app *app, double z_min, double z_max, const char *name);

/* Layer profiles: a name for a layer range (z_min..z_max, as for the
 * overrides). The overrides with the same range are the changes of the
 * profile. A 3MF file keeps them. A new model clears them. */
typedef struct {
    double z_min, z_max;
    const char *name;
    size_t name_len;
} zs_layer_profile;
int zs_app_profile_set(zs_app *app, double z_min, double z_max, const char *name);
size_t zs_app_profile_count(const zs_app *app);
int zs_app_profile_get(const zs_app *app, size_t i, zs_layer_profile *out);
/* Removes the profile of the range and all its overrides. Returns the
 * number of overrides removed. */
size_t zs_app_profile_remove(zs_app *app, double z_min, double z_max);

/* Removes the overrides of a setting that cover z. Returns how many. */
size_t zs_app_override_clear_at(zs_app *app, double z, const char *name);
/* 1 if an override of the setting covers z. */
int zs_app_override_at(const zs_app *app, double z, const char *name);
/* The value of a setting for the layers at z, with the overrides. The same
 * buffer rules as zs_app_setting_get. */
int zs_app_setting_get_at(const zs_app *app, double z, const char *name, char *buf, size_t cap, size_t *out_len);

/* ---- the plate: more than one part ---- */

/* zs_app_load_stl replaces all parts; zs_app_add_stl adds one. A new part
 * keeps the place of its file if it is on the bed there and touches no
 * other part (unless project.placement is center), else it goes to a free
 * place. Returns the index of the part, or minus a zs_status. */
ptrdiff_t zs_app_add_stl(zs_app *app, const char *name, const void *data, size_t len);

typedef struct zs_part {
    const char *name;   /* valid until the plate changes */
    double x, y;        /* the center of the footprint on the bed, mm */
    double rotation;    /* degrees around the vertical axis */
    double size_x, size_y, size_z; /* the footprint and the height, mm */
    double scale_x, scale_y, scale_z; /* along the axes of the file, 1 = 100 % */
} zs_part;

/* A copy of part i (its mesh, pose, scale, settings, and modifier
 * volumes) at a free place on the bed. Returns its index, or a negative
 * status. */
ptrdiff_t zs_app_part_duplicate(zs_app *app, size_t i);
/* Splits part i into its separate bodies (the sets of faces that share no
 * vertex), each a part at its place, with the settings of part i. The new
 * parts are at index i on. Returns their count, 0 for a part of one body,
 * or -status. */
ptrdiff_t zs_app_part_split(zs_app *app, size_t i);
/* Cuts part i with a level plane at height z (mm above the bed): the part
 * below and the part above, each closed (with a cap), with the settings of
 * part i, at index i and i + 1. flip != 0 turns the upper part over onto
 * its cut face. pegs > 0: at most that many holes for pegs in both parts
 * (where the part is wide and deep enough), and the pegs (diameter peg_d
 * mm, 0: 5 mm) as parts at the end of the plate, to line the parts up when
 * they are joined. Returns the count of new parts (2 and the pegs), 0 if
 * the plane misses the part, or -status. zs_view_set_cut shows the plane
 * while the user picks the height. */
ptrdiff_t zs_app_part_cut(zs_app *app, size_t i, double z, int flip, int pegs, double peg_d);
/* 1 if each part of the plate is on the bed and overlaps no other part. A
 * cut arranges the plate when a new part has no free place; after it, 0
 * means the parts do not fit on this bed: say so, and offer to move parts
 * to another plate. */
int zs_app_plate_fits(const zs_app *app);
/* A picture of the parts of the plate: a PNG of w by h pixels (at most
 * 1024), from the front right and above, in the filament color, on a clear
 * background. It works with no slice. ZS_NO_MODEL for an empty plate. Free
 * the bytes with zs_buffer_free. */
int zs_app_thumbnail_png(const zs_app *app, uint32_t w, uint32_t h, uint8_t **out, size_t *out_len);
/* A name for the G-code file of the last slice, with no extension: the
 * model (its extension dropped), the plate (when plate > 0, 1-based), the
 * layer height, the material, the printer, and the time, for example
 * "3DBenchy_0.2mm_PLA_MK4_50m". The same name in each app. */
int zs_app_gcode_name(const zs_app *app, const char *model, size_t plate, char *buf, size_t cap, size_t *out_len);

size_t zs_app_part_count(const zs_app *app);
int zs_app_part_get(zs_app *app, size_t i, zs_part *out);
/* The settings of a part from its 3MF file (a Cura project) and its
 * modifier volumes, one on each line: each Cura setting with the zslice
 * setting that it becomes, or why zslice does not use it. Empty for a
 * part with no settings. The same buffer rules as zs_app_setting_get. */
int zs_app_part_settings(const zs_app *app, size_t i, char *buf, size_t cap, size_t *out_len);
/* The settings of part i and of its volumes that zslice does not use, one
 * a line: "key\tvalue\twhy". A near value (the nearest infill pattern)
 * is not in the list. The same buffer rules as zs_app_setting_get. */
int zs_app_part_unused(const zs_app *app, size_t i, char *buf, size_t cap, size_t *out_len);
/* The zslice settings of Cura settings for the whole plate, from the
 * settings now. text: one "key=value" a line (Cura keys:
 * support_enable=false). Each line of the result is one of
 * "set\tname\tvalue", "near\tkey\tvalue\twhy" (zslice uses a near
 * value), or "unused\tkey\tvalue\twhy" (zslice cannot use the key). It
 * changes no setting. The same buffer rules as zs_app_setting_get. */
int zs_app_cura_settings(const zs_app *app, const char *text, char *buf, size_t cap, size_t *out_len);
/* on != 0: the parts of a 3MF file keep their places in the file, also
 * near the edge of the bed or near another part (a plate that another
 * program packed). 0 (the default): a part that does not fit with the
 * part gap goes to a free place. */
int zs_app_set_keep_places(zs_app *app, int on);
/* The settings of one part: a zslice setting that this part prints with,
 * not the value of the plate (value NULL: the value of the plate again).
 * The part slices as its own job, so any setting with per_part = 1
 * applies to it: walls, layer height, seam, speeds, infill, skin,
 * support. A 3MF save keeps them. zs_app_part_setting_get gives ZS_NO_RESULT when the part
 * has the value of the plate. */
int zs_app_part_setting_set(zs_app *app, size_t i, const char *name, const char *value);
int zs_app_part_setting_get(const zs_app *app, size_t i, const char *name, char *buf, size_t cap, size_t *out_len);
/* Moves a part (the center of its footprint) to (x, y) on the bed. */
int zs_app_part_move(zs_app *app, size_t i, double x, double y);
/* Sets the turn of a part, in degrees, around the center of its footprint. */
int zs_app_part_rotate(zs_app *app, size_t i, double degrees);
/* The scale of a part along the axes of its file (1 = 100 %; a negative
 * value mirrors). */
int zs_app_part_scale(zs_app *app, size_t i, double sx, double sy, double sz);
/* Turns a part by `degrees` about the X (axis 0) or Y (axis 1) axis of the
 * bed; it then rests on the bed. */
int zs_app_part_turn(zs_app *app, size_t i, int axis, double degrees);
/* Part `part` slices coarse in the next slices (thicker layers, one wall,
 * no skin, no infill), a few times faster; part < 0: none. For the live
 * slice of a part while a turn ring drags; the full slice comes after the
 * drag. ZS_OUT_OF_RANGE for no such part. */
int zs_app_set_coarse_part(zs_app *app, int part);
/* Physics: part i falls over if it cannot stand as it is (its center of
 * mass past the area it stands on), and rolls onto a face until it rests.
 * With support on, the support holds it, and it stays. Call it when a turn
 * ends (the release of a ring, a turn key). Returns the angle of the fall in
 * degrees (0: it stands; an app can animate the fall), or -status. */
double zs_app_part_settle(zs_app *app, size_t i);
/* 1 if part i can stand as it is, 0 if it would fall over, whatever the
 * support setting (with support on, the support holds it in place). */
/* The fall of a part, for a shell that shows it (src/rigid.zig: a rigid
 * body on the bed, with friction). zs_app_fall_start: 1 if part i falls,
 * 0 if it stands or support holds it. zs_app_fall_step runs dt seconds and
 * writes 10 values to out: the turn qx, qy, qz, qw about the pivot px, py,
 * pz, then the move mx, my, mz; give them to zs_view_part_preview (flags
 * 0). It returns 1 while the part falls, 0 when it rests (the part is at
 * its new place, flush on a face: one history step; slice again), or -1
 * with no fall. zs_app_fall_cancel ends it with no change. */
int zs_app_fall_start(zs_app *app, size_t part);
int zs_app_fall_step(zs_app *app, double dt, double *out);
void zs_app_fall_cancel(zs_app *app);
/* The first part that cannot stand as it is, or -1: with support off, or
 * on the support trees of the user that it has (their tips on the bed
 * hold it). Call it after a change of a setting or of the plate (support
 * turned off under a turned part, a branch deleted), and start its fall. */
ptrdiff_t zs_app_fall_pending(zs_app *app);
/* The hand: zs_app_grab_start takes part i at a bed point on its surface
 * (1 if it did), zs_app_grab_move moves the hand, and zs_app_grab_end lets
 * go. The part follows the hand as a real object (it swings and turns
 * about the point held), and on release it keeps its speed, falls, and
 * rests flush on the plate. Run zs_app_fall_step each frame from the
 * start, as for a fall. */
int zs_app_grab_start(zs_app *app, size_t part, double x, double y, double z);
void zs_app_grab_move(zs_app *app, double x, double y, double z);
void zs_app_grab_turn(zs_app *app, double ax, double ay, double az, double degrees);
void zs_app_grab_end(zs_app *app);
/* The hand holds the orientation of the part it took: zs_app_grab_turn
 * turns it about an axis of the bed. On release with support off, the part
 * falls and rests; with support on, it keeps the orientation that the
 * hand gave it, goes down on the bed, and support holds it. A part thrown
 * past the edge of the bed stops at the edge. */
int zs_app_part_stands(zs_app *app, size_t i);
/* "This side on the bed": the side of the part nearest to the bed point
 * (x, y, z), for example a picked line, goes down. */
int zs_app_part_put_down_at(zs_app *app, size_t i, double x, double y, double z);
/* Turns a part to its best orientation. */
enum zs_place_mode {
    ZS_PLACE_SMART = 0,        /* less support, more on the bed, low */
    ZS_PLACE_LESS_SUPPORT = 1, /* the least support */
    ZS_PLACE_STRENGTH = 2,     /* strong along `axis` (0 X, 1 Y, 2 Z of the file) */
};
int zs_app_part_place(zs_app *app, size_t i, int mode, int axis);
/* The orientation and the scale of the file again. */
int zs_app_part_reset(zs_app *app, size_t i);
/* Plates: the app has one or more plates. The active plate is the one that
 * the calls above change, that slices, and that the views show; each
 * plate keeps its own parts, changes, and support marks. A switch stops a
 * slice; call zs_app_request_slice after it. */
size_t zs_app_plate_count(const zs_app *app);
size_t zs_app_plate_active(const zs_app *app);
size_t zs_app_plate_parts(const zs_app *app, size_t i);
/* A new empty plate after the others; it becomes the active plate. */
ptrdiff_t zs_app_plate_add(zs_app *app);
int zs_app_plate_select(zs_app *app, size_t i);
/* Removes plate i and its parts (the last plate stays, empty). */
int zs_app_plate_remove(zs_app *app, size_t i);

/* Smart placement of all parts, then an arrange. 1 if they all fit. */
int zs_app_plate_smart_place(zs_app *app);
int zs_app_part_remove(zs_app *app, size_t i);
/* Packs all parts on the bed, the largest first. 1 if all fit. */
int zs_app_plate_arrange(zs_app *app);
int zs_app_plate_clear(zs_app *app);
/* The part under (x, y) on the bed, or -1. */
ptrdiff_t zs_app_part_at(const zs_app *app, double x, double y);
/* The part of a path of the toolpaths, or -1. */
ptrdiff_t zs_app_part_of_path(const zs_app *app, size_t path);

/* ---- saved state ---- */

enum zs_group { ZS_GROUP_MACHINE = 0, ZS_GROUP_FILAMENT = 1, ZS_GROUP_PROJECT = 2 };

/* Writes the settings of a group that differ from the defaults, as a
 * profile text (TOML), with the help of each setting as a comment. A shell
 * saves it to keep the settings after a restart. The same buffer rules as
 * zs_app_setting_get. */
int zs_app_state_write(const zs_app *app, int group, char *buf, size_t cap, size_t *out_len);
/* The settings of a group that differ from the built-in defaults, as a
 * profile. For the project group, the quality profile and the changes of
 * this print together (zs_app_state_write has the changes only). */
int zs_app_profile_write(const zs_app *app, int group, char *buf, size_t cap, size_t *out_len);
/* Refinements (src/app/refine.zig): the first slice is a guide.
 * zs_app_refine_records gives the changes of the plate from the guide,
 * one record on each line. The app keeps a store of the records of its
 * projects on the device: zs_refine_merge replaces the records of one
 * project. zs_app_refine_suggest gives the refinements that the user made
 * in at least two other projects with the same material and nozzle
 * ("kind\tzone\tkey\tvalue\tcount\tz_lo\tz_hi"), and
 * zs_app_refine_apply applies one of them (one history step; slice
 * again after it). */
int zs_app_refine_records(zs_app *app, char *buf, size_t cap, size_t *out_len);
int zs_refine_merge(const char *store, size_t store_len, const char *project, const char *records, size_t records_len, char *buf, size_t cap, size_t *out_len);
int zs_app_refine_suggest(zs_app *app, const char *store, size_t store_len, const char *project, char *buf, size_t cap, size_t *out_len);
int zs_app_refine_apply(zs_app *app, const char *line, size_t len);

/* The history of changes (src/app/history.zig). zs_app_history_facts
 * writes the state as lines of "scope\tkey\tvalue" (only the values that
 * differ from the start). zs_history_diff gives the changes from one state
 * to the next, one on each line ("scope\tkey\told\tnew"), and
 * zs_history_describe writes them in words ("Part Benchy\tWall count the
 * print value -> 4"). The scopes: "machine", "filament", "print",
 * "part:<name>", "layers:<z_min>:<z_max>". zs_app_history_revert undoes one
 * change line and keeps the others (ZS_NOT_SUPPORTED for a move of a
 * part); slice again after it. The same buffer rules as
 * zs_app_setting_get. The undo list of the app (zs_app_history_commit and
 * the functions after it) keeps the steps. */
int zs_app_history_facts(const zs_app *app, char *buf, size_t cap, size_t *out_len);
int zs_history_diff(const char *before, size_t before_len, const char *after, size_t after_len, char *buf, size_t cap, size_t *out_len);
int zs_history_describe(const char *changes, size_t len, char *buf, size_t cap, size_t *out_len);
/* zs_history_describe with the layer numbers of the last slice of the app
 * ("Layers 86 and up"). */
int zs_app_history_describe(const zs_app *app, const char *changes, size_t len, char *buf, size_t cap, size_t *out_len);
int zs_app_history_revert(zs_app *app, const char *change, size_t len);
/* The kind of a step, from its changes, for its look in a timeline: "walls",
 * "infill", "surface" (top and bottom skin, ironing, slope smoothing),
 * "speed", "heat" (temperatures, cooling, filament, flow), "support",
 * "layers", "move", "rotate", "scale", "add", "remove", "quality",
 * "printer", or "other". A static string. */
const char *zs_history_kind(const char *changes, size_t len);

/* The undo list. Each app keeps a list of steps, the oldest first, and the
 * step now (zs_app_history_current). The steps after the step now are the
 * redo steps. A step has the settings of the three groups, the quality
 * profile, and the plate (as a 3MF file).
 *
 * Each change through this API notes its key: the name of one setting
 * (zs_app_setting_set, zs_app_global_setting_set, zs_app_override_set), or
 * "more" for a profile, a quality, the plate, a part, a mark, or a
 * project. The shell keeps a timer: it calls zs_app_history_commit 400 ms
 * after the last change. The commit makes a step if the state differs
 * from the step now; the redo steps go. The first commit takes the start
 * (step 0). The shell gives the time (ms since 1970, for the list).
 *
 * An edit of one setting is one step while its editor has the focus: the
 * shell calls zs_app_history_set_focus with the name of the setting of the
 * editor with the focus (NULL: none). A commit of changes of only that
 * setting, after a step of only that setting, amends that step. If the
 * value goes back to the value before the edit, the step goes. A move of
 * the focus ends the edit: the changes so far become a step.
 *
 * Undo, redo, goto, and truncate commit first, then restore the state of
 * the new step: the plate if it differs, then the quality profile and each
 * group of settings that differs. Their changes are not noted. They return
 * 0 if the step did not change, else the bits of enum zs_history_restored.
 * The shell then updates its editors, saves the groups that changed, and
 * slices again.
 *
 * Limits: 100 steps before the step now, and 200 MB of 3MF files in them.
 * The oldest steps go first. Steps with the same plate share its file. */
enum zs_history_restored {
    ZS_HISTORY_MOVED = 1,     /* the step now changed */
    ZS_HISTORY_PLATE = 2,     /* the plate loaded again (or cleared) */
    ZS_HISTORY_MACHINE = 4,   /* the group restored: 4 << enum zs_group */
    ZS_HISTORY_FILAMENT = 8,
    ZS_HISTORY_PROJECT = 16,
    ZS_HISTORY_QUALITY = 32,  /* the quality profile changed */
    ZS_HISTORY_DROPPED = 64,  /* truncate: the later steps went */
};
/* Ends the step of the changes so far. Returns 1 if a step was added,
 * amended, or dropped (the shell then shows the list again). */
int zs_app_history_commit(zs_app *app, int64_t now_ms);
/* The setting whose editor has the focus, or NULL. A new focus commits
 * the changes that wait; returns 1 if that commit changed the list. */
int zs_app_history_set_focus(zs_app *app, const char *key, int64_t now_ms);
int zs_app_history_undo(zs_app *app, int64_t now_ms);
int zs_app_history_redo(zs_app *app, int64_t now_ms);
/* Goes to step i (0 is the start). */
int zs_app_history_goto(zs_app *app, size_t i, int64_t now_ms);
/* Clears the history after step i: goes to step i first if it is not the
 * step now, then drops the later steps (redo cannot bring them back). */
int zs_app_history_truncate(zs_app *app, size_t i, int64_t now_ms);
/* Drops all steps, for example for a new file. The next commit takes the
 * start. */
void zs_app_history_reset(zs_app *app);
/* The number of steps (0 before the first commit), and the step now. */
size_t zs_app_history_count(const zs_app *app);
size_t zs_app_history_current(const zs_app *app);
/* 1 if changes wait for a commit. */
int zs_app_history_pending(const zs_app *app);
/* Step i: the time of its commit, its kind (zs_history_kind, or "start"
 * for step 0), and its changes from step i - 1: as lines of
 * zs_history_diff, and in words (zs_app_history_describe). Both are ""
 * for step 0. The strings are not 0-terminated (except kind). They are
 * valid until the next zs_app_history_step or the next change of the
 * list. */
typedef struct {
    int64_t time_ms;
    const char *kind;
    const char *changes;
    size_t changes_len;
    const char *text;
    size_t text_len;
} zs_history_step;
int zs_app_history_step(zs_app *app, size_t i, zs_history_step *out);
/* Sets all settings of a group to the built-in defaults: for example
 * before the profile of an other printer. */
int zs_app_group_reset(zs_app *app, int group);
/* Applies a profile text to a group: the text of zs_app_state_write, or a
 * profile that the user wrote. On an error, message (can be NULL) gets the
 * line and the reason, and the settings do not change. */
int zs_app_profile_apply(zs_app *app, int group, const char *text, size_t len, char *message, size_t cap);

/* The cascade of the settings, the lowest first: a higher level replaces
 * the value of a lower one. A part has its own values on top
 * (zs_app_part_setting_set). */
enum zs_level {
    ZS_LEVEL_DEFAULT = 0,  /* the built-in value */
    ZS_LEVEL_GLOBAL = 1,   /* the global settings of the user */
    ZS_LEVEL_MACHINE = 2,  /* the printer profile */
    ZS_LEVEL_FILAMENT = 3, /* the filament profile */
    ZS_LEVEL_QUALITY = 4,  /* the quality profile (fine, standard, ...) */
    ZS_LEVEL_PRINT = 5,    /* the changes for this print */
    ZS_LEVEL_PART = 6      /* the value of one part */
};
/* Sets the quality profile: a project profile text (with extends) and its
 * name. keep_edits: the changes of this print stay on top; else they go.
 * zs_app_state_write of the project group then writes only the changes
 * of this print, and a reset of the group (zs_app_group_reset) goes back
 * to the quality profile. */
int zs_app_quality_set(zs_app *app, const char *name, const char *text, size_t len, bool keep_edits, char *message, size_t cap);
const char *zs_app_quality_name(const zs_app *app);
/* The global settings of the user: a project profile text, under the
 * quality profile. */
int zs_app_global_set(zs_app *app, const char *text, size_t len, char *message, size_t cap);
/* One global setting (a project setting for all prints): set it, or
 * clear it with value NULL; the changes of this print stay on top.
 * zs_app_global_get gives its global value (the default if not set);
 * zs_app_global_write gives all of them as a profile text. */
int zs_app_global_setting_set(zs_app *app, const char *name, const char *value);
int zs_app_global_get(const zs_app *app, const char *name, char *buf, size_t cap, size_t *out_len);
int zs_app_global_write(const zs_app *app, char *buf, size_t cap, size_t *out_len);
/* Formulas: zs_app_setting_set with a value that starts with "=" (for
 * example "= {line_width} * 2") makes the value of the setting follow
 * the other settings (see src/expr.zig); a plain value removes the
 * formula. zs_app_formula_get gives the text after "=", or ZS_NO_RESULT.
 * zs_app_formulas_write and zs_app_formulas_read keep them in the state
 * of a shell. */
int zs_app_formula_get(const zs_app *app, const char *name, char *buf, size_t cap, size_t *out_len);
int zs_app_formulas_write(const zs_app *app, char *buf, size_t cap, size_t *out_len);
int zs_app_formulas_read(zs_app *app, const char *text, size_t len);

/* Where the value of a setting comes from: its level (enum zs_level) and
 * the name of the profile of that level (can be ""). part < 0: the plate;
 * else part i (ZS_LEVEL_PART if the part has its own value). */
int zs_app_setting_source(const zs_app *app, ptrdiff_t part, const char *name, int *level, char *profile, size_t cap);
/* The value of a setting with no change of this print: the value that a
 * reset gives. */
int zs_app_setting_base_get(const zs_app *app, const char *name, char *buf, size_t cap, size_t *out_len);

/* The path of a feature (enum zs_feature) nearest to (x, y) mm on a layer
 * (or on the last layer, if there are fewer), at any distance, or
 * (size_t)-1. To keep a selection after a new slice moves its line. */
size_t zs_app_pick_feature(const zs_app *app, size_t layer, int feature, double x, double y);
/* The path of a layer nearest to (x, y) mm, within twice the line width,
 * or (size_t)-1. */
size_t zs_app_pick_layer(const zs_app *app, size_t layer, double x, double y);

/* ---- the 3D view ---- */

/* On Linux, the core draws the 3D view of a slice into a native surface
 * that the shell gives: a Wayland wl_surface or an X11 window. The core
 * loads Vulkan at run time, so the shell does not link it. Without Vulkan,
 * zs_view_new returns ZS_NOT_SUPPORTED. In wasm and on macOS, the core
 * does not draw: the view keeps the frame data (zs_view_web_frame), and
 * the shell draws it with WebGL2 or Metal. Call the view functions from
 * the UI thread. */

enum zs_surface_kind {
    ZS_SURFACE_WAYLAND = 1, /* display: struct wl_display *, surface: struct wl_surface * */
    ZS_SURFACE_XLIB = 2,    /* display: Display *, window: Window */
    ZS_SURFACE_WEB = 3,     /* wasm and macOS: no surface; the shell reads
                               the frame data (zs_view_web_frame) and draws it */
    ZS_SURFACE_FRAME = 3    /* the same as ZS_SURFACE_WEB, for a native shell */
};

typedef struct zs_surface {
    int kind; /* enum zs_surface_kind */
    void *display;
    void *surface;
    uint64_t window;
} zs_surface;

typedef struct zs_view zs_view;

/* Looks at the point (x, y, z) from the side that faces (nx, ny, nz), from
 * dist mm; the camera moves there in steps (zs_view_animate). For a double
 * click on a side of a part. */
void zs_view_look_at(zs_view *view, float x, float y, float z, float nx, float ny, float nz, float dist);
/* A double click at the pixel (px, py): the camera turns to face the side
 * of the print there, and zooms to it, from 1.4 times `size` mm (at least
 * 20 mm; 0: the size of the print; give the size of the part when the
 * shell knows it). The normal comes from the surface around the pixel.
 * Returns 1 if the camera moves, 0 if the pixel shows no side of the print
 * (the shell then resets the view). */
int zs_view_look_at_side(zs_view *view, float px, float py, float size);

/* Makes a view for the surface, width_px x height_px pixels. */
int zs_view_new(const zs_surface *surface, uint32_t width_px, uint32_t height_px, zs_view **out);
void zs_view_free(zs_view *view);
/* The size in pixels: the logical size times the scale. */
void zs_view_resize(zs_view *view, uint32_t width_px, uint32_t height_px);
/* Reads the toolpaths of the last slice, and the bed size. Call it after
 * ZS_EVENT_SLICED. */
int zs_view_load(zs_view *view, const zs_app *app);
/* Shows the layers from 0 to `layer`. */
void zs_view_set_layer(zs_view *view, size_t layer);
/* Shows the layers lo to hi (the layers under lo do not show, so the
 * inside of the part at lo is visible), and stops the replay. */
/* With a highlight: on = 1 shows the other beads as ghosts, so only the
 * selected path is solid. on = 0 (the default) keeps their colors. */
void zs_view_isolate(zs_view *view, int on);
struct zs_printers; /* the printer library, below */
/* Shows the bed model of model i of a library under the plate: the bytes of
 * its files (zs_printers_bed; NULL and 0 for a missing file). The view
 * places it from the library record and the bed size of the last
 * zs_view_load, and keeps it until the next call. The data goes to the GPU
 * once. ZS_NO_RESULT if the model has no bed model, ZS_INVALID_MESH if the
 * mesh does not read (a texture that does not read is left out). */
int zs_view_set_bed(zs_view *view, const struct zs_printers *lib, size_t i, const uint8_t *mesh, size_t mesh_len,
                    const uint8_t *texture, size_t texture_len);
/* Shows the bed as the grid alone. */
void zs_view_clear_bed(zs_view *view);
void zs_view_set_layer_range(zs_view *view, size_t lo, size_t hi);
/* Turns the camera by a drag of dx, dy pixels, as in Cura and Tinkercad:
 * around the vertical axis and a tilt. The bed stays level, and the tilt
 * stops at 89 degrees above and below the bed. */
void zs_view_orbit(zs_view *view, float dx, float dy);
/* Moves the camera nearer (factor < 1) or further (factor > 1). */
void zs_view_zoom(zs_view *view, float factor);
/* Zooms toward the pixel (px, py): the point under it stays in place. The
 * camera moves there smoothly: call zs_view_animate on each frame. */
void zs_view_zoom_at(zs_view *view, float factor, float px, float py);
/* Moves the camera smoothly back to the start view (see zs_view_animate). */
void zs_view_reset_smooth(zs_view *view);
/* Moves the camera toward its goal for dt seconds (the time since the last
 * frame). Returns 1 while the camera still moves, so the shell asks for
 * one more frame, and 0 when it is at rest. Drags move the camera at once. */
int zs_view_animate(zs_view *view, double dt);
/* Moves the view by a drag of dx, dy pixels: the scene follows the pointer. */
void zs_view_pan(zs_view *view, float dx, float dy);
/* A frame on the bed around a selected part; none if x1 < x0. */
void zs_view_part_box(zs_view *view, double x0, double y0, double x1, double y1);
/* The point of the bed under the pixel (px, py) of a 3D view. 0 if none. */
/* The box of path `path` on the screen, in pixels (x0, y0, x1, y1): a card
 * next to a line keeps out of it. 0 if it is not in front of the camera. */
int zs_view_path_rect(const zs_view *view, size_t path, float out[4]);
int zs_view_bed_point(const zs_view *view, float px, float py, double *x, double *y);
/* The point under the pixel on the level plane at height z (mm), for the
 * hand that carries a part (zs_app_grab_move). 0 if not under the pixel. */
int zs_view_plane_point(const zs_view *view, float px, float py, double z, double *x, double *y);
/* The point of the print under the pixel (px, py), for a measure tape: on
 * the surface of the first line that the pixel shows, else on the bed. With
 * snap, the end of a line within 12 pixels. out gets x, y, z (mm). 0 if
 * the pixel shows neither. */
int zs_view_surface_point(const zs_view *view, float px, float py, int snap, double out[3]);
/* The points of the measure tape: n is 0 (none), 1, or 2; pts has 3 values
 * (x, y, z) for each point. The view draws a mark at each point and a line
 * between two. */
void zs_view_set_measure(zs_view *view, size_t n, const double *pts);

/* The rings of the Turn tool around (x, y, z), radius mm (0: none). The view
 * draws them: red about X, green about Y, blue about Z; the ring of a turn
 * in progress is thicker. The shells use the center (x, y, size_z / 2) of
 * the part and the radius 0.62 * the largest size + 4 mm. */
void zs_view_set_rings(zs_view *view, double x, double y, double z, double radius);
/* The plane of a cut (zs_app_part_cut): the box x0, y0, x1, y1 (mm) at
 * height z, drawn in orange. A box with no area hides it. */
void zs_view_set_cut(zs_view *view, double x0, double y0, double x1, double y1, double z);
/* The support areas that the view draws (the support editor). A load of
 * the app fills them from its areas (zs_app_support_area_*). A shell that
 * edits an area clears them and adds each again: n points of x, y, z (mm)
 * in pts, the kind (enum zs_mark_kind: block is red, the others blue), and
 * flags: 1 closed (an area, with lines across it; else the path that the
 * user draws now, with a large first point), 2 selected (a thicker line
 * and its points), 4 its points, 8 bare (a path in the air, as the nodes
 * of the support trees: no lines across it; with 4, only a small bead at
 * each point, and no lines). */
void zs_view_support_clear(zs_view *view);
int zs_view_support_add(zs_view *view, const double *pts, size_t n, int kind, int flags);
/* on != 0: zs_view_surface_point and the picks skip the support lines, so
 * a click finds the part under them (the Support tool). */
void zs_view_pick_skip_support(zs_view *view, int on);
/* The ring under the pixel within tol pixels: 0 X, 1 Y, 2 Z, or -1. */
int zs_view_ring_at(const zs_view *view, float px, float py, float tol);
/* Starts a turn on the ring of axis at the pixel of the press. 1 if it
 * started. */
int zs_view_ring_press(zs_view *view, int axis, float px, float py);
/* The turn since the press in degrees, in steps of step_deg (0: none), in
 * the sense of the ring on the screen, so the part turns with the pointer.
 * Send the difference to the last value (zs_app_part_turn), with
 * zs_set_changed_held, and zs_set_release at the end. */
double zs_view_ring_drag(const zs_view *view, float px, float py, float step_deg);
/* The end of a turn. */
void zs_view_ring_release(zs_view *view);
/* The pixel of a point of the world (mm), or 0 if it is behind the camera
 * (to grab an end of the measure tape). */
int zs_view_pixel_of(const zs_view *view, double x, double y, double z, float *px, float *py);
/* Shows the beads of some features clearly, and fades the others: a bit
 * (1 << enum zs_feature) for each feature, or 0 to end the focus. Only the
 * beads with a top at or under zmax (mm) are in focus; a negative zmax is
 * all layers. For a settings browser: zs_setting_get_effect gives the bits. */
/* Returns 1 if the focus shows lines, 0 if the plate has no line of these
 * features: the view then shows the whole print (say "no lines of this
 * setting on this plate"), and never shows an empty view. */
int zs_view_focus(zs_view *view, uint32_t features, double zmax);
/* Turns the camera freely around the axes of the screen, by a drag of dx,
 * dy pixels. Drags in turn can roll the view, so the part can turn to any
 * direction. zs_view_orbit keeps the bed level; this does not. */
/* Shows the gaps of a layer (see zs_app_layer_gaps) in red, or none for a
 * negative layer. Call it again after a new slice. */
void zs_view_show_gaps(zs_view *view, zs_app *app, int64_t layer);
/* The index of the shown gap under the pixel, or -1. */
int64_t zs_view_gap_at(const zs_view *view, zs_app *app, float px, float py);
/* The gaps of a layer from their runs, for a view with no app (the web
 * page, whose app is in a worker): runs as zs_app_layer_gaps gives them,
 * the top z of the layer, and the cell size (zs_app_gap_cell). A negative
 * layer: none. zs_view_layer_point gives the point (mm) under a pixel on
 * the top of a layer, for zs_app_gap_at. */
void zs_view_set_gap_runs(zs_view *view, int64_t layer, float layer_z, const zs_gap_run *runs, size_t n, double cell);
int zs_view_layer_point(const zs_view *view, float px, float py, float layer_z, double *x, double *y);

void zs_view_rotate(zs_view *view, float dx, float dy);
/* Turns the camera around the vertical axis only (a turntable), by a drag
 * of dx pixels. */
void zs_view_turn(zs_view *view, float dx);
/* Returns the camera to the start view around the part. */
void zs_view_reset(zs_view *view);
/* The camera, for a restore after a reload: 8 floats, the target (x, y, z),
 * the rotation (a quaternion x, y, z, w), and the distance. Set it back at
 * once with zs_view_set_camera (a bad value leaves the camera as it is). */
void zs_view_get_camera(const zs_view *view, float out[8]);
void zs_view_set_camera(zs_view *view, const float in[8]);
enum zs_view_mode {
    ZS_VIEW_PRINT = 0,      /* the filament color: the print as it will look */
    ZS_VIEW_FEATURES = 1,   /* one color for each feature */
    ZS_VIEW_SPEED = 2,      /* the real speed of each path (a ramp) */
    ZS_VIEW_FLOW = 3,       /* the plastic flow of each path, mm^3/s */
    ZS_VIEW_LAYER_TIME = 4, /* the time of each layer, s */
    ZS_VIEW_WIDTH = 5       /* the bead width, mm */
};

/* The range of the ramp of a value mode (in its unit), after
 * zs_view_load. Returns 1 for a value mode, 0 for the others. The ramp
 * goes from blue (min) through green and yellow to red (max); for the
 * layer time, red is the shortest layer. */
int zs_view_legend(const zs_view *view, double *min, double *max);

/* The colors of the view. Call zs_view_load again after a change. */
/* The dark look (on != 0): a dark background, grid, and bed, for the dark
 * mode of the system. */
void zs_view_set_dark(zs_view *view, int on);
/* A frame shell (WebGL, Metal) whose bead shader draws mesh level 2 as a
 * ribbon that faces the camera (see src/render/shaders/box.vert, tv.w = 2)
 * calls this with on != 0. The view then draws the beads a few pixels
 * wide with it. Off at the start for a frame shell; the Vulkan backend
 * always has it. */
void zs_view_set_ribbons(zs_view *view, int on);
/* Shows part `part` of the plate (the part index of zs_app) turned and
 * moved in the view only: the turn is the unit quaternion (qx, qy, qz,
 * qw) about the point (px, py, pz), then the part moves by (mx, my, mz)
 * mm. Flag ZS_PREVIEW_ON_BED also puts its lowest bead on the bed. The
 * beads of the last slice turn at once, for the drag of a turn ring or
 * the fall of a part; the next zs_view_load (the slice of the new place)
 * ends it. part < 0 ends it now. Each call replaces the last one. */
enum { ZS_PREVIEW_ON_BED = 1 };
int zs_view_part_preview(zs_view *view, int part, float qx, float qy, float qz, float qw,
                         float px, float py, float pz, float mx, float my, float mz, int flags);
void zs_view_set_mode(zs_view *view, int mode);
/* Highlights the beads of one path (an index into zs_app_toolpaths), or
 * nothing if path is (size_t)-1. */
void zs_view_highlight(zs_view *view, size_t path);
/* Replay: shows the print as it is t seconds after the start, with the
 * bead that the nozzle is printing cut to its printed part. A negative t
 * returns to whole layers. zs_view_set_layer also returns to whole layers. */
void zs_view_set_time(zs_view *view, double t);
/* The replay length in seconds (the end of the last bead). */
double zs_view_duration(const zs_view *view);
/* The layer that the nozzle prints at time t. */
size_t zs_view_layer_at_time(const zs_view *view, double t);
/* The path under the pixel (px, py) (pixels from the top left), or
 * (size_t)-1. */
size_t zs_view_pick(zs_view *view, float px, float py);
/* As zs_view_pick, and the segment of the path under the pixel (segment k
 * goes from point k to point k + 1; the last segment of a closed path goes
 * back to point 0). */
size_t zs_view_pick_segment(zs_view *view, float x, float y, size_t *seg);
/* Marks one segment of the highlighted path in orange; seg < 0: none.
 * zs_view_highlight clears it. */
void zs_view_highlight_segment(zs_view *view, size_t path, ptrdiff_t seg);
/* The other paths of a multiple selection, in yellow too (n = 0: none).
 * A new load clears them. */
int zs_view_highlight_more(zs_view *view, const size_t *paths, size_t n);
/* Draws and presents one frame. Call it after a change. */
int zs_view_draw(zs_view *view);

/* ---- a print view: G-code files, offscreen, touch ----
 *
 * For a printer screen (printdeck): the view of a G-code file of any
 * slicer, drawn into an image that the view owns, with no window. See
 * docs/embedding/print-view.md.
 *
 *   1. zs_gcode_open (or zs_gcode_new, zs_gcode_feed in pieces,
 *      zs_gcode_finish) reads the file. Keep it while a view shows it.
 *   2. zs_view_offscreen makes the view; zs_view_load_gcode shows the file.
 *   3. On each change: zs_view_set_position with the file position of the
 *      printer, or zs_view_set_layer from a scrubber; then zs_view_draw
 *      and zs_view_read for the pixels.
 *
 * Threads: one zs_gcode or zs_view on one thread at a time. Different
 * handles are independent (no global state). zs_view_draw, zs_view_read,
 * and the set and touch calls do not allocate memory. */

typedef struct zs_gcode zs_gcode;

/* Reads a G-code file in pieces of 1 MB. ZS_NO_RESULT if the file does not
 * open. ZS_NOT_SUPPORTED in wasm. */
int zs_gcode_open(const char *path, zs_gcode **out);
/* The same in steps: feed the bytes in pieces of any size (a piece can end
 * in the middle of a line), then finish. The queries need a finished
 * file. ZS_OUT_OF_RANGE for a file over 4 GB. */
int zs_gcode_new(zs_gcode **out);
int zs_gcode_feed(zs_gcode *g, const uint8_t *data, size_t len);
int zs_gcode_finish(zs_gcode *g);
void zs_gcode_free(zs_gcode *g);

typedef struct zs_gcode_info {
    uint64_t size;      /* bytes */
    uint64_t moves;     /* moves in x or y, with or without plastic */
    uint64_t beads;     /* moves with plastic */
    size_t layers;
    double time_s;      /* the print time: from the comments of the
                           slicer, else an estimate */
    double filament_mm; /* the filament diameter: from a comment, else
                           1.75 or 2.85 from the bead widths */
    double box[6];      /* the beads: min x, y, z, then max x, y, z (mm),
                           without the purge line of the start code */
} zs_gcode_info;
int zs_gcode_get_info(const zs_gcode *g, zs_gcode_info *out);

/* A byte offset counts the bytes read: a printer at offset p has read the
 * lines that end at or before p (the file position of Klipper). */
typedef struct zs_gcode_layer {
    uint64_t start, end;     /* the bytes of the layer: start to end */
    double z, height;        /* mm */
    double start_s, end_s;   /* the print time at its start and end */
} zs_gcode_layer;
int zs_gcode_get_layer(const zs_gcode *g, size_t layer, zs_gcode_layer *out);
/* The layer at a byte offset (the layer of the last byte read). */
size_t zs_gcode_layer_at(const zs_gcode *g, uint64_t offset);

typedef struct zs_gcode_state {
    size_t layer;
    uint64_t move;   /* the last move read */
    int feature;     /* enum zs_feature of the last bead, -1 if none */
    int travel;      /* 1 if the last move has no plastic */
    double speed;    /* mm/s of the last move */
    double x, y, z;  /* its end point, mm */
} zs_gcode_state;
/* The state at a byte offset. ZS_NO_RESULT before the first move. */
int zs_gcode_state_at(const zs_gcode *g, uint64_t offset, zs_gcode_state *out);

/* A PNG picture of the file from the front right, above (as the
 * thumbnails of zs_slice), width x height pixels, with a clear
 * background. by_feature != 0: one color for each feature, else rgb
 * (0xRRGGBB). Free the bytes with zs_buffer_free. */
int zs_gcode_thumbnail_png(const zs_gcode *g, uint32_t width, uint32_t height, int by_feature, uint32_t rgb,
                           uint8_t **out, size_t *out_len);

enum zs_view_offscreen_mode {
    ZS_VIEW_REDUCED = 1, /* the reduced view: no tools, gizmos, selection,
                            marks, or labels */
    ZS_VIEW_BGRA = 2     /* zs_view_read gives B, G, R, A bytes (the order of
                            a 32-bit Linux framebuffer); else R, G, B, A */
};
/* A view that draws into an image that it owns (no window, no display),
 * width x height pixels; mode: enum zs_view_offscreen_mode flags.
 * zs_view_resize changes the size. ZS_NOT_SUPPORTED with no Vulkan. */
int zs_view_offscreen(uint32_t width, uint32_t height, int mode, zs_view **out);
/* Copies the last frame (after zs_view_draw) to out: rows from the top,
 * stride bytes from one row to the next, 4 bytes for each pixel. Waits
 * for the GPU. ZS_BUSY before the first frame. */
int zs_view_read(zs_view *view, uint8_t *out, size_t len, size_t stride);
/* Shows a finished G-code file. The beads go to the GPU once; a position
 * or a layer only changes how many of them draw. bed_x, bed_y: the bed
 * size in mm (0: a bed around the part). zs_view_load ends it. */
int zs_view_load_gcode(zs_view *view, const zs_gcode *g, double bed_x, double bed_y);
/* Shows the print at a byte offset: the moves read, the nozzle at the
 * last one, and its layer lit. zs_view_set_layer (the scrubber) shows
 * whole layers again, up to a layer. */
void zs_view_set_position(zs_view *view, uint64_t offset);
/* Frames the beads of a loaded G-code file at once: the part in the middle,
 * filling `fill` of the smaller side of the view (0.8 is a good value), at
 * the start angle. The reduced view starts so, and zs_view_reset does it.
 * Call it again after a resize. Returns 1, or 0 with no G-code. */
int zs_view_frame_part(zs_view *view, float fill);
/* The colors of a G-code file: by_feature != 0 for one color for each
 * feature, else the filament color rgb (0xRRGGBB, the default 0xd0d0cc). */
int zs_view_gcode_colors(zs_view *view, int by_feature, uint32_t rgb);
/* zs_view_set_dark sets the night look (a dark background). */
void zs_view_set_reduced(zs_view *view, int on);
/* A print view: the nozzle at the position (nozzle != 0), and the top
 * layer lit with the layers under it darker (lit != 0). Both are on at
 * the start. */
void zs_view_print_look(zs_view *view, int nozzle, int lit);

enum zs_touch_action {
    ZS_TOUCH_DOWN = 0,
    ZS_TOUCH_MOVE = 1,
    ZS_TOUCH_UP = 2,
    ZS_TOUCH_CANCEL = 3 /* ends all touches */
};
/* A finger on a touch screen: id tells the fingers apart; x, y in pixels.
 * One finger orbits; two fingers pinch to zoom and move to pan.
 * zs_view_reset goes back to the start view. */
void zs_view_touch(zs_view *view, int64_t id, int action, float x, float y);

/* ---- the plates of a set in one view ----
 *
 * A set has one app for each plate. The view shows all plates in a row
 * from left to right, with a gap between them. The active plate is the
 * plate of the view: zs_view_load (or zs_view_scene_read) gives its beads,
 * and the pick, the layer range, and the selection work on it. Each other
 * plate is a fixed buffer of beads, made once after each slice of its app
 * (zs_view_plate_load or zs_view_plate_scene_read). It has no pick and no
 * layer range. Far from the camera, a plate draws with fewer beads (the
 * outside of the parts, and fewer layers).
 *
 * The world of the view is the frame of the active plate: its bed starts
 * at (0, 0). zs_view_plate_origin gives the place of another plate in it.
 * A change of the active plate moves the camera with the world, so the
 * picture stays still. Call zs_view_frame_plate after it to move to the
 * new plate. Only the frame backend (wasm and macOS) draws the other
 * plates for now; the Vulkan backend draws the active plate only. A plate
 * set (zs_set_view_sync, below) makes these calls. */

enum zs_plate_flag {
    ZS_PLATE_STALE = 1,     /* the slice is old: the beads fade a little */
    ZS_PLATE_BED_MODEL = 2, /* draw the bed model of the view (zs_view_set_bed) at this plate */
    ZS_PLATE_DISABLED = 4   /* the plate cannot slice: a light grid, and its outline faded */
};

/* The plates of the row: n bed sizes (beds: x, y in mm for each plate)
 * and the index of the active plate. The plates keep their beads. n = 0:
 * one plate, and no row. */
int zs_view_set_plates(zs_view *view, size_t n, size_t active, const float *beds);
/* The beads of plate i (not the active plate): from the bytes of
 * zs_view_scene_write of its app, or from the last slice of its app. In
 * the color mode of the view. */
int zs_view_plate_scene_read(zs_view *view, size_t i, const uint8_t *data, size_t len);
int zs_view_plate_load(zs_view *view, size_t i, const zs_app *app);
/* Shows plate i (not the active plate) as the footprints of its parts:
 * n boxes (boxes: x0, y0, x1, y1 in mm for each), for a plate with parts
 * and no slice (a plate that cannot slice). */
int zs_view_plate_outline(zs_view *view, size_t i, size_t n, const float *boxes);
/* Drops the beads of plate i (an empty plate). */
void zs_view_plate_clear(zs_view *view, size_t i);
/* The flags of plate i: enum zs_plate_flag bits. */
int zs_view_plate_flags(zs_view *view, size_t i, uint32_t flags);
/* The plate under the pixel (its bed or its beads, the nearest), or -1. */
int64_t zs_view_plate_at(const zs_view *view, float px, float py);
/* The origin of the bed of plate i in the world of the view (mm), for a
 * label over the plate (zs_view_pixel_of). */
int zs_view_plate_origin(const zs_view *view, size_t i, double *x, double *y);
/* Moves the camera (animated, see zs_view_animate) to show plate i from
 * the front; i = (size_t)-1 shows all plates. */
void zs_view_frame_plate(zs_view *view, size_t i);

/* ---- the 2D view of one layer, and the steps along the print ----
 *
 * A 2D view shows one layer from the top. These calls give it the data of
 * the loaded slice, from the view alone (a view of zs_view_scene_read has
 * them too). The places are in mm on the bed, in the cooled shape of the
 * beads (as the 3D view shows them). A path has one bead for each segment:
 * bead first + k of a path is its segment k. */

/* The path and the segment of `layer` nearest to (x, y) mm, closer than
 * twice the bead width, or (size_t)-1. */
size_t zs_view_pick_layer(const zs_view *view, size_t layer, double x, double y, size_t *seg);
/* The beads of a layer, or of a path, in the instances of the view: from
 * first to end. The web shell draws them from its copy of the instances. */
int zs_view_layer_beads(const zs_view *view, size_t layer, uint32_t *first, uint32_t *end);
int zs_view_path_beads(const zs_view *view, size_t path, uint32_t *first, uint32_t *end);
/* The marks of a layer (the seams, the travel moves, and the retractions;
 * see zs_view_focus): from first to end in the instances, after the beads.
 * Their alpha byte is the bit of the mark (ZS_MARK_SEAM is 1 << 11). */
int zs_view_layer_marks(const zs_view *view, size_t layer, uint32_t *first, uint32_t *end);
/* The layer of a path, and its number of segments. */
size_t zs_view_path_layer(const zs_view *view, size_t path);
size_t zs_view_path_segments(const zs_view *view, size_t path);
/* The outline of each layer: the material of the layer, to fill by the
 * nonzero rule (outer rings go counterclockwise, holes clockwise). Ring i
 * has the points ring_ends[i - 1] to ring_ends[i] (x, y pairs in points);
 * layer j has the rings layer_ends[j - 1] to layer_ends[j]. The arrays
 * stay valid until the next load. */
int zs_view_outlines(const zs_view *view, const float **points, size_t *n_points, const uint32_t **ring_ends,
                     size_t *n_rings, const uint32_t **layer_ends, size_t *n_layers);
/* The box of all beads: min x, min y, max x, max y (mm). ZS_NO_RESULT with
 * no beads. */
int zs_view_bounds(const zs_view *view, double out[4]);
/* One step along the print, for the keys h and l: from segment *seg of
 * path *path to the next segment (dir 1) or the one before (dir -1), on to
 * the next or the path before at an end of a path. *seg < 0 is the whole
 * path; whole_path = 1 steps a whole path at a time. Paths with no segment
 * are passed. Returns 1 and sets *path and *seg, or 0 at an end of the
 * print. */
int zs_view_step(const zs_view *view, size_t *path, ptrdiff_t *seg, int dir, int whole_path);
/* The path of `layer` nearest to the middle of `path`, for the keys j and
 * k; a path of another feature counts as 1 mm farther. (size_t)-1 if the
 * layer has no path. */
size_t zs_view_nearest_on_layer(const zs_view *view, size_t path, size_t layer);
/* The print time (s) at the end of a segment, and the path and the segment
 * that print at time t (returns 0 with no beads). */
double zs_view_segment_end_time(const zs_view *view, size_t path, size_t seg);
int zs_view_segment_at_time(const zs_view *view, double t, size_t *path, size_t *seg);

/* The loaded scene as bytes, for a view in another wasm instance: the web
 * shell slices in a worker and draws on the main thread. Free the bytes
 * with zs_buffer_free. zs_view_scene_read is the same as zs_view_load of
 * that slice. The same build writes and reads them. */
int zs_view_scene_write(zs_view *view, uint8_t **out, size_t *out_len);
int zs_view_scene_read(zs_view *view, const uint8_t *data, size_t len);

/* wasm and macOS: the frame data of a ZS_SURFACE_WEB view, after
 * zs_view_draw. The pointers point into the memory of the core and stay
 * valid until the next call into the view. A buffer changes only when its generation changes. The
 * instances are zs_web_instance values; the bead mesh, the shaders, and the
 * draw calls are those of the Vulkan backend (src/render/vk.zig), with the
 * clip space of Vulkan (y down, depth 0 to 1). NULL on other targets. */
typedef struct {
    float mvp[16], vec[4], eye[4], params[4];
} zs_web_push;
typedef struct {
    float ax, ay, bx, by, z, h, w;
    uint8_t rgba[4];
} zs_web_instance;
typedef struct {
    uint32_t first, count, lod;
} zs_web_draw;
/* One other plate of the frame, or the light beads of the active plate
 * (see the plate set above): the matrices with the place of the plate,
 * its bead buffer (upload it again when gen changes; keep one buffer for
 * each slot), and its draws in zs_web_frame.plate_draws. fade: how much
 * the colors go to the background. flags: 1 draws the bed model with
 * bed_mvp; 2 is the active plate (draw with the push data of box). */
typedef struct {
    float mvp[16], bed_mvp[16];
    const zs_web_instance *instances;
    uint32_t instance_count, gen;
    uint32_t draws_first, draws_count;
    float fade;
    uint32_t flags, slot;
} zs_web_plate;
typedef struct {
    zs_web_push box, grid;
    float clear[4];
    uint32_t box_first, box_count, mark_first, mark_count;
    const zs_web_instance *extras;
    uint32_t extras_count;
    const zs_web_instance *head;
    uint32_t head_count;
    const zs_web_instance *instances; /* the beads, then the marks */
    uint32_t instance_count, instances_gen;
    const float *mesh_verts; /* vec4 for each vertex */
    uint32_t mesh_vert_count;
    const uint16_t *mesh_index;
    uint32_t mesh_index_count, mesh_gen;
    const float *grid_points; /* vec3, two for each line */
    uint32_t grid_vertices, grid_gen;
    uint32_t width, height;
    /* The beads to draw: ranges with a level of detail (lod 0 is the full
     * mesh, 1 and up coarser meshes for beads far from the camera). The
     * chunks out of the view are not in the list. Empty: no bead is in
     * the view. */
    const zs_web_draw *draws;
    uint32_t draws_count;
    /* The meshes in mesh_index: the full mesh is 0 .. mesh_full_count; the
     * mesh of lod k (1, 2) is mesh_lod_first[k - 1] .. + mesh_lod_count[k - 1]. */
    uint32_t mesh_full_count, mesh_lod_first[2], mesh_lod_count[2];
    /* The bed model (zs_view_set_bed), drawn after the beads: its push
     * constants (color: the bed color; eye: the light; params: x 1 with a
     * texture, y the z over which the bed is see-through, z 1 when the
     * camera is under the bed), its vertices (8 floats each: position,
     * normal, uv; uv x < 0: no texture), and its RGBA texture (width 0:
     * none). Upload them again when bed_gen changes. bed_vertices is 0 in
     * a frame with no bed. */
    zs_web_push bed;
    const float *bed_verts;
    uint32_t bed_vertex_count, bed_vertices, bed_gen;
    const uint8_t *bed_tex;
    uint32_t bed_tex_width, bed_tex_height;
    /* The other plates and their draws, and their grid lines (vec3, two
     * for each line; from vertex plate_grid_dim on, the plates that
     * cannot slice). Upload the grid again when plate_grid_gen changes. */
    const zs_web_plate *plates;
    uint32_t plates_count;
    const zs_web_draw *plate_draws;
    uint32_t plate_draws_count;
    const float *plate_grid;
    uint32_t plate_grid_vertices, plate_grid_dim, plate_grid_gen;
    /* A part that turns in the view only (zs_view_part_preview): its push
     * constants (the matrix of the turn; the light and the eye in the
     * frame of its beads), and its draws in the bead buffer. draws leaves
     * these beads out. */
    zs_web_push part;
    const zs_web_draw *part_draws;
    uint32_t part_draws_count;
} zs_web_frame;
const zs_web_frame *zs_view_web_frame(const zs_view *view);

/* ---- comparison with Cura ---- */

/* Reads the file at path for the core. Returns its bytes and sets *len,
 * or returns NULL. The bytes stay valid until zs_app_cura_compare
 * returns. */
typedef const char *(*zs_read_fn)(void *ctx, const char *path, size_t *len);

/* One setting of a comparison. The strings live until
 * zs_cura_compare_free. */
typedef struct zs_cura_row {
    const char *name;         /* the zslice setting, "machine.max_speed" */
    const char *zslice_value; /* the value of zslice now */
    const char *cura_value;   /* the value of Cura, ready for
                                 zs_app_setting_set; for a formula, the
                                 formula of Cura */
    const char *cura_keys;    /* the Cura keys, with ", " between them */
    const char *from;         /* the Cura file of the value */
    const char *note;         /* for example "25 mm/s in Cura", or "" */
    int differs;              /* 1 if the values differ */
    int formula;              /* 1 if the Cura value is a formula */
    int in_use_all;           /* 1 if "Use all" takes this value: it
                                 differs, and it is not a name or the
                                 start or end G-code */
} zs_cura_row;

typedef struct zs_cura_compare zs_cura_compare;

/* Compares the settings of the app with a Cura stack (src/cura_compare.zig).
 * read gives "cura.json" (the layout of the Cura import, see
 * docs/user/profiles.md), the files that it names, and
 * "definitions/<id>.def.json" for each definition of the inherits chain.
 * The first quality profile and the first material are the active ones.
 * A speed of Cura becomes a ratio of the machine.max_speed of the app: to
 * take all values, set machine.max_speed first, then compare again. On an
 * error, message (can be NULL) gets the file and the reason. */
int zs_app_cura_compare(const zs_app *app, zs_read_fn read, void *ctx, zs_cura_compare **out, char *message, size_t cap);
size_t zs_cura_compare_count(const zs_cura_compare *cc);
int zs_cura_compare_get(const zs_cura_compare *cc, size_t i, zs_cura_row *out);
void zs_cura_compare_free(zs_cura_compare *cc);

/* ---- printdeck.yml projects (src/project.zig) ----
 *
 * A project is a repository with a printdeck.yml: its parts, each with its
 * files, count, printer, profile ("<folder>/<profile>" of profiles/, a Cura
 * stack with cura.json), material, and Cura settings. The plan puts the
 * chosen parts on plates. The results are JSON texts with the buffer rules
 * of zs_app_setting_get. counts: "n,n,..." with one entry for each part
 * ("-" or a missing entry: the count of the file, 0: not on a plate), or
 * NULL for all parts. */

/* The files of a repository that a plate needs (the model files, and the
 * files of profiles/<folder>/), with paths relative to the repository. */
typedef struct zs_files zs_files;
zs_files *zs_files_new(void);
int zs_files_add(zs_files *files, const char *path, const void *data, size_t len);
void zs_files_free(zs_files *files);

/* The parts and the suggested plates of a printdeck.yml: {"name",
 * "parts": [{"name", "base_name", "variant", "group", "description",
 * "files", "count", "printer", "profile", "material",
 * "settings": [{"key", "value"}], "alone", "prebuilt"}], "plates":
 * [{"printer", "profile", "material", "items": [{"part", "count"}]}]}, or
 * {"error", "line"}. */
int zs_project_plan(const char *yml, const char *counts, char *buf, size_t cap, size_t *out_len);
/* The profiles of plate `plate`: {"machine": {"name", "text"},
 * "filament": {...}, "project": {...}} or {"error", "line"}. Load each with
 * zs_app_group_reset and zs_app_profile_apply, then call
 * zs_app_project_load. */
int zs_project_profiles(const zs_files *files, const char *yml, const char *counts, size_t plate, char *buf, size_t cap, size_t *out_len);
/* Puts plate `plate` on the plate of the app, in place of its parts: the
 * plate settings (support, adhesion) as changes of the print, then the
 * copies of the files, each with the settings of its part, arranged.
 * ZS_OUT_OF_RANGE: the parts do not all fit on the bed (they stay on the
 * plate). On an error, message (can be NULL) gets the reason. */
int zs_app_project_load(zs_app *app, const zs_files *files, const char *yml, const char *counts, size_t plate, char *message, size_t cap);

/* ---- the plate set (src/app/plate_set.zig) ----
 *
 * A set has one or more plates, each with its own zs_app: its own
 * settings, parts, undo list, and slice. The active plate is the plate
 * that the shell shows and changes: call the zs_app functions on
 * zs_set_app(set, zs_set_active(set)). The set slices the other plates in
 * the background, one plate at a time, so that a view shows all plates in
 * a row (zs_view_set_plates).
 *
 * After each change of a plate, call zs_set_changed (not
 * zs_app_request_slice): the plate waits for a slice. The active plate
 * slices first, then each other waiting plate in order. A plate keeps its
 * old slice until its new slice is done. During a drag of a part, call
 * zs_set_changed_held, and zs_set_release at the end: a move or a turn
 * slices once, at the end.
 *
 * Two modes:
 * - zs_set_new (native): the core starts each slice. A change of the
 *   active plate starts its slice at once, and stops the slice of another
 *   plate (that plate slices again later).
 * - zs_set_new_web (wasm): a slice runs on the calling thread. Call
 *   zs_set_step from a timer while it returns 1, so that the other
 *   messages of the worker come between the slices.
 *
 * Events: the callback gets the events of the app of each plate (the
 * index of the plate, then the values of zs_app_event_fn), and
 * ZS_EVENT_PLATES with plate (size_t)-1 when the list or a status
 * changes. In the native mode it runs on the slice threads and on the
 * thread of the call: move each event to the UI thread, and call no zs_set
 * function in the callback. Call the zs_set functions from one thread. */

typedef struct zs_set zs_set;

typedef void (*zs_set_event_fn)(void *user, size_t plate, int event, double progress, int status);

/* A new set with one empty plate. */
int zs_set_new(zs_set_event_fn event_fn, void *user, zs_set **out);
/* wasm only: the same, with the events to the import env.zs_web_set_event
 * (plate, event, progress, status) of the module. */
int zs_set_new_web(zs_set **out);
/* Stops each slice, and frees the set and its apps. */
void zs_set_free(zs_set *set);

size_t zs_set_count(zs_set *set);
size_t zs_set_active(zs_set *set);
/* The app of plate i, or NULL. It stays valid until the plate goes
 * (zs_set_remove, zs_set_keep_active, zs_set_project_load). */
zs_app *zs_set_app(zs_set *set, size_t i);

/* A new empty plate after the others, with the settings of the active
 * plate, named "Plate n". It becomes the active plate. Returns its index,
 * or a negative status. */
ptrdiff_t zs_set_add(zs_set *set);
/* Makes plate i the active plate. The plate that was active frees the
 * memory that only makes its next slice faster (zs_app_trim). A plate
 * with parts and no current slice waits for a slice. */
int zs_set_select(zs_set *set, size_t i);
/* Removes plate i and its app (no undo: the plates are not in the undo
 * list of an app). If it is the active plate, the plate on its left
 * becomes active (the first plate, if it was the first); else the active
 * plate stays. The last plate stays, with no parts. */
int zs_set_remove(zs_set *set, size_t i);
/* Keeps only the active plate: a set of one plate. For example before a
 * file opens in place of the plates of a project. */
int zs_set_keep_active(zs_set *set);

enum zs_plate_status {
    ZS_PLATE_STATUS_EMPTY = 0,   /* no parts */
    ZS_PLATE_STATUS_STALE = 1,   /* waits for a slice; the old slice shows */
    ZS_PLATE_STATUS_SLICING = 2,
    ZS_PLATE_STATUS_DONE = 3,
    ZS_PLATE_STATUS_FAILED = 4,  /* the slice or the load failed (see message) */
    ZS_PLATE_STATUS_CANNOT = 5   /* zslice cannot slice the plate (a resin plate) */
};

typedef struct zs_plate_info {
    uint64_t id;              /* new for each plate; never used again */
    int status;               /* enum zs_plate_status */
    double bed_x, bed_y;      /* the bed size, mm */
    const char *name;         /* for a list: the name of the plate, or of its model */
    const char *printer_key;  /* "<machine.model>\n<machine.name>": two
                                 plates with the same key share a bed model */
    size_t part_count;
    const char *message;      /* why the load failed, or why the parts do
                                 not fit; "" if none */
} zs_plate_info;

/* The facts of plate i. The strings stay valid until the next
 * zs_set_plate_info of the same plate, or a change of the list. */
int zs_set_plate_info(zs_set *set, size_t i, zs_plate_info *out);
/* The name of plate i for a list (a file name); NULL or "": the name of
 * its model. */
int zs_set_name(zs_set *set, size_t i, const char *name);
/* The printer that plate i is for: a key of the app's list of printers, or
 * NULL or "" for none. The project file keeps it. */
int zs_set_plate_printer(zs_set *set, size_t i, const char *key);
/* The printer of plate i ("" for none), copied to buf with a 0 at the end. */
int zs_set_plate_printer_get(zs_set *set, size_t i, char *buf, size_t cap, size_t *out_len);

/* Plate i changed: it waits for a slice. In the native mode, a change of
 * the active plate starts its slice at once. A plate with no parts does
 * not slice, and its beads go (ZS_PLATE_STATUS_EMPTY). */
int zs_set_changed(zs_set *set, size_t i);
/* A change of plate i during a drag: the slice waits for zs_set_release.
 * A zs_set_changed of the plate ends the wait. */
int zs_set_changed_held(zs_set *set, size_t i);
int zs_set_release(zs_set *set);
/* The plate that zs_set_step slices next, or -1 (for example, to give the
 * cancel flag of its app to the page: zs_app_cancel_address). */
ptrdiff_t zs_set_next(zs_set *set);
/* Slices the next waiting plate on the calling thread. Returns 1 if a
 * plate waited, 0 if none. A canceled slice waits again. */
int zs_set_step(zs_set *set);

/* Loads all plates of a printdeck.yml in place of the plates of the set:
 * one app for each plate, with the profiles, the settings, and the parts
 * of the plate (see zs_app_project_load). files has the files of all
 * plates. A plate with no Cura stack (a resin plate) gets its parts, for
 * their footprints, and ZS_PLATE_STATUS_CANNOT. A plate that does not load is
 * ZS_PLATE_STATUS_FAILED with a message. Plate `active` becomes the active plate,
 * and the plates slice. On an error of the yml, the set does not change,
 * and message (can be NULL) gets the reason. */
int zs_set_project_load(zs_set *set, const zs_files *files, const char *yml, const char *counts, size_t active,
                        char *message, size_t cap);
/* All plates as one project file (.3mf; other slicers open its first
 * plate): the parts, their places and settings, and the printer, filament,
 * and print settings of each plate. Free *out with zs_buffer_free. */
int zs_set_project_save(zs_set *set, const char *name, uint8_t **out, size_t *len);
/* The session of the app, for a restore after a reload or a quit: the
 * plates, the last scene of each (the view shows it at once at startup),
 * the camera (8 floats of zs_view_get_camera, or NULL), and the text of the
 * app (its own state: pages, scroll, focus). Free the bytes with
 * zs_buffer_free. */
int zs_session_write(zs_set *set, const float *camera, const char *app_text, uint8_t **out, size_t *len);
/* Puts a session back: its plates replace the plates of the set, each plate
 * shows its last scene until it slices again, camera_out gets the camera
 * (*has_camera = 1), and *app_text the text of the app (free it with
 * zs_buffer_free). ZS_INVALID_VALUE with a message for a bad file. */
int zs_session_read(zs_set *set, const uint8_t *bytes, size_t len, float camera_out[8], int *has_camera, uint8_t **app_text, size_t *app_len, char *message, size_t cap);
/* 1 if the bytes are a zslice project file (zs_set_project_open), 0 for
 * another file (a plain 3MF opens as a model). */
int zs_project_file_is(const uint8_t *bytes, size_t len);
/* Opens a project file: its plates replace the plates of the set. On an
 * error the set stays, and message says why; a message can also come with
 * ZS_OK (a plate that did not load fully). */
int zs_set_project_open(zs_set *set, const uint8_t *bytes, size_t len, char *message, size_t cap);
/* Moves part `part` of plate `from` to plate `to`, or to a new plate after
 * the others (to < 0, with the settings of plate from). The part keeps its
 * mesh, pose, scale, settings, and volumes, and goes to a free place. One
 * history step on each plate; both slice again. Returns the index of the
 * target plate, or -status. */
ptrdiff_t zs_set_part_move(zs_set *set, size_t from, size_t part, ptrdiff_t to);
/* The sums of the project: the plates with parts, how many have a slice
 * (a plate that slices now or failed counts in missing, not in the sums),
 * the parts, the print time, the filament, and the cost: the filament at
 * filament.price_per_kg and the time at machine.hour_rate of each plate. */
typedef struct zs_totals {
    size_t plates, sliced, missing, parts;
    double time_s, filament_g, filament_mm;
    double cost_filament, cost_machine, cost;
} zs_totals;
/* Copies of part `part` of plate `from` until there are n in all: on its
 * plate while they fit the bed, then on new plates after the others, with
 * the settings of plate from ("make 100 of this part"). Returns the copies
 * in all, and the count of plates that have them in *plates (can be NULL),
 * or -status. One history step on each plate that changed. */
ptrdiff_t zs_set_fill(zs_set *set, size_t from, size_t part, size_t n, size_t *plates);
int zs_set_totals(zs_set *set, zs_totals *out);
/* The same sums for plate i alone. */
int zs_set_plate_totals(zs_set *set, size_t i, zs_totals *out);

/* ---- the plates of a set in a view ----
 *
 * zs_set_view_sync brings a view up to date with the set after
 * ZS_EVENT_PLATES or a slice: the row of the beds (220 mm for a bed of 0),
 * zs_view_plate_clear where another plate came to a place, the flags of
 * each plate (ZS_PLATE_STALE while it waits or slices, ZS_PLATE_BED_MODEL
 * when its printer_key is the key of the active plate, ZS_PLATE_DISABLED
 * when it cannot slice or failed), the footprints of the parts of a plate
 * that cannot slice (once for each change), and the beads of each other
 * plate with a new slice. The shell still draws the active plate with
 * zs_view_load (or zs_view_scene_read) after its slice. One view follows
 * one set; zs_set_view_reset starts again for a new view. */
int zs_set_view_sync(zs_set *set, zs_view *view);
void zs_set_view_reset(zs_set *set);
/* The scene bytes of plate i (for zs_view_scene_read): its last slice, or
 * its old beads while it slices again (after zs_session_read: the scene of
 * the session). ZS_NO_RESULT if none. The bytes stay valid until the next
 * call of the set. */
int zs_set_plate_scene(zs_set *set, size_t i, const uint8_t **out, size_t *out_len);
/* The same as bytes, for a view in another wasm instance (the web app
 * slices in a worker, and the page owns the view): zs_set_sync_write in
 * the worker (free the bytes with zs_buffer_free), and zs_view_sync_read
 * in the page. zs_set_view_mode sets the color mode of the beads (enum
 * zs_view_mode); zs_set_view_sync takes the mode of its view. */
int zs_set_sync_write(zs_set *set, uint8_t **out, size_t *out_len);
int zs_view_sync_read(zs_view *view, const uint8_t *data, size_t len);
void zs_set_view_mode(zs_set *set, int mode);
/* The scene bytes of plate i, for zs_view_scene_read: of its last slice,
 * or its old beads while it slices again. ZS_NO_RESULT if it has none.
 * The bytes stay valid until the next zs_set call. */
int zs_set_plate_scene(zs_set *set, size_t i, const uint8_t **out, size_t *out_len);

/* ---- licenses ---- */

/* zslice and the components in the core. A shell adds the components that
 * only it links (for example GTK). All strings are static. text is the
 * full license text: show it whole. */
typedef struct zs_license {
    const char *name;
    const char *license;
    const char *text;
} zs_license;

size_t zs_license_count(void);
int zs_license_get(size_t index, zs_license *out);

/* ---- printer library ---- */

/* The printers that zslice knows: brands, models, and the machine profile
 * of each model (src/printers.zig). The data is a file
 * (src/printers/library.txt) from the printer definitions of Cura,
 * PrusaSlicer, and OrcaSlicer. Native builds embed it
 * (zs_printers_builtin). The wasm module does not: the web app fetches the
 * file and gives the bytes to zs_printers_load. All strings stay valid
 * until zs_printers_free. */
typedef struct zs_printers zs_printers;

/* ZS_INVALID_VALUE if the bytes are not a library. */
int zs_printers_load(const uint8_t *data, size_t len, zs_printers **out);
/* ZS_NOT_SUPPORTED in the wasm module. */
int zs_printers_builtin(zs_printers **out);
void zs_printers_free(zs_printers *lib);

/* Brands in alphabetical order. The models of brand i are first to end
 * (not included), in the order of their series. */
size_t zs_printers_brand_count(const zs_printers *lib);
int zs_printers_brand_get(const zs_printers *lib, size_t i, const char **name, size_t *first, size_t *end);

typedef struct zs_printer_model {
    const char *id;        /* stable, for example "creality-ender-3-v2" */
    const char *brand;
    size_t brand_index;
    const char *name;      /* without the brand, for example "Ender-3 V2" */
    const char *series;    /* for groups, for example "Ender" */
    double bed_x, bed_y, height; /* mm; a round bed: bed_x is the diameter */
    double origin_x, origin_y;   /* the G-code X and Y of the front left corner */
    bool round;            /* a round bed (most delta printers) */
    bool heated_bed, heated_chamber;
    bool klipper;          /* Klipper G-code (else Marlin) */
    bool has_start_gcode;  /* false: the source G-code has scripts, and zslice uses its own */
    double nozzle;         /* the default nozzle, mm */
    const char *nozzles;   /* the nozzle sizes, "0.25;0.4;0.6", or "" */
    double filament;       /* the filament diameter, mm */
    double max_speed;      /* the limit of the firmware, mm/s, or 0 */
    double max_accel;      /* mm/s², or 0 */
    const char *firmware;  /* "Marlin", "Klipper", "RepRapFirmware", ... */
    const char *kinematics;/* "corexy", "i3", "delta", or "" */
    uint32_t extruders;
    const char *title;     /* for the user: "Creality Ender-3 V2", "Voron 2.4 350" */
} zs_printer_model;

size_t zs_printers_model_count(const zs_printers *lib);
int zs_printers_model_get(const zs_printers *lib, size_t i, zs_printer_model *out);
/* The index of the model with this id, or -1. */
ptrdiff_t zs_printers_find(const zs_printers *lib, const char *id);
/* The models that match the query (search as you type), best first. brand:
 * a brand index, or -1 for all. Writes up to cap model indices, and
 * returns the count of matches (can be more than cap). An empty query
 * gives the models in the library order. */
size_t zs_printers_search(const zs_printers *lib, const char *query, ptrdiff_t brand, uint32_t *out, size_t cap);
/* The printers that most people have (Bambu Lab, Prusa, Creality, Elegoo,
 * Anycubic, Voron, Sovol, LulzBot), for the first view of a picker: model
 * indices, at most cap. Returns the count. */
size_t zs_printers_popular(const zs_printers *lib, uint32_t *out, size_t cap);
/* The model of a machine profile: by its setting machine.model (the id that
 * zs_printers_profile writes), else by a machine.name that is the title of
 * a model (a profile from before machine.model). -1 if none fits. */
ptrdiff_t zs_printers_find_machine(const zs_printers *lib, const char *model, const char *name);
/* The bed model of a model: the names of its files in the bed folder
 * (installed with the app, for example share/zslice/beds; the web app
 * serves them as beds/). Each name can be "": a bed with a mesh and no
 * texture, or a texture alone. ZS_NO_RESULT if the model has no bed model:
 * the 3D view then shows the grid. */
typedef struct zs_printer_bed {
    const char *mesh;    /* "ender3-bed.mesh", or "" */
    const char *texture; /* "ender3.png", or "" */
    const char *source;  /* the slicer of the files: "PrusaSlicer" */
    bool flat;           /* the texture covers the plate (the top row at the
                            back): a picker can draw it on its plate. Else
                            the texture follows the UV of the mesh. */
} zs_printer_bed;
int zs_printers_bed(const zs_printers *lib, size_t i, zs_printer_bed *out);
/* The model that fits a printer on the network: a name hint (a TXT model,
 * a host name) and its bed (0 when not known), or -1. */
ptrdiff_t zs_printers_match(const zs_printers *lib, const char *hint, double bed_x, double bed_y, double height);
/* As zs_printers_match, with the nozzle of the printer in mm (0: not known;
 * take it from zs_printer_status_get). A name that starts the names of a
 * family of models (one printer, many tool heads) matches the family; in
 * it, the model with that nozzle wins, and with no nozzle the stock size. */
ptrdiff_t zs_printers_match_nozzle(const zs_printers *lib, const char *hint, double bed_x, double bed_y, double height, double nozzle);
/* The text functions below write the text and a 0 to buf, and its length
 * (without the 0) to out_len. buf NULL: the length only. */
/* The machine profile of a model (for zs_app_profile_apply with
 * ZS_GROUP_MACHINE), with a nozzle of `nozzle` mm (0: the default). */
int zs_printers_profile(const zs_printers *lib, size_t i, double nozzle, char *buf, size_t cap, size_t *out_len);
/* The key facts in one line: "220 × 220 × 250 mm · heated bed · Marlin". */
int zs_printers_facts(const zs_printers *lib, size_t i, char *buf, size_t cap, size_t *out_len);
/* The sources of the data of a model: "Cura, OrcaSlicer". */
int zs_printers_sources(const zs_printers *lib, size_t i, char *buf, size_t cap, size_t *out_len);

/* ---- printer discovery ---- */

/* Finds printers on the local network with mDNS (src/discovery.zig). The
 * core builds and reads the packets; the shell does the network I/O:
 *   1. Send the zs_discovery_query packet over UDP to 224.0.0.251 port
 *      5353: from a socket on port 5353 in the group (SO_REUSEADDR and
 *      SO_REUSEPORT: the mDNS service of the system has the port too), where
 *      the answers come, and from a socket of its own port (a unicast answer
 *      comes back to it, if no firewall stops it). Send it again after 1 s
 *      and 3 s: a packet can get lost.
 *   2. Give each packet that comes back to zs_discovery_feed. When it
 *      returns 1, send zs_discovery_query again: it has the next questions
 *      (a server can answer with a PTR record alone).
 *   3. For a new printer: GET <url>/api/version (OctoPrint, printdeck,
 *      PrusaLink) or <url>/printer/objects/query?toolhead (Moonraker), with
 *      no key, and give the body to zs_discovery_reply. The kind and the bed
 *      can change.
 * A browser cannot send UDP: the web app asks for an address instead. */
typedef struct zs_discovery zs_discovery;

enum zs_found_kind {
    ZS_FOUND_OCTOPRINT = 1,
    ZS_FOUND_PRINTDECK = 2,
    ZS_FOUND_MOONRAKER = 3,
    ZS_FOUND_PRUSALINK = 4,
    ZS_FOUND_BAMBU = 5     /* Bambu Lab in LAN mode (SSDP on UDP 2021) */
};

enum zs_found_reply {
    ZS_FOUND_REPLY_VERSION = 1,  /* the body of GET <url>/api/version */
    ZS_FOUND_REPLY_TOOLHEAD = 2  /* the body of GET <url>/printer/objects/query?toolhead */
};

typedef struct zs_found_printer {
    const char *name;       /* the service name, for example "Printdeck" */
    int kind;               /* enum zs_found_kind */
    const char *kind_title; /* "OctoPrint", "printdeck", ... */
    const char *host;       /* "printdeck.local" */
    const char *address;    /* "192.168.1.20" */
    int port;
    const char *url;        /* "http://192.168.1.20" */
    const char *model;      /* from the TXT record, or "" */
    const char *version;    /* "" if not known */
    double bed_x, bed_y, height; /* from Klipper, 0 if not known */
    double origin_x, origin_y;
    const char *serial;     /* Bambu Lab: the serial number (USN), or "" */
} zs_found_printer;

/* Bambu Lab printers in LAN mode send SSDP text packets to UDP port 2021:
 * listen on that port too (SO_REUSEADDR, broadcast), and give those packets
 * to zs_discovery_feed as well. It tells them from mDNS packets. */
#define ZS_DISCOVERY_BAMBU_PORT 2021
int zs_discovery_new(zs_discovery **out);
void zs_discovery_free(zs_discovery *d);
/* The query packet. It stays valid until the next call. */
int zs_discovery_query(zs_discovery *d, const uint8_t **out, size_t *len);
/* Returns 1 if the list changed or the next query has new questions, 0 if
 * not, -1 on an error. */
int zs_discovery_feed(zs_discovery *d, const uint8_t *data, size_t len);
size_t zs_discovery_count(const zs_discovery *d);
/* The strings stay valid until zs_discovery_free. */
int zs_discovery_get(const zs_discovery *d, size_t i, zs_found_printer *out);
/* what: enum zs_found_reply. Returns 1 if the entry changed, 0 if not, -1
 * on an error. */
int zs_discovery_reply(zs_discovery *d, size_t i, int what, const char *body, size_t len);


/* ---- the farm ----
 *
 * Printers, orders, and the jobs of the orders, for a shop with many
 * printers (src/app/farm.zig). The app polls each printer
 * (zs_printer_status) and gives the farm its state with zs_farm_status.
 * zs_farm_next proposes sends: each waiting job (the order due first) to a
 * free printer that fits it (bed, turned too; nozzle; material), the
 * smallest bed first. A proposal changes nothing: the app asks the person
 * ("Is the bed clear?"), sends the file, and calls zs_farm_sent. A
 * printdeck starts a print only after a press of Print on its screen; its
 * job waits as "sent" until the deck prints it. The farm never starts a
 * print. zs_farm_events gives "ready to collect", "failed" (with why),
 * "paused", and an order done or failed. A poll can miss a short state:
 * when a printer is idle again with no job, a job that was at 95 % or more
 * is done, else it failed. A failed job waits again, 3 tries at most. */
typedef struct zs_farm zs_farm;

enum zs_farm_printer_state {
    ZS_FARM_OFFLINE = 0,
    ZS_FARM_IDLE = 1,
    ZS_FARM_PRINTING = 2,
    ZS_FARM_PAUSED = 3,
    ZS_FARM_FINISHED = 4, /* done, the print is still on the bed */
    ZS_FARM_FAILED = 5,
};

enum zs_farm_job_state {
    ZS_FARM_JOB_WAITING = 0,
    ZS_FARM_JOB_SENT = 1,
    ZS_FARM_JOB_PRINTING = 2,
    ZS_FARM_JOB_DONE = 3,      /* ready to collect */
    ZS_FARM_JOB_COLLECTED = 4,
    ZS_FARM_JOB_FAILED = 5,    /* failed on the last try */
};

enum zs_farm_event_kind {
    ZS_FARM_READY = 0,
    ZS_FARM_FAILED_EVENT = 1,
    ZS_FARM_PAUSED_EVENT = 2,
    ZS_FARM_ORDER_DONE = 3,
    ZS_FARM_ORDER_FAILED = 4,
};

typedef struct zs_farm_send { uint32_t job; size_t printer; } zs_farm_send;

typedef struct zs_farm_event {
    int kind;          /* enum zs_farm_event_kind */
    uint32_t job, order;
    ptrdiff_t printer; /* or -1 */
    const char *text;  /* why (not 0-terminated), valid until the next zs_farm_events */
    size_t text_len;
} zs_farm_event;

typedef struct zs_farm_job {
    uint32_t id, order;
    int state;         /* enum zs_farm_job_state */
    uint32_t tries;
    ptrdiff_t printer; /* while sent, printing, or done; else -1 */
    double progress, seconds;
    const char *name;
    size_t name_len;
} zs_farm_job;

typedef struct zs_farm_printer {
    int state;         /* enum zs_farm_printer_state */
    double progress;
    uint32_t job;      /* the job on the printer, or 0 */
    const char *key;
    size_t key_len;
} zs_farm_printer;

int zs_farm_new(zs_farm **out);
void zs_farm_free(zs_farm *farm);
/* Adds a printer (its key in the app), or changes its facts: the bed in mm,
 * the nozzle, the material in it ("" for any), and printdeck (1: a press
 * on the deck starts each print). Returns its index, or -status. */
ptrdiff_t zs_farm_printer_set(zs_farm *farm, const char *key, double bed_x, double bed_y, double nozzle, const char *material, int printdeck);
ptrdiff_t zs_farm_printer_find(zs_farm *farm, const char *key);
size_t zs_farm_printer_count(zs_farm *farm);
int zs_farm_printer_get(zs_farm *farm, size_t i, zs_farm_printer *out);
/* An order of a customer, due at a time (any clock in seconds, 0: none).
 * Returns its id (> 0), or -status. */
int64_t zs_farm_order_add(zs_farm *farm, const char *customer, int64_t due);
/* A job (one plate) of an order: its name, material, the bed it needs, the
 * nozzle (0: any), and its time in s. Returns its id (> 0), or -status. */
int64_t zs_farm_job_add(zs_farm *farm, uint32_t order, const char *name, const char *material, double bed_x, double bed_y, double nozzle, double seconds);
size_t zs_farm_job_count(zs_farm *farm);
int zs_farm_job_get(zs_farm *farm, size_t i, zs_farm_job *out);
/* The state of printer i from a poll, the progress of its job (0 to 1), why
 * it failed (or NULL), and the time. */
int zs_farm_status(zs_farm *farm, size_t printer, int state, double progress, const char *why, int64_t now);
size_t zs_farm_next(zs_farm *farm, zs_farm_send *out, size_t cap);
int zs_farm_sent(zs_farm *farm, uint32_t job, size_t printer, int64_t now);
/* A person took the print off printer i: the printer is free. */
int zs_farm_collected(zs_farm *farm, size_t printer);
size_t zs_farm_events(zs_farm *farm, zs_farm_event *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
