/* printer-link.h: talk to a printer: read what it knows, send G-code, and
 * watch the print.
 *
 * printdeck and OctoPrint: the OctoPrint API (X-Api-Key). printdeck also
 * has /api/plugin/printdeck: the filament in the printer, the spools, and
 * the job. Moonraker: its own API. USB: the app opens the serial port and
 * sends the G-code itself, one line at a time, and waits for "ok" after
 * each line.
 *
 * All calls are asynchronous; the callbacks run on the main thread.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gio/gio.h>

#include "../prefs/printers.h"
#include "../model/app-model.h"

G_BEGIN_DECLS

/* What a printer tells. A value that it does not tell is 0 or NULL. */
typedef struct {
    char *state;     /* for example "Operational", "Printing" */
    double bed_x, bed_y, height;
    double nozzle;
    char *material;  /* the filament in the printer, for example "PLA" */
    double diameter; /* of the filament */
    char *spool;     /* the name of the loaded spool */
    char *spool_id;  /* its ID at the printer */
    char *spool_color; /* "#rrggbb" */
    double spool_left; /* grams */
    double spool_price; /* the price of the roll, or 0 */
    /* The motion limits of the printer (printdeck: [printer] of
     * printer.cfg), 0 when not known: mm/s and mm/s². */
    double max_velocity, max_accel, corner_velocity, max_z_velocity, max_z_accel;
    double spool_full;  /* grams of filament of a full roll, or 0 */
    char **spools;   /* the names of all spools, NULL at the end */
    ZgRoll *rolls;   /* all rolls, with their IDs and materials */
    size_t n_rolls;
    /* The job. */
    char *job;       /* the title of the print, or NULL */
    double progress; /* 0 to 1 */
    double time_left; /* seconds, or -1 */
    int layer, layers;
    /* The status of the core, for zs_app_apply_printer_status. */
    zs_printer_status *core;
} ZgPrinterInfo;

void zg_printer_info_free(ZgPrinterInfo *info);

typedef void (*ZgInfoFn)(ZgPrinterInfo *info, const char *error, gpointer data);
typedef void (*ZgDoneFn)(gboolean ok, const char *message, gpointer data);
typedef void (*ZgProgressFn)(double fraction, gpointer data);

/* Reads what the printer knows. `info` is NULL on an error; the callback
 * owns it (free it with zg_printer_info_free). */
void zg_link_query(const ZgPrinter *p, GCancellable *cancel, ZgInfoFn fn, gpointer data);

/* The camera of a printdeck, OctoPrint, or Moonraker printer
 * (zs_printer_camera_paths): the absolute addresses of its MJPEG stream
 * and its snapshot, each NULL when it has none, or an error. The strings
 * are valid during the call. */
typedef void (*ZgCameraFn)(const char *stream, const char *snapshot, const char *error, gpointer data);
void zg_link_camera(const ZgPrinter *p, GCancellable *cancel, ZgCameraFn fn, gpointer data);

/* The printers of a printdeck (GET /slicer/printer.json with the key). A
 * deck that drives more than one printer lists them: each has the path of
 * its API under the deck ("" for the first printer, "/printers/<id>" for
 * another). `printers` is NULL on an error; it has ZgDeckPrinter items,
 * empty for a deck with one printer. */
typedef struct {
    char *id, *name, *label, *color, *kind, *path;
} ZgDeckPrinter;
typedef void (*ZgDeckFn)(GPtrArray *printers, const char *error, gpointer data);
void zg_link_deck_printers(const ZgPrinter *p, GCancellable *cancel, ZgDeckFn fn, gpointer data);

/* Sends a G-code file, and starts the print if `print`. For USB, the call
 * sends the whole print over the port: `progress` follows, and `done` comes
 * at the end. */
void zg_link_send(const ZgPrinter *p, const char *filename, GBytes *gcode, gboolean print, GCancellable *cancel,
                  ZgProgressFn progress, ZgDoneFn done, gpointer data);

/* The time of a print of a G-code file on a printdeck printer, from its
 * history: the moves (the plan times the factor that the printer learned),
 * the steps of its start macro (home, heat, probe, prime), and the total,
 * in seconds. plan_prints: the past prints in the factor. */
typedef struct {
    double moves, prep, total;
    int plan_prints;
} ZgEstimate;

/* The estimate is NULL on an error, or when the printer has no estimates
 * (an older printdeck, or another kind of printer). */
typedef void (*ZgEstimateFn)(const ZgEstimate *estimate, const char *error, gpointer data);

/* Asks a printdeck printer for the time of a print of `gcode`
 * (POST /api/plugin/printdeck/estimate, with gzip). */
void zg_link_estimate(const ZgPrinter *p, GBytes *gcode, GCancellable *cancel, ZgEstimateFn fn, gpointer data);

/* Asks the printer for an API key of its own, with the App Keys flow of
 * OctoPrint (also on printdeck): POST /plugin/appkeys/request, then a poll
 * of /plugin/appkeys/request/<token> each second, for 2 minutes. The
 * printer asks its user "Allow zslice?" (on the touch screen of a
 * printdeck, in the web page of OctoPrint). `wait` gets the seconds since
 * the request while the user decides. `done` gets the key (ok), or the
 * reason (not ok). A cancel stops the poll with no call of `done`. */
typedef void (*ZgWaitFn)(int seconds, gpointer data);
typedef void (*ZgKeyFn)(gboolean ok, const char *key, const char *message, gpointer data);
void zg_link_request_key(const ZgPrinter *p, GCancellable *cancel, ZgWaitFn wait, ZgKeyFn done, gpointer data);

/* The serial ports of the computer, for the USB choice. Free with
 * g_strfreev. */
char **zg_link_serial_ports(void);

G_END_DECLS
