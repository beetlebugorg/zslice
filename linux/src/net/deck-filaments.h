/* deck-filaments.h: the loaded filaments of a printdeck printer.
 *
 * GET <printer>/api/plugin/printdeck (zg_link_loaded_filaments) returns
 * JSON with "filaments" ([{slot, material, color "#rrggbb", nozzle
 * "main" or "aux"}]) and "nozzles" ([{type "HS01"}]). This file reads that
 * JSON into the filaments for the plate. It has no network code, so the
 * tests can call it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* A spool of the printer. color is "#rrggbb" or NULL; material is in
 * upper case. */
typedef struct {
    char *slot;
    char *material;
    char *color;
    gboolean aux; /* it feeds the second nozzle */
} ZgSpool;

typedef struct {
    /* The filaments of the plate, in the order of the printer (ZgSpool,
     * 16 at most). */
    GPtrArray *use;
    /* The spools of the second nozzle on a printer with one nozzle in the
     * settings: the plate does not use them. */
    GPtrArray *left_out;
    /* The nozzle of the printer (machine.nozzle_type and
     * machine.nozzle_flow), or NULL for no known nozzle code. */
    const char *nozzle_type, *nozzle_flow;
} ZgDeckFilaments;

/* Reads the JSON of the deck. two_nozzles: machine.nozzles is 2. On an
 * error returns NULL and sets *error (free it with g_free); `printer` is
 * the name of the printer for the error text. */
ZgDeckFilaments *zg_deck_filaments_parse(const char *json, gssize len, gboolean two_nozzles, const char *printer, char **error);
void zg_deck_filaments_free(ZgDeckFilaments *d);

/* The words for the user after the plate uses the filaments: "2 filaments
 * from X1C: A1 PLA, A2 PETG." and the spools left out and the nozzle.
 * Free with g_free. */
char *zg_deck_filaments_message(const ZgDeckFilaments *d, gboolean two_nozzles, const char *printer);

/* The nozzle of a Bambu Lab nozzle code (/^([HST])([SH])\d*$/, case
 * free): the first letter is the material (H hardened_steel, S
 * stainless_steel, T tungsten_carbide), the second the flow (H high_flow,
 * S standard). FALSE for another code. */
gboolean zg_nozzle_of_code(const char *code, const char **type, const char **flow);

G_END_DECLS
