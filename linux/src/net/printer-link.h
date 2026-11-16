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

G_BEGIN_DECLS

/* What a printer tells. A value that it does not tell is 0 or NULL. */
typedef struct {
    char *state;     /* for example "Operational", "Printing" */
    double bed_x, bed_y, height;
    double nozzle;
    char *material;  /* the filament in the printer, for example "PLA" */
    double diameter; /* of the filament */
    char *spool;     /* the name of the loaded spool */
    char *spool_color; /* "#rrggbb" */
    double spool_left; /* grams */
    char **spools;   /* the names of all spools, NULL at the end */
    /* The job. */
    char *job;       /* the title of the print, or NULL */
    double progress; /* 0 to 1 */
    double time_left; /* seconds, or -1 */
    int layer, layers;
} ZgPrinterInfo;

void zg_printer_info_free(ZgPrinterInfo *info);

typedef void (*ZgInfoFn)(ZgPrinterInfo *info, const char *error, gpointer data);
typedef void (*ZgDoneFn)(gboolean ok, const char *message, gpointer data);
typedef void (*ZgProgressFn)(double fraction, gpointer data);

/* Reads what the printer knows. `info` is NULL on an error; the callback
 * owns it (free it with zg_printer_info_free). */
void zg_link_query(const ZgPrinter *p, GCancellable *cancel, ZgInfoFn fn, gpointer data);

/* Sends a G-code file, and starts the print if `print`. For USB, the call
 * sends the whole print over the port: `progress` follows, and `done` comes
 * at the end. */
void zg_link_send(const ZgPrinter *p, const char *filename, GBytes *gcode, gboolean print, GCancellable *cancel,
                  ZgProgressFn progress, ZgDoneFn done, gpointer data);

/* The serial ports of the computer, for the USB choice. Free with
 * g_strfreev. */
char **zg_link_serial_ports(void);

G_END_DECLS
