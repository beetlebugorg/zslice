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

/* Makes the paths of one layer. It takes a few milliseconds. */
int zs_app_layer_paths(const zs_app *app, size_t layer, zs_layer_paths *out);
void zs_layer_paths_free(zs_layer_paths *paths);

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
