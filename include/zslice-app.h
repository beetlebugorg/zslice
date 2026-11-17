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
    ZS_EVENT_CANCELED = 4
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

int zs_app_write_3mf(zs_app *app, const uint8_t **out, size_t *out_len);
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

size_t zs_app_part_count(const zs_app *app);
int zs_app_part_get(zs_app *app, size_t i, zs_part *out);
/* The settings of a part from its 3MF file (a Cura project) and its
 * modifier volumes, one on each line: each Cura setting with the zslice
 * setting that it becomes, or why zslice does not use it. Empty for a
 * part with no settings. The same buffer rules as zs_app_setting_get. */
int zs_app_part_settings(const zs_app *app, size_t i, char *buf, size_t cap, size_t *out_len);
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
/* The history of changes. A shell keeps the facts of each step of its undo
 * list: zs_app_history_facts writes the state as lines of
 * "scope\tkey\tvalue" (only the values that differ from the start).
 * zs_history_diff gives the changes from one step to the next, one on each
 * line ("scope\tkey\told\tnew"), and zs_history_describe writes them in
 * words ("Part Benchy\tWall count the print value -> 4"). The scopes:
 * "machine", "filament", "print", "part:<name>", "layers:<z_min>:<z_max>".
 * zs_app_history_revert undoes one change line and keeps the others
 * (ZS_NOT_SUPPORTED for a move of a part); slice again after it. The same
 * buffer rules as zs_app_setting_get. */
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

/* The core draws the 3D view of a slice into a native surface that the
 * shell gives: a Wayland wl_surface or an X11 window on Linux. The core
 * loads Vulkan at run time, so the shell does not link it. Without Vulkan,
 * zs_view_new returns ZS_NOT_SUPPORTED. Call the view functions from the
 * UI thread. */

enum zs_surface_kind {
    ZS_SURFACE_WAYLAND = 1, /* display: struct wl_display *, surface: struct wl_surface * */
    ZS_SURFACE_XLIB = 2,    /* display: Display *, window: Window */
    ZS_SURFACE_WEB = 3      /* wasm only: no surface; the shell reads the
                               frame data (zs_view_web_frame) and draws it */
};

typedef struct zs_surface {
    int kind; /* enum zs_surface_kind */
    void *display;
    void *surface;
    uint64_t window;
} zs_surface;

typedef struct zs_view zs_view;

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
int zs_view_bed_point(const zs_view *view, float px, float py, double *x, double *y);
/* Shows the beads of some features clearly, and fades the others: a bit
 * (1 << enum zs_feature) for each feature, or 0 to end the focus. Only the
 * beads with a top at or under zmax (mm) are in focus; a negative zmax is
 * all layers. For a settings browser: zs_setting_get_effect gives the bits. */
void zs_view_focus(zs_view *view, uint32_t features, double zmax);
/* Turns the camera freely around the axes of the screen, by a drag of dx,
 * dy pixels. Drags in turn can roll the view, so the part can turn to any
 * direction. zs_view_orbit keeps the bed level; this does not. */
/* Shows the gaps of a layer (see zs_app_layer_gaps) in red, or none for a
 * negative layer. Call it again after a new slice. */
void zs_view_show_gaps(zs_view *view, zs_app *app, int64_t layer);
/* The index of the shown gap under the pixel, or -1. */
int64_t zs_view_gap_at(const zs_view *view, zs_app *app, float px, float py);

void zs_view_rotate(zs_view *view, float dx, float dy);
/* Turns the camera around the vertical axis only (a turntable), by a drag
 * of dx pixels. */
void zs_view_turn(zs_view *view, float dx);
/* Returns the camera to the start view around the part. */
void zs_view_reset(zs_view *view);
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

/* wasm only: the frame data of a ZS_SURFACE_WEB view, after zs_view_draw.
 * The pointers point into wasm memory and stay valid until the next call
 * into the view. A buffer changes only when its generation changes. The
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
     * chunks out of the view are not in the list. Empty: draw box_first
     * to box_count with the full mesh. */
    const zs_web_draw *draws;
    uint32_t draws_count;
    /* The meshes in mesh_index: the full mesh is 0 .. mesh_full_count; the
     * mesh of lod k (1, 2) is mesh_lod_first[k - 1] .. + mesh_lod_count[k - 1]. */
    uint32_t mesh_full_count, mesh_lod_first[2], mesh_lod_count[2];
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
/* The model that fits a printer on the network: a name hint (a TXT model,
 * a host name) and its bed (0 when not known), or -1. */
ptrdiff_t zs_printers_match(const zs_printers *lib, const char *hint, double bed_x, double bed_y, double height);
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
    ZS_FOUND_PRUSALINK = 4
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
} zs_found_printer;

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

#ifdef __cplusplus
}
#endif

#endif
