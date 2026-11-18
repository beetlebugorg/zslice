/* printers.h: the printers of the user, and the global app settings.
 *
 * The file <config>/zslice/app.ini (a GKeyFile, readable only by the user,
 * because it has API keys) has:
 *   [general]       the app settings (theme, start view) and the id of the
 *                   current printer
 *   [printer <id>]  one group for each printer: its name and connection
 * The machine settings of each printer are a profile in
 * <config>/zslice/printers/<id>.toml (see zs_app_state_write). The model
 * applies the profile of the current printer at the start and after a
 * change of printer.
 *
 * ZSLICE_STATE_DIR moves the folder (for tests).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef enum {
    ZG_LINK_NONE,     /* no connection: export a file */
    ZG_LINK_PRINTDECK,/* a printdeck deck (the OctoPrint API, and more) */
    ZG_LINK_OCTOPRINT,
    ZG_LINK_MOONRAKER,/* Klipper with Moonraker */
    ZG_LINK_USB,      /* a serial port: the app sends the G-code itself */
    ZG_N_LINKS
} ZgLinkKind;

typedef struct {
    char *id;   /* a short name for the files, for example "printer-1" */
    char *name; /* for the user */
    ZgLinkKind kind;
    char *url;  /* http://host:port for the network kinds */
    char *api_key;
    char *device; /* the serial port, for USB */
    int baud;
    /* The pin of an https printer: the SHA-256 hash of its certificate
     * (hex), and the start of its validity (Unix seconds). "" and 0
     * before the first https reply. See printer-link.h. */
    char *tls_pin;
    gint64 tls_since;
} ZgPrinter;

/* The titles of the link kinds, in the order of ZgLinkKind. */
extern const char *const zg_link_titles[ZG_N_LINKS];

/* The folder of the settings files. Free with g_free. */
char *zg_config_dir(void);

/* Loads app.ini. With no printers, it makes one ("My printer"), and moves
 * an old machine.toml to its profile. */
void zg_printers_load(void);
/* Writes app.ini. */
void zg_printers_save(void);

guint zg_printers_count(void);
ZgPrinter *zg_printers_get(guint index);
ZgPrinter *zg_printers_find(const char *id);
/* The current printer (never NULL after zg_printers_load). */
ZgPrinter *zg_printers_current(void);
void zg_printers_set_current(const char *id);
/* A new printer with a new id, after the others. */
ZgPrinter *zg_printers_add(const char *name);
/* Removes a printer and its profile file. The last printer stays. */
void zg_printers_remove(const char *id);

/* TRUE after zg_printers_load made the first printer ("My printer") with
 * the default settings: no printer was set up. The window then shows the
 * printer picker. */
gboolean zg_printers_first_start(void);
void zg_printers_set_first_start(gboolean on);

/* The machine profile file of a printer. Free with g_free. */
char *zg_printer_profile_path(const ZgPrinter *p);

/* The global app settings in [general]. */
char *zg_pref_get(const char *key, const char *fallback);
void zg_pref_set(const char *key, const char *value);

G_END_DECLS
