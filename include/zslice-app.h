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
    ZS_FEATURE_SUPPORT_INTERFACE = 7
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
} zs_toolpaths;

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
#define ZS_MARK_SEAM (1u << 8)
#define ZS_MARK_TRAVEL (1u << 9)
#define ZS_MARK_RETRACT (1u << 10)

int zs_setting_get_effect(const char *name, zs_setting_effect *out);

/* The print time, length, and plastic of the lines of one feature. */
typedef struct zs_feature_stats {
    double time_s;
    double length_mm;
    double volume_mm3;
    size_t paths;
} zs_feature_stats;

#define ZS_FEATURE_COUNT 8
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
/* Sets all settings of a group to the built-in defaults: for example
 * before the profile of an other printer. */
int zs_app_group_reset(zs_app *app, int group);
/* Applies a profile text to a group: the text of zs_app_state_write, or a
 * profile that the user wrote. On an error, message (can be NULL) gets the
 * line and the reason, and the settings do not change. */
int zs_app_profile_apply(zs_app *app, int group, const char *text, size_t len, char *message, size_t cap);

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
    ZS_SURFACE_XLIB = 2     /* display: Display *, window: Window */
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
/* Turns the camera by a drag of dx, dy pixels. */
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

#ifdef __cplusplus
}
#endif

#endif
