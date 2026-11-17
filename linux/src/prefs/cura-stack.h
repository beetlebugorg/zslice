/* cura-stack.h: the active printer of the Cura app on this computer.
 *
 * The core compares the zslice settings with a Cura stack, but it does no
 * file I/O. This file finds the files of the stack and reads them for the
 * core (zs_read_fn):
 *
 * 1. The newest version folder in ~/.config/cura (for example 5.14).
 * 2. cura.cfg there: `active_machine` in [general] or [cura].
 * 3. machine_instances/<name>.global.cfg in ~/.local/share/cura/<version>,
 *    and the extruder stack in extruders/ whose [metadata] machine is the
 *    same name. Their [containers] list the layers from the top: user,
 *    quality_changes, intent, quality, material, variant,
 *    definition_changes, definition.
 * 4. The file of each layer, in the user folder or in the resources of
 *    Cura (ZSLICE_CURA_RESOURCES, /opt/ultimaker-cura/share/cura/resources,
 *    or /usr/share/cura/resources). A file name has the id of its
 *    container with URL escapes ("%7C" for "|", "+" for a space).
 *
 * The result is a cura.json text in the layout of the Cura import, with
 * absolute paths. The read callback gives it as "cura.json", and finds
 * "definitions/<id>.def.json" in the definition folders.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <glib.h>

#include "zslice-app.h"

typedef struct ZgCuraStack ZgCuraStack;

/* Finds the stack of the active Cura printer. NULL with an error if Cura
 * has no configuration or no active printer. */
ZgCuraStack *zg_cura_stack_find(GError **error);
void zg_cura_stack_free(ZgCuraStack *stack);

/* A line for people: "Cura 5.14: <printer>, <profile>, <material>". */
const char *zg_cura_stack_title(const ZgCuraStack *stack);

/* The read callback for zs_app_cura_compare, with the stack as ctx. The
 * bytes stay valid until zg_cura_stack_free. */
const char *zg_cura_stack_read(void *ctx, const char *path, size_t *len);
